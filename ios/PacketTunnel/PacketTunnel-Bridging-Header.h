// Exposes the SingLink core (Singlink.xcframework, built by `make -C core ios`)
// and the utun constants the iOS SDK does not publish to Swift.
#ifndef PacketTunnel_Bridging_Header_h
#define PacketTunnel_Bridging_Header_h

#include "libsinglink.h"

// <sys/kern_control.h> / <net/if_utun.h> are macOS-only headers; the values
// are the same on iOS. Used to find the utun descriptor of the tunnel
// (getsockopt(fd, SYSPROTO_CONTROL, UTUN_OPT_IFNAME, ...)), as WireGuard does.
#define SINGLINK_SYSPROTO_CONTROL 2
#define SINGLINK_UTUN_OPT_IFNAME 2
#define SINGLINK_IFNAMSIZ 16

#endif
