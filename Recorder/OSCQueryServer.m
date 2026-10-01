//
//  OSCQueryServer.m
//  eMotion
//
//  OSCQuery protocol server. See OSCQueryServer.h for an overview.
//
//  This file is compiled with ARC.
//

#import "OSCQueryServer.h"

#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>

// Maximum size of an incoming HTTP request we are willing to buffer.
#define kOSCQueryMaxRequestBytes (16 * 1024)
// How many consecutive TCP ports to try when the preferred one is busy.
#define kOSCQueryPortAttempts 16
// Per-connection socket receive timeout.
#define kOSCQueryRecvTimeoutSeconds 5


#pragma mark - Namespace node

@interface OSCQueryNode : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *fullPath;
@property (nonatomic, copy, nullable) NSString *typeSpec;      // nil = container or wildcard method
@property (nonatomic, copy, nullable) NSString *nodeDescription;
@property (nonatomic, assign) BOOL isMethod;
@property (nonatomic, assign) OSCQueryAccess access;           // None = derive from node kind
@property (nonatomic, copy, nullable) NSArray<NSDictionary *> *range;
@property (nonatomic, copy, nullable) OSCQueryValueProvider valueProvider;
@property (nonatomic, strong) NSMutableDictionary<NSString *, OSCQueryNode *> *children;
@end

@implementation OSCQueryNode

- (instancetype)init
{
    if ((self = [super init])) {
        _children = [NSMutableDictionary dictionary];
    }
    return self;
}

// Serialize this node (and recursively its children) to a JSON-ready
// dictionary following the OSCQuery proposal attribute names. Nodes with a
// value provider are collected into valueJobs as @[dict, provider] pairs;
// the caller fills their VALUE attribute afterwards, off the state queue
// (see fillValuesForJobs:), so providers can run on the main thread without
// deadlocking against it.
- (NSMutableDictionary *)jsonRepresentationCollectingValueJobs:(NSMutableArray *)valueJobs
{
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[@"FULL_PATH"] = self.fullPath;

    // ACCESS: 0 = container / no value, 1 = read-only, 2 = write-only,
    // 3 = read-write. Without an explicit level, methods are write-only
    // (eMotion consumes them) unless a value provider makes them readable.
    OSCQueryAccess access = self.access;
    if (access == OSCQueryAccessNone) {
        if (self.valueProvider)
            access = OSCQueryAccessReadWrite;
        else if (self.isMethod)
            access = OSCQueryAccessWriteOnly;
    }
    dict[@"ACCESS"] = @(access);

    if (self.isMethod && self.typeSpec.length > 0)
        dict[@"TYPE"] = self.typeSpec;

    if (self.nodeDescription.length > 0)
        dict[@"DESCRIPTION"] = self.nodeDescription;

    if (self.range.count > 0)
        dict[@"RANGE"] = self.range;

    if (self.valueProvider && valueJobs)
        [valueJobs addObject:@[ dict, self.valueProvider ]];

    if (self.children.count > 0) {
        NSMutableDictionary *contents = [NSMutableDictionary dictionaryWithCapacity:self.children.count];
        [self.children enumerateKeysAndObjectsUsingBlock:^(NSString *key, OSCQueryNode *child, BOOL *stop) {
            contents[key] = [child jsonRepresentationCollectingValueJobs:valueJobs];
        }];
        dict[@"CONTENTS"] = contents;
    }
    return dict;
}

@end


#pragma mark - Server

@interface OSCQueryServer () <NSNetServiceDelegate>
{
    OSCQueryNode *_root;
    dispatch_queue_t _stateQueue;       // guards _root and server state
    dispatch_queue_t _connectionQueue;  // concurrent, one block per connection
    dispatch_source_t _acceptSource;
    int _listenFD;
    NSNetService *_netService;
    NSInteger _bonjourRenameAttempts;   // garde-fou : au plus une reprise après collision
    NSInteger _httpPort;
    BOOL _running;
}
@end

@implementation OSCQueryServer

+ (instancetype)sharedServer
{
    static OSCQueryServer *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[OSCQueryServer alloc] init];
    });
    return shared;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _root = [self newRootNode];
        _stateQueue = dispatch_queue_create("net.am-cb.emotion.oscquery.state", DISPATCH_QUEUE_SERIAL);
        _connectionQueue = dispatch_queue_create("net.am-cb.emotion.oscquery.connections", DISPATCH_QUEUE_CONCURRENT);
        _listenFD = -1;
    }
    return self;
}

- (OSCQueryNode *)newRootNode
{
    OSCQueryNode *root = [[OSCQueryNode alloc] init];
    root.name = @"";
    root.fullPath = @"/";
    return root;
}

