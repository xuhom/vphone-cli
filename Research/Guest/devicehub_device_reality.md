# DeviceHub device reality

DeviceHub's “Virtual Machine” suffix is independent of `deviceType` and
`productType`. On Hom-iPhone, iOS 27.0.1 (24A446), CoreDevice initially reports
`deviceType = iPhone`, `productType = iPhone18,2`, `reality = virtual`.
The host's `remotectl show` independently shows `IsVirtualDevice => true` in
the guest's RSD handshake.

## Identity publisher

The guest `/usr/libexec/remoted` is a standalone Mach-O. In its unmodified
24A446 image, the property-population sequence at `0x10000eeb0` loads the
CFString at `0x100055788`, calls `MGCopyAnswer` at `0x10000eebc`, and publishes
the result under the literal `IsVirtualDevice` at `0x10000eee0`.
The CFString's text is `MrC93gcyPVLHmEbzUu9uzQ`, which equals unpadded
base64(MD5("MGCopyAnswer" + "IsVirtualDevice")). These addresses document
the inspected image; the implementation contains no binary address or offset.

## Scope

`MISFixDeviceIdentity.c` already interposes both MobileGestalt answer APIs in
remoted for the configured UDID. It now also returns retained
`kCFBooleanFalse` for the plain or obfuscated `IsVirtualDevice` key, only when
the process is remoted. The WithError variant preserves its three-argument ABI
and clears the error output on an overridden answer.

This changes the identity advertised to CoreDevice. It does not make the VM
physical hardware or change the kernel, drivers, ECID, pairing identity, or
MobileGestalt answers in unrelated processes. Existing UDID overrides remain
independent. It ships through the existing guest environment hook deployment,
under `system-launchdaemons-boot-environment`; no firmware byte patch is added.

## Verification

Before: `remotectl show` reports `IsVirtualDevice => true`; `devicectl list
devices` reports `reality = virtual`. Install the updated bundle and update the
existing machine's guest environment while stopped, then boot it again so
remoted publishes a fresh handshake. Check both tools and DeviceHub after the
new connection.

Verified on 2026-10-20 with bundle `2.10.11-local.e663fd73` (build 53),
installed and applied to Hom-iPhone's host and guest environment:

| Observation | Before | After |
| --- | --- | --- |
| RSD `IsVirtualDevice` | true | false |
| CoreDevice `hardwareProperties.reality` | virtual | physical |
| CoreDevice model description | iPhone18,2 | iPhone 17 Pro Max (iPhone18,2) |
| DeviceHub sidebar subtitle | Virtual Machine | iPhone 17 Pro Max |

The machine reconnected under the same UDID and existing pairing, and
CoreDevice reported `connected`. Its device type remains `iPhone` and product
type remains `iPhone18,2`. No host identity cache edit or re-pair was needed.
The `VPhone` workspace build, strict deep signature verification, guest
injection target tests, and `git diff --check` passed. Verification covers this
iOS 27.0.1 machine; no claim is made for other OS versions or physical devices.

## Screen sharing is a separate check

On 2026-10-20 the same machine subsequently reported DeviceKit 4000 with
CoreDevice 9015, `AVC video stream RTCP timeout`. Capture and HEVC encoding
were running, but the Mac's receiver counted zero packets and zero decoded
frames. Changing the advertised reality is not evidence that video works.

The guest had Stash 3.6.0 (build 1324) running a packet tunnel at 198.18.0.1.
Temporarily disconnecting Stash and opening a new DeviceHub stream restored
visible live video while CoreDevice continued to report physical iPhone.
The receiver then counted 1475 packets and 221 decoded frames, with about
55 fps, and later 2353 packets and 290 decoded frames in the reporting window.
Reconnecting Stash interrupted video again. This isolates the failure to the
guest VPN interaction on this machine; it does not establish the exact
NetworkExtension policy responsible.

The Stash Tunnel IPv6 route setting was Off, despite existing skipped routes
for fc00::/7 and fe80::/10. DeviceHub uses a separate IPv6 ULA tunnel. Auto
also timed out after a cold boot with Stash connected. On did not establish
stable sharing in the subsequent trial. At the user's request to stop this
investigation, the setting was restored to Off with Stash connected.
VPN and sharing coexistence remains unresolved. The host's original proxy settings were
restored after proxy-bypass experiments failed to restore video. A guest
AVConference feature-flag override also failed to restore video with the VPN
connected and was removed; no new firmware patch was retained.
