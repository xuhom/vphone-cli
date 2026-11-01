# VM window placement and rotation, 2026-10-31

Requested behavior: each virtual machine remembers its last window position,
size and rotation, then restores them on its next windowed launch.

## Cause and implementation

The existing AppKit frame autosave used the canonical machine directory, but
`showWindow` immediately fitted the restored frame to portrait twice. The
orientation was not persisted, and a guest disconnect also forced portrait.
Fixed-inner Duo startup additionally requested 90 degrees unconditionally.

`VPhoneWindowState` keeps frame and orientation together in the host preference
suite `com.vphone.vm-window-state`, keyed by canonical machine directory.
The record does not depend on the bundle version or executable path. Existing
AppKit saved frames are used on the first launch without a new record.
Saving window placement does not write into a running machine directory.

The window restores its orientation and frame after adding the toolbar, then
keeps the exact saved frame for the same panel, including AppKit Zoom's
letterboxing. Switching panels refits to the new panel's ratio. The panel
size is optional in the record for compatibility with older saves.
A disconnected monitor falls
back to an available one; valid negative monitor coordinates are retained.
Move/resize and orientation notifications coalesce for 500 ms. Closing or
restarting flushes immediately, using an in-progress turn's destination frame.
Shutdown freezes the saved pose before guest cleanup can change it. Transient
guest disconnects retain the last orientation. Full screen retains the last
ordinary window frame and still records orientation changes.

On the first connection to a new guest instance, the control restores the
Duo's selected panel before requesting the remembered rotation through the
existing `display.rotation` route. Orientation polling stays paused for the
whole startup operation. A fixed-inner Duo with no saved state retains its
90-degree startup default. The two Launchpad startup entries, dynamic posture
record and physical corner geometry are preserved.

The host-only change is bundle 2.14.6 build 72. It does not change guest
components. The previously exported 2.14.5 distribution is left intact.

## Validation

- CoreKit window state, orientation and Duo posture tests: 23 tests in three
  suites passed. They cover all four rotations, VM isolation, a fresh defaults
  instance, corrupt/zero-size records, negative monitor coordinates and an
  unplugged/undersized monitor.
- Final full-bundle build and bundle validation passed. The installed final
  bundle is `2.14.6-local.dff19507`; Launchpad policy and AMFI preflight passed.
  Both machines are bound to it, with the running iPad taking the new host
  programs on its next start. No CFW environment update was requested.
- Native titlebar controls expanded the dynamic Duo and rotated it to 180
  degrees. AppKit Zoom produced a deliberately letterboxed 2304 x 1266
  window at (-204, 1248). The first candidate exposed that fitting a saved
  frame would shrink this window; the final version preserves it.
- A full stop/start retained that exact origin and size. The record was
  unchanged by shutdown. After startup settled, independent guest
  `display.orientation` reported 180 degrees, hinge 180 and screen on;
  host `display.geometry` independently reported both input and view rotation
  at 180 degrees. The restored record additionally contains panel 669 x 951.
- Native capture showed the upright desktop wallpaper and physical rounded
  corners after restoring 180 degrees. A real desktop mouse click opened
  Settings. Its first launch took longer than the immediate capture; the
  later native capture confirmed General was visible. The guest was returned
  Home, the window unzoomed to 823 x 1230, and the test VM stopped again.
- Window records and a guest capture are in the task artifact directory
  `artifacts/window-state-2026-10-31/`. `before-restart.json` and
  `after-restart.json` preserve the exact-placement comparison. Build/test logs
  are `/tmp/vphone-window-state-build-20261031-final.log` and
  `/tmp/vphone-window-state-tests-20261031.log`.