#pragma mark Registration

- (void)registerOSCAddress:(NSString *)address
                  typeSpec:(NSString *)typeSpec
               description:(NSString *)description
{
    [self registerOSCAddress:address
                    typeSpec:typeSpec
                 description:description
                      access:OSCQueryAccessNone
                       range:nil
               valueProvider:nil];
}

- (void)registerOSCAddress:(NSString *)address
                  typeSpec:(NSString *)typeSpec
               description:(NSString *)description
                    access:(OSCQueryAccess)access
                     range:(NSArray<NSDictionary *> *)range
             valueProvider:(OSCQueryValueProvider)valueProvider
{
    if (address.length == 0 || ![address hasPrefix:@"/"])
        return;

    // OSC pattern-matching addresses can't be represented as namespace nodes.
    NSCharacterSet *patternChars = [NSCharacterSet characterSetWithCharactersInString:@"*?[]{}#, "];
    if ([address rangeOfCharacterFromSet:patternChars].location != NSNotFound)
        return;

    OSCQueryValueProvider providerCopy = [valueProvider copy];

    dispatch_async(_stateQueue, ^{
        NSArray<NSString *> *components = [address componentsSeparatedByString:@"/"];
        OSCQueryNode *node = self->_root;
        NSMutableString *path = [NSMutableString string];

        for (NSString *component in components) {
            if (component.length == 0)
                continue;
            [path appendFormat:@"/%@", component];
            OSCQueryNode *child = node.children[component];
            if (!child) {
                child = [[OSCQueryNode alloc] init];
                child.name = component;
                child.fullPath = [path copy];
                node.children[component] = child;
            }
            node = child;
        }

        if (node == self->_root)
            return;

        node.isMethod = YES;
        // typeSpec/description: first registration wins (liblo methods are
        // often registered once per overload). Provider, range and explicit
        // access upgrade the node in place when supplied.
        if (node.typeSpec == nil && typeSpec.length > 0)
            node.typeSpec = typeSpec;
        if (node.nodeDescription == nil && description.length > 0)
            node.nodeDescription = description;
        if (access != OSCQueryAccessNone)
            node.access = access;
        if (range.count > 0)
            node.range = range;
        if (providerCopy)
            node.valueProvider = providerCopy;
    });
}

- (void)clearRegisteredAddresses
{
    dispatch_async(_stateQueue, ^{
        self->_root = [self newRootNode];
    });
}

#pragma mark Accessors

- (NSInteger)httpPort
{
    __block NSInteger port = 0;
    dispatch_sync(_stateQueue, ^{ port = self->_httpPort; });
    return port;
}

- (BOOL)isRunning
{
    __block BOOL running = NO;
    dispatch_sync(_stateQueue, ^{ running = self->_running; });
    return running;
}

#pragma mark Lifecycle

- (BOOL)startOnPort:(NSInteger)preferredPort
{
    [self stop];

    __block BOOL success = NO;
    dispatch_sync(_stateQueue, ^{
        int fd = -1;
        NSInteger boundPort = 0;

        for (NSInteger attempt = 0; attempt < kOSCQueryPortAttempts; attempt++) {
            NSInteger candidate = preferredPort + attempt;
            if (candidate <= 0 || candidate > 65535)
                break;

            fd = socket(AF_INET, SOCK_STREAM, 0);
            if (fd < 0) {
                NSLog(@"OSCQuery: socket() failed: %s", strerror(errno));
                return;
            }

            int yes = 1;
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

            struct sockaddr_in addr;
            memset(&addr, 0, sizeof(addr));
            addr.sin_family = AF_INET;
            addr.sin_addr.s_addr = htonl(INADDR_ANY);
            addr.sin_port = htons((uint16_t)candidate);

            if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0 && listen(fd, 16) == 0) {
                boundPort = candidate;
                break;
            }

            close(fd);
            fd = -1;
        }

        if (fd < 0) {
            NSLog(@"OSCQuery: could not bind a TCP port starting at %ld", (long)preferredPort);
            return;
        }

        // Non-blocking listen socket so the accept dispatch source never stalls.
        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);

        self->_listenFD = fd;
        self->_httpPort = boundPort;

        self->_acceptSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, fd, 0, self->_stateQueue);
        __weak OSCQueryServer *weakSelf = self;
        dispatch_source_set_event_handler(self->_acceptSource, ^{
            [weakSelf acceptPendingConnections];
        });
        dispatch_source_set_cancel_handler(self->_acceptSource, ^{
            close(fd);
        });
        dispatch_resume(self->_acceptSource);

        self->_running = YES;
        success = YES;
    });

    if (!success)
        return NO;

    NSLog(@"OSCQuery server started on TCP port %ld (namespace of OSC port %ld)",
          (long)self.httpPort, (long)self.oscPort);

    [self publishBonjour];
    return YES;
}

