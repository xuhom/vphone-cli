# Upstream integration, 2026-10-30

Local baseline: `566a96cbbe807a05f0498d8b361ba6f644980bc9` on xuhom/main.
Upstream: `39324ee7fcbb1d909bfa293f6188a8ef752ba734`, re-fetched after
validation with no newer tip. This brings in 32 upstream commits since the
previous merge. Both local and remote xuhom/main matched before the merge;
the working tree was clean. A recovery ref is
`backup/xuhom-before-upstream-20261030-566a96cb`.

## Incoming behavior

- Duo follows the simulator's portrait 2007 x 2853 inner framebuffer,
  mounting rotation, 3x scale, corner properties and physical dimensions.
  Its inner compositor can share backboardd's completed pages instead of
  rendering the inner display a second time on every panel frame.
- Folding uses SpringBoard's display-tool service or CoreMotion's hinge
  relay as appropriate. DeviceHub's controls and pose readings follow that
  path, the VM window follows settled guest-side folds, and sleeping/waking
  panels are covered until a new frame is ready.
- DeviceHub capture encodes a new frame only when the screen drew and leaves
  audio playback with the VM window.
- Camera session tracking uses a teardown-safe weak registration, avoiding
  an abort when AVFoundation reaches a session getter during deallocation.
- HomePod 26.5 gains kernelcache recipes, firmware selection, setup handling
  and an AirPlay VM override with reversible preference/restart handling.
- The standard preset enables the foldable product identity and panel-node
  repair; manifests, installer paths and patch comparison notes come from
  upstream together with their tests.

## Merge decisions

Research conflicts were independent appended histories; both were retained
under separate integration headings. Native declarations retain the fixed-inner
orientation bridge and the new upstream fold-service/relay interfaces. Both
camera source-scan and new camera session-reference test targets remain in the
Makefile. Camera/audio usage descriptions remain in the bundle Info.plist.

The accepted fixed-inner startup remains separate from upstream's dynamic
cover/inner path. Its hardware Main UUID still prevents creation of a second
software inner display. `vp_core_motion_hinge` now returns false for that
explicit fixed-inner Main even if foldable capabilities become available after
a device-tree update: its pose override, startup restoration and four-way
rotation must not silently switch to the dynamic hinge relay. The native
orientation test exercises both modes with CoreMotion availability mocked true,
including returning to the dynamic mode after the fixed mode.

The two native hinge command initializers explicitly set the newly added
`quiet` field false, preserving their publish behavior and passing strict
warning checks. The injected-touch test links the new InnerPages implementation
required by the updated Backboard implementation rather than stubbing it.

The 2.14.3 host click mapping, final-resolution R55 inner mask, transparent
screen/titlebar corners and titlebar gap are preserved. Launchpad keeps its
inner/outer startup menu. Mac camera transport, LAN Remote video/audio,
headless remote startup and preferred port, and titlebar device buttons remain
in the local branch. Bundle and Launchpad versions advance to 2.14.4; the
Launchpad helper build remains 22 because its service implementation did not
change.

## Validation

- Complete VPhone Xcode scheme passed, including guest components, bundle
  staging, signing and admission. Deep/strict signature verification passed.
- VPhoneLaunchpad Xcode build passed; the existing Developer ID signed the
  artifact, and the signing script's entitlement and helper-requirement checks
  plus deep/strict verification passed.
- CoreKit: 667 tests in 68 suites passed, including display geometry,
  orientation, firmware catalogue and manifest coverage.
- FirmwarePatcher: 75 tests in seven suites passed: kernelcache mixer, iPhone
  board properties, foldable subtype, product identity, panel nodes, guest patch
  resolution and bundled patch catalogue. These are focused fixture/unit
  checks, not a fresh full firmware corpus or live guest acceptance.
- Native regressions passed: fixed/dynamic display isolation, actual Backboard
  injected-touch routing, hinge state/HID controls, camera session reference,
  frame geometry (1183 checks), source scan, drive gate (116 checks), HomePod
  setup transitions/process ordering and AirPlay preference/restart behavior.
- Actual native AX orientation bridge passed four rotations, fallback,
  repeated preparation and fixed/relay mode isolation. Daemon logic passed
  394 checks with zero failures.
- The local delta against origin/main passes `git diff --check`. Upstream's
  simulator evidence contains pre-existing blank EOF lines; those files were
  retained byte-for-byte instead of mass-formatting imported evidence.

Build, signing and test logs: `/tmp/vphone-upstream-20261030-*.log`.
Artifacts are `.build/XcodeBundle/Build/Products/Debug/VPhone.bundle` and
`.build/XcodeLaunchpad/Build/Products/Debug/vphone-launchpad.app`.
This integration builds artifacts locally and pushes source; it does not
replace the installed applications or update/restart existing guests.
