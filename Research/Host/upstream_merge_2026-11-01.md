# Upstream merge, 2026-11-01

Upstream `Lakr233/vphone-cli` advanced from `39324ee7` to `57bbc93c`
(12 commits). Local and `xuhom/main` started at `2bfe1f32`. The previously
validated local Duo/window work is preserved in `a430fb54`, also retained by
local branch `backup/local-duo-window-20261101`, before merging upstream.

## Resulting behavior

- Keep both Duo startup entries, fixed-inner rotation, dynamic posture memory,
  final 669 x 951 inner-panel corner reference, full scanout input mapping,
  per-machine window placement/rotation memory and reversible left expansion
  around a fixed right edge.
- Adopt upstream's inner CADisplay 3x point scale and early SpringBoard scale
  handling. The existing local input geometry already applies active/backing
  pixel fractions in the drawn view, so it retains the upstream window-scale
  correction together with letterboxing and the local backing-view transform.
- Adopt upstream's HomeView catalog/preset, TVOS family handling, native setup
  repairs, distance control model and environment-service patch. Its gates and
  default selection remain as upstream declares them. Existing guests are not
  changed by this source merge/build.
- Merge the localization catalog structurally by key and locale. There were
  no conflicting scalar translations; upstream additions and the local Duo
  startup and other custom strings are retained together.
- Build Launchpad and VPhone.bundle as the compatible 2.15.0 series. Bundle
  build is 76; Launchpad retains local helper build 22 and upstream's new
  minimum bundle contract. Camera/audio usage descriptions and the local
  Developer ID signing workflow remain available. No team ID is committed.

## Validation

- Full Debug VPhone bundle build and bundle admission passed. The staged
  bundle reports 2.15.0, build 76, and passes deep/strict signature validation.
- Release Launchpad build passed. The resulting 2.15.0 app was signed using
  the existing local Developer ID identity with the project's signing script;
  nested signatures, helper requirements and resource entitlements passed.
  This build was not submitted for notarization by this task.
- CoreKit: 80 tests in seven selected suites passed, covering display geometry,
  orientation/viewports, window state, Duo posture, guest families and firmware
  catalog reporting.
- FirmwarePatcher: 122 tests in 11 selected suites passed, including HomeView
  environment-cache patching/undo, HomeView guest resolution, device-tree
  changes, scoped lookup exceptions, patch declarations, version gates,
  selection, plans and the bundled preset catalog. These use synthetic data;
  no new firmware patch was deployed to a live guest.
- Daemon policy logic: 410 checks, zero failures. HomeView distance ABI and
  host controls tests passed. Launchpad bundle-name/binding and product-type
  tests passed, including the new HomeView family.
- Native fold topology, injected touch, HomePod setup/journal/process ordering
  and AirPlay preference tests passed.
- Structured catalog validation preserved all five local-only and 28
  upstream-only string keys, with zero scalar conflicts. JSON, plist and Git
  whitespace validation passed.

Logs use `/tmp/vphone-upstream-merge-20261101-*`. This task compiles and pushes
source; it does not replace the installed Launchpad or rebind running machines.
The build outputs are `.build/XcodeBundle/Build/Products/Debug/VPhone.bundle`
and `.build/XcodeLaunchpad/Build/Products/Release/vphone-launchpad.app`.
