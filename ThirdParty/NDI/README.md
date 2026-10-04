# NDI SDK headers

`include/` holds the headers of the NDI SDK for Apple, version 6.1.1 (`NDI 2024-12-20 r143737 v6.1.1`), copied unchanged
from `/Library/NDI SDK for Apple/include`. They are what Simple Recorder needs to call NDI's library, which it loads at run
time with `dlopen`: nothing links against it.

The MIT notice at the top of each header applies to the headers only. The library (`libndi.dylib`) is under the NDI SDK's
licence (`NDI SDK License Agreement.pdf` in the SDK, or http://ndi.link/ndisdk_license) and is not in this repository:
install the NDI SDK for Apple, or NDI Tools, to get it.

`module.modulemap` and `NDIHeaders.c` are ours: they make the headers a SwiftPM target, `NDIHeaders`.

NDI® is a registered trademark of Vizrt NDI AB.
