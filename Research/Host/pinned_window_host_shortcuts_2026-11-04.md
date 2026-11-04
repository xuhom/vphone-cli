# Pinned windows and the Mac app switcher, 2.15.6

The reported failure is Command-Tab going into the guest, rather than merely
typing into a guest after switching Mac applications. The VM view enabled
`capturesSystemKeys` whenever hardware keyboard input was enabled. In addition,
the window-key observer pushed Carbon's all-disabled symbolic hot-key mode.
Both routes must release host shortcuts for a pinned phone overlay.

The pin preference now participates in the capture policy: a pinned VM leaves
`VZVirtualMachineView.capturesSystemKeys` off and pops its symbolic hot-key token.
Ordinary keyboard input still goes through the existing virtual keyboard. The
policy changes immediately with the native menu toggle and applies to a saved
pinned state at initial presentation. This also leaves the Mac's other system
shortcuts, such as Spotlight, with the Mac while the phone is pinned; the guest
Spotlight and input-source menu actions remain available.

Window-key focus is insufficient for a floating window. Application
deactivation explicitly disables system-key capture, releases mouse capture
and held guest fallback keys, and restores the host hot-key mode. Reactivation
re-evaluates the active/key/pinned/keyboard conditions. Explicit mouse capture
is preserved while a pinned window is still active and key.

Read-only `display.geometry.view` diagnostics include application/key-window,
system-key capture, symbolic hot-key suspension and mouse-capture state.
No host keyboard preferences, global hot-key settings, accessibility grants or
guest firmware are changed. The public SDK documents `capturesSystemKeys` as
the switch for routing system shortcuts to the guest; CarbonEvents.h documents
the all-disabled mode as applying while the process is frontmost.

Complete bundle build/admission passed; installed host bundle
`2.15.6-local.0a4052f9` passed Launchpad policy and AMFI preflight. Duo was
restarted on it with the saved pin enabled; the live diagnostics report
`system_keys_captured=false`, `host_hotkeys_suspended=false` and no mouse
capture in the background. Both existing machines are bound to this host
bundle. The iPhone/iPad guest resources are unchanged (only the unrelated TV
daemon's rebuilt bytes differ), so no guest environment reinstall was needed.
The owner completed the physical-keyboard check on 2026-11-04: after clicking
the pinned Duo window, Command-Tab successfully switched to other Mac apps.
This closes the app-switcher acceptance check that background-targeted desktop
automation could not exercise.

Ordinary virtual-keyboard input was also checked with capture disabled: focus
Settings' search field, send `a` through the existing `hostkey`/VZ keyboard
path, and inspect the native framebuffer. The field visibly contained `a`.
The test character was deleted and the guest returned Home afterwards. The
distribution DMG and both ZIPs were re-exported; mounted application/bundle
signatures, DMG integrity and ZIP integrity passed.