- (void)stop
{
    __block NSNetService *serviceToStop = nil;
    dispatch_sync(_stateQueue, ^{
        if (self->_acceptSource) {
            dispatch_source_cancel(self->_acceptSource); // cancel handler closes the fd
            self->_acceptSource = nil;
        }
        self->_listenFD = -1;
        self->_httpPort = 0;
        self->_running = NO;
        serviceToStop = self->_netService;
        self->_netService = nil;
    });

    if (serviceToStop) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [serviceToStop stop];
        });
    }
}

- (void)publishBonjour
{
    _bonjourRenameAttempts = 0;
    [self publishBonjourWithName:(self.serverName ?: @"eMotion OSCQuery")];
}

- (void)publishBonjourWithName:(NSString *)name
{
    NSInteger port = self.httpPort;

    dispatch_async(dispatch_get_main_queue(), ^{
        // The server may have been stopped (or restarted on another port)
        // between startOnPort: and this block running — skip if stale.
        __block BOOL stillCurrent = NO;
        dispatch_sync(self->_stateQueue, ^{
            stillCurrent = (self->_running && self->_httpPort == port);
        });
        if (!stillCurrent)
            return;

        NSNetService *service = [[NSNetService alloc] initWithDomain:@""
                                                                type:@"_oscjson._tcp."
                                                                name:name
                                                                port:(int)port];
        service.delegate = self;
        [service publish];

        dispatch_sync(self->_stateQueue, ^{
            self->_netService = service;
        });
        NSLog(@"OSCQuery service published for Bonjour as \"%@\" (_oscjson._tcp. port %ld)", name, (long)port);
    });
}

// Bonjour renomme le service en cas de collision (une 2e instance d'eMotion sur la
// machine devient « … (2) ») : le nom effectivement publié n'est donc pas toujours
// celui demandé. On le journalise pour qu'un client — ou le banc headless — sache
// quel nom chercher dans le browse.
- (void)netServiceDidPublish:(NSNetService *)sender
{
    NSLog(@"OSCQuery: Bonjour publication confirmed as \"%@\" (_oscjson._tcp. port %ld)",
          sender.name, (long)sender.port);
}

- (void)netService:(NSNetService *)sender didNotPublish:(NSDictionary<NSString *, NSNumber *> *)errorDict
{
    NSInteger code = [errorDict[NSNetServicesErrorCode] integerValue];

    // Collision de nom : une autre instance d'eMotion tient déjà « Machine (eMotion) »
    // sur cette machine (typiquement celle lancée depuis Xcode à côté d'une autre).
    // NSNetService ne renomme PAS tout seul ici — il rend NSNetServicesCollisionError
    // (-72001) et abandonne : la 2e instance n'était alors découvrable par AUCUN client
    // OSCQuery, sans autre trace que cette ligne. On republie une fois sous un nom
    // désambiguïsé par le port HTTP, qui est justement ce qu'un client doit joindre.
    if (code == NSNetServicesCollisionError && _bonjourRenameAttempts == 0) {
        _bonjourRenameAttempts = 1;
        NSString *base = self.serverName ?: @"eMotion OSCQuery";
        NSString *renamed = [NSString stringWithFormat:@"%@ %ld", base, (long)self.httpPort];
        NSLog(@"OSCQuery: nom Bonjour « %@ » déjà pris sur cette machine — nouvelle tentative "
              @"sous « %@ »", base, renamed);
        [self publishBonjourWithName:renamed];
        return;
    }

    NSLog(@"OSCQuery: Bonjour publication failed: %@", errorDict);
}

#pragma mark Connections

