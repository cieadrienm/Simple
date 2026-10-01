//
//  OSCQueryServer.h
//  eMotion
//
//  OSCQuery protocol server (https://github.com/Vidvox/OSCQueryProposal).
//
//  Serves the application's OSC address space as JSON over HTTP so that
//  OSCQuery-aware clients (TouchOSC, Chataigne, Vezer, VDMX, ...) can
//  discover and auto-map eMotion's OSC namespace. The service is
//  advertised over Bonjour as "_oscjson._tcp".
//
//  Supported queries:
//    GET /                → full namespace as a JSON tree
//    GET /some/path       → subtree rooted at that OSC container/method
//    GET /some/path?ATTR  → single attribute (TYPE, ACCESS, DESCRIPTION,
//                           FULL_PATH, CONTENTS)
//    GET /?HOST_INFO      → server metadata (NAME, OSC_PORT, OSC_TRANSPORT,
//                           EXTENSIONS)
//
//  This file is compiled with ARC.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// OSCQuery ACCESS attribute values.
typedef NS_ENUM(NSInteger, OSCQueryAccess) {
    OSCQueryAccessNone      = 0,   // container / no value
    OSCQueryAccessReadOnly  = 1,
    OSCQueryAccessWriteOnly = 2,
    OSCQueryAccessReadWrite = 3,
};

/// Returns the node's current value(s), one entry per OSC type tag
/// (NSNumber for i/f, NSString for s). Return nil to omit VALUE for this
/// request. Always invoked on the main thread so it can safely read
/// application state.
typedef NSArray * _Nullable (^OSCQueryValueProvider)(void);

@interface OSCQueryServer : NSObject

+ (instancetype)sharedServer;

/// Name reported in HOST_INFO and used for the Bonjour service.
@property (atomic, copy, nullable) NSString *serverName;

/// UDP port of the OSC server this query server describes (HOST_INFO OSC_PORT).
@property (atomic, assign) NSInteger oscPort;

/// TCP port the HTTP server is actually bound to (valid while running).
@property (atomic, readonly) NSInteger httpPort;

@property (atomic, readonly, getter=isRunning) BOOL running;

/// Add an OSC method to the published namespace. Intermediate containers
/// are created automatically. typeSpec is a liblo-style tag string such as
/// "fff" (nil when the method accepts any arguments). Registering the same
/// address twice keeps the first non-nil typeSpec/description.
- (void)registerOSCAddress:(NSString *)address
                  typeSpec:(nullable NSString *)typeSpec
               description:(nullable NSString *)description;

/// Full registration. access selects the OSCQuery ACCESS level (pass
/// OSCQueryAccessNone to keep the default: write-only for methods).
/// range is one dictionary per argument (keys MIN and/or MAX, or an empty
/// dictionary for "no range"). valueProvider makes the current value(s)
/// readable through the VALUE attribute; it runs on the main thread.
/// Re-registering an address upgrades the existing node in place.
- (void)registerOSCAddress:(NSString *)address
                  typeSpec:(nullable NSString *)typeSpec
               description:(nullable NSString *)description
                    access:(OSCQueryAccess)access
                     range:(nullable NSArray<NSDictionary *> *)range
             valueProvider:(nullable OSCQueryValueProvider)valueProvider;

/// Remove every registered address (used when the OSC server is rebuilt).
- (void)clearRegisteredAddresses;

/// Start listening on preferredPort (TCP). If the port is busy, the next
/// 15 ports are tried. Publishes the Bonjour service on success.
- (BOOL)startOnPort:(NSInteger)preferredPort;

/// Stop the HTTP server and withdraw the Bonjour advertisement.
- (void)stop;

@end

NS_ASSUME_NONNULL_END
