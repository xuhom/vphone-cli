# xuhom integration of upstream main — 2026-10-29

Local baseline: `8041f2cc71f4b7c575c4a5cfbfc94bb09b8fce28`.
Upstream baseline previously merged: `7d633c9a` (2.13.8).
Upstream main now merged: `2a8ee8b06f89698ff1c4e2578a38236e0d11bbf1` (PR #777).
There are 87 newly reachable upstream commits, including merge commits;
several earlier X1/audio/service changes already existed as local imports.
Build version: bundle and Launchpad **2.14.1**; VM bundle build 66,
Launchpad helper build 22 (authorization rule changed).

## Changes added by this merge

- Duo: cover-sized startup, a separate software inner display, panel-state
  coordination, redraw of the inner display's own frames, retained context
  frames, fold-aware touch routing and rotation, and an inner-display 120 Hz
  digital mode. The upstream patch still labels folding experimental.
- Duo injected touch: discard a digitizer's stale inner-display UUID after a
  backboardd restart and route input to the currently live inner display
  (PR #777, fetched during final verification). Explicit live display IDs are
  retained, and blanked/fixed-inner cases fall back to their existing route.
- Tap to wake: a touch on a dark screen lights the Lock Screen; it tries
  SBSUndimScreen before a throttled side-button fallback and does not press Home.
- iOS 27.1 CIBarcode: lower the standalone CoreImage plug-in's remaining X1
  instructions, which whole-shared-cache lowering cannot cover; the patch is
  version gated and can be disabled through the catalogue.
- Rotation input: remove the physical orientation poll that overwrote injected
  virtual orientation with Unknown on 24A94425.
- Guest environment refresh: include ctime in the binary digest cache, detecting
  in-place rewrites even when size and mtime remain equal.
- MISFix: relocate ordinary conditional branches in detoured prologues instead
  of refusing all of them; synthetic relocation coverage is retained upstream.
- Apple Watch Series 11: correct display density facts.
- Launchpad: reuse its non-shared administrator credential for the login session
  and remove the automatically opened maintenance sheet/progress banner.
- CLI/UI additions: bulk VM creation; resolve iPhone release/build selections
  with their recommended cloudOS; import/export preset plist files; include
  every selected patch in custom-preset template cache keys; toggle the guest
  software keyboard without restarting.

## Preserved xuhom behavior and conflict decisions

The Mac built-in camera transport/preview repair, LAN Remote video/audio,
headless startup and preferred port, titlebar device buttons, transparent
rounded windows/titlebars and 3 mm gap remain present. Launchpad retains the
Duo inner/outer startup menu and other models retain the ordinary start button.

The accepted fixed-inner mode is retained alongside the upstream folding path.
FoldDisplay skips a hardware Main carrying the fixed-inner UUID, and the daemon
selects its tested fixed-inner rotation mapping before the dynamic hinge route.
The fixed-inner viewer does not expose the dynamic fold toggle. On the dynamic
path the extra fold button uses the local device-button size/spacing, and the
mask follows the currently visible cover/inner panel. Research histories from
both branches are retained with separate labels.

The upstream minimum Core Bundle 2.14.0 is adopted because its new preset-file
contract needs that CLI. Launchpad and bundle are built as 2.14.1. The existing
Developer ID identity is used to sign the new Launchpad artifact.

## Validation and deployment boundary

- Full Xcode VPhone scheme: passed; includes guest components, complete bundle
  staging, signing and bundle admission validation.
- Xcode VPhoneLaunchpad scheme: passed; Developer ID signing and deep/strict
  signature verification passed.
- Native tests: fixed/dynamic topology isolation, stale injected-touch recovery, accelerometer, hinge, sidebar
  lifecycle/hit regions, BackBoard touch ABI, FoldGuard and AX orientation passed.
- vphoned logic tests: 394 checks, zero failures.
- Launchpad bundle-name/binding, machine-product-type and maintenance-progress
  tests passed.
- Firmware catalogue, ARM64E_X1, foldable-product-id and VirtualAudio suites:
  69 tests in four suites passed. Patch model suites: 32 tests in five suites passed. CoreKit: 663 tests in 68 suites passed. Conditional-branch relocation tests passed.

This run builds and pushes source. It does not install either artifact or
update/restart a guest, so the upstream dual-display path and 120 Hz mode have
not been independently verified in the user's current VM by this integration.
Existing machines continue using their previously installed bundles.

Build logs: `/tmp/vphone-upstream-merge-20261029-{build,launchpad-build}.log`.
Test logs: `/tmp/vphone-upstream-merge-20261029-{patcher-tests,patch-model-tests,corekit-tests}.log`.

Final upstream check added PR #777 after the initial 56a97c02 merge; the full
VPhone bundle was rebuilt against it. A regression includes the actual
FoldDisplayBackboard implementation and verifies stale UUID recovery, valid
explicit cover/inner UUIDs, nil input, blanking, a second restart and the
fixed-inner fallback. Localization values are merged with a JSON equality
check while preserving the original catalog formatting for review.