// Runs on _stateQueue (the accept source's target queue).
- (void)acceptPendingConnections
{
    while (YES) {
        struct sockaddr_in clientAddr;
        socklen_t addrLen = sizeof(clientAddr);
        int clientFD = accept(_listenFD, (struct sockaddr *)&clientAddr, &addrLen);
        if (clientFD < 0)
            break; // EWOULDBLOCK: no more pending connections

        // BSD/macOS : le socket accepté HÉRITE de O_NONBLOCK du socket d'écoute
        // (qui est non bloquant pour la dispatch source). Sans ce retour au mode
        // bloquant, recv() rend EAGAIN quand la requête n'est pas encore arrivée →
        // handleConnection: sort, close() → RST côté client (« Connection reset by
        // peer », une requête sur deux en loopback selon la charge de la machine).
        int flags = fcntl(clientFD, F_GETFL, 0);
        if (flags >= 0 && (flags & O_NONBLOCK))
            fcntl(clientFD, F_SETFL, flags & ~O_NONBLOCK);

        int yes = 1;
        setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
        setsockopt(clientFD, IPPROTO_TCP, TCP_NODELAY, &yes, sizeof(yes));

        struct timeval timeout = { .tv_sec = kOSCQueryRecvTimeoutSeconds, .tv_usec = 0 };
        setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        setsockopt(clientFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));

        // Connection sockets are blocking (with timeouts); handle each one on
        // the concurrent connection queue so slow clients can't stall accepts.
        dispatch_async(_connectionQueue, ^{
            [self handleConnection:clientFD];
            close(clientFD);
        });
    }
}

- (void)handleConnection:(int)fd
{
    NSMutableData *request = [NSMutableData data];
    char buffer[2048];

    // Read until the end of the HTTP header block.
    while (request.length < kOSCQueryMaxRequestBytes) {
        ssize_t n = recv(fd, buffer, sizeof(buffer), 0);
        if (n <= 0)
            return; // timeout or client hung up before completing a request
        [request appendBytes:buffer length:(NSUInteger)n];
        if ([request rangeOfData:[NSData dataWithBytes:"\r\n\r\n" length:4]
                         options:0
                           range:NSMakeRange(0, request.length)].location != NSNotFound)
            break;
    }

    NSString *header = [[NSString alloc] initWithData:request encoding:NSUTF8StringEncoding];
    if (!header)
        header = [[NSString alloc] initWithData:request encoding:NSISOLatin1StringEncoding];
    NSString *requestLine = [header componentsSeparatedByString:@"\r\n"].firstObject;
    NSArray<NSString *> *parts = [requestLine componentsSeparatedByString:@" "];
    if (parts.count < 2) {
        [self sendStatus:400 body:nil toFD:fd];
        return;
    }

    NSString *method = parts[0];
    NSString *target = parts[1];

    if (!([method isEqualToString:@"GET"] || [method isEqualToString:@"HEAD"])) {
        [self sendStatus:405 body:nil toFD:fd];
        return;
    }

    // Split "?query" off the request target and percent-decode the path.
    NSString *path = target;
    NSString *query = nil;
    NSRange questionMark = [target rangeOfString:@"?"];
    if (questionMark.location != NSNotFound) {
        path = [target substringToIndex:questionMark.location];
        query = [target substringFromIndex:NSMaxRange(questionMark)];
        // Tolerate clients that send "?ATTR=" or "?ATTR&...": keep the
        // attribute name only.
        query = [query componentsSeparatedByString:@"&"].firstObject;
        query = [query componentsSeparatedByString:@"="].firstObject;
    }
    path = [path stringByRemovingPercentEncoding] ?: path;
    if (path.length == 0)
        path = @"/";

    NSData *body = nil;
    NSInteger status = [self responseForPath:path query:query body:&body];
    [self sendStatus:status body:([method isEqualToString:@"HEAD"] ? nil : body) toFD:fd];
}

#pragma mark Request handling

// Returns the HTTP status code and, when appropriate, a JSON body.
- (NSInteger)responseForPath:(NSString *)path query:(NSString *)query body:(NSData **)outBody
{
    *outBody = nil;

    // HOST_INFO may be requested on any path.
    if ([query isEqualToString:@"HOST_INFO"]) {
        *outBody = [self jsonDataForObject:[self hostInfoDictionary]];
        return 200;
    }

    NSMutableArray *valueJobs = [NSMutableArray array];
    __block NSDictionary *nodeJSON = nil;
    dispatch_sync(_stateQueue, ^{
        OSCQueryNode *node = [self nodeForPath:path];
        if (node)
            nodeJSON = [node jsonRepresentationCollectingValueJobs:valueJobs];
    });

    if (!nodeJSON)
        return 404;

    // Run the value providers on the main thread (they read application
    // state), then merge the results in. Done here — off the state queue —
    // because the main thread itself synchronizes onto the state queue.
    [self fillValuesForJobs:valueJobs];

    if (query.length == 0) {
        *outBody = [self jsonDataForObject:nodeJSON];
        return 200;
    }

    // Attribute query: reply with a single-attribute JSON object. Recognized
    // attributes with no data on this node yield 204; unknown attributes 400.
    static NSSet<NSString *> *knownAttributes = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        knownAttributes = [NSSet setWithArray:@[ @"FULL_PATH", @"CONTENTS", @"TYPE", @"ACCESS",
                                                 @"DESCRIPTION", @"VALUE", @"RANGE", @"TAGS",
                                                 @"EXTENDED_TYPE", @"UNIT", @"CRITICAL",
                                                 @"CLIPMODE", @"OVERLOADS", @"HTML" ]];
    });

    if (![knownAttributes containsObject:query])
        return 400;

    id value = nodeJSON[query];
    if (!value)
        return 204;

    *outBody = [self jsonDataForObject:@{ query : value }];
    return 200;
}

// Executes the collected value providers on the main thread and stores each
// result under the VALUE key of its node dictionary. Bounded by a timeout so
// a busy main thread degrades to "no VALUE" instead of a hung HTTP reply.
- (void)fillValuesForJobs:(NSArray *)valueJobs
{
    if (valueJobs.count == 0)
        return;

    NSMutableArray *results = [NSMutableArray arrayWithCapacity:valueJobs.count];
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    dispatch_async(dispatch_get_main_queue(), ^{
        for (NSArray *job in valueJobs) {
            OSCQueryValueProvider provider = job[1];
            NSArray *value = nil;
            @try {
                value = provider();
            } @catch (NSException *exception) {
                NSLog(@"OSCQuery: value provider raised: %@", exception);
            }
            [results addObject:(value ?: (id)[NSNull null])];
        }
        dispatch_semaphore_signal(sem);
    });

    dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC));
    if (dispatch_semaphore_wait(sem, deadline) != 0) {
        // The block may still run later; it only touches `results`, which we
        // abandon here, so the node dictionaries stay safe to serialize.
        NSLog(@"OSCQuery: timed out reading values (main thread busy)");
        return;
    }

    [valueJobs enumerateObjectsUsingBlock:^(NSArray *job, NSUInteger idx, BOOL *stop) {
        id value = results[idx];
        if (value != [NSNull null])
            ((NSMutableDictionary *)job[0])[@"VALUE"] = value;
    }];
}

// Must be called on _stateQueue.
- (OSCQueryNode *)nodeForPath:(NSString *)path
{
    OSCQueryNode *node = _root;
    for (NSString *component in [path componentsSeparatedByString:@"/"]) {
        if (component.length == 0)
            continue;
        node = node.children[component];
        if (!node)
            return nil;
    }
    return node;
}

- (NSDictionary *)hostInfoDictionary
{
    return @{
        @"NAME" : self.serverName ?: @"eMotion",
        @"OSC_PORT" : @(self.oscPort),
        @"OSC_TRANSPORT" : @"UDP",
        @"EXTENSIONS" : @{
            @"ACCESS" : @YES,
            @"DESCRIPTION" : @YES,
            @"VALUE" : @YES,
            @"RANGE" : @YES,
            @"TAGS" : @NO,
            @"CLIPMODE" : @NO,
            @"UNIT" : @NO,
            @"CRITICAL" : @NO,
            @"LISTEN" : @NO,
            @"PATH_CHANGED" : @NO,
        },
    };
}

- (NSData *)jsonDataForObject:(id)object
{
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:&error];
    if (!data)
        NSLog(@"OSCQuery: JSON serialization failed: %@", error);
    return data;
}

#pragma mark HTTP output

- (void)sendStatus:(NSInteger)status body:(NSData *)body toFD:(int)fd
{
    NSString *reason;
    switch (status) {
        case 200: reason = @"OK"; break;
        case 204: reason = @"No Content"; break;
        case 400: reason = @"Bad Request"; break;
        case 404: reason = @"Not Found"; break;
        case 405: reason = @"Method Not Allowed"; break;
        default:  reason = @"Error"; break;
    }

    NSMutableString *header = [NSMutableString string];
    [header appendFormat:@"HTTP/1.1 %ld %@\r\n", (long)status, reason];
    [header appendString:@"Content-Type: application/json; charset=utf-8\r\n"];
    // Allow browser-based OSCQuery clients to read the namespace.
    [header appendString:@"Access-Control-Allow-Origin: *\r\n"];
    [header appendFormat:@"Content-Length: %lu\r\n", (unsigned long)body.length];
    [header appendString:@"Connection: close\r\n\r\n"];

    NSMutableData *response = [[header dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    if (body)
        [response appendData:body];

    const uint8_t *bytes = response.bytes;
    NSUInteger remaining = response.length;
    while (remaining > 0) {
        ssize_t n = send(fd, bytes, remaining, 0);
        if (n <= 0)
            return;
        bytes += n;
        remaining -= (NSUInteger)n;
    }
}

@end
