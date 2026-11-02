# Upstream merge, 2026-11-02

The local branch and `xuhom/main` started at `16f5f071`. Previously installed
Duo fold-completion and window-anchor repairs are saved in `30659d32`, with
backup branch `backup/local-duo-fold-20261102`. Upstream advanced from
`57bbc93c` to `fd1610d7` (19 commits). Both histories are retained by this merge.

## Resulting behavior

- Preserve the local Duo dual startup entries, fixed-inner rotation, dynamic
  fold memory, native fold completion/ownership checks, short nonzero host
  sweeps, final-panel corners, window placement/rotation memory, right-anchored
  left expansion and reversible closing. Camera and LAN Remote integration
  are retained.
- Adopt upstream's built-in inner-display type publication to other processes
  and the hinge server's WebDriverAgent client-event path. The local host
  display-tool path remains distinct from externally dispatched hinge samples.
- Adopt the OpenGL ES shader/compiler and primitive-restart fixes, mixed
  armv7/arm64 IPA signing, the service-profile correction for
  `generativeexperiencesd`, first-boot bootstrap option, watch audio fixes and
  the explicit-source iOS 17 desktop experiment. Their version gates, preset
  defaults and opt-in behavior remain as upstream declares them.
- The only textual merge conflict was the patch-comparison document's leading
  notes; both sets of records were retained. No source conflict was resolved
  by discarding either side.
- Update Launchpad and VPhone.bundle to compatible version 2.15.3. Bundle
  build is 79; the Launchpad helper version remains 22. Signing uses the
  existing local Developer ID configuration without committing identity data.

The new experimental iPhone 15 has a known identity but no automatic firmware
pairing. Existing catalog tests incorrectly assumed every known device had a
curated pairing. Their expectations now exclude this explicit-source experiment,
with a regression check that it remains absent from the automatic catalog.
No production catalog or patch selection was widened to satisfy a test.

Live validation also exposed a stale panel-owner record on a completed
continuous close: the cover was visibly correct at 0°, the power path logged
`shown=0`, but the earlier swap observer still held the inner owner. The owner
record is now published at the same committed-owner read that applies panel
power and compositing, rather than only from the earlier transition observers.
It still writes only when ownership changes, with no idle polling or new
firmware declaration. The panel protocol, injected-touch and topology tests
were rerun, and the full bundle was rebuilt and admitted after this correction.

## Validation

- Full Debug VPhone build and bundle admission passed; the complete bundle
  passes strict/deep signature verification.
- Release Launchpad build passed. The project's Developer ID signing script
  verified nested signatures, helper requirements and camera/microphone/location
  resource entitlements. The installed app reports 2.15.3.
- CoreKit: 90 tests in seven selected suites passed, including fold completion,
  geometry, orientation, window state, guest identities and catalog reporting.
- FirmwarePatcher: the 128-test selected run passed with three fixture-dependent
  cases skipped: the supplied-kernel GLES fixture and the two watch
  MediaExperience/cache fixtures. Synthetic patch discovery, refusal,
  idempotence, manifest/version/preset tests ran. The real 23E5207q GPU driver
  fixture was supplied from the existing pristine GPU cache; its input and
  expected patched hashes passed.
- Mixed-architecture signing: four tests passed. Daemon policy logic: 417
  checks, zero failures.
- Native hinge dispatch, panel-owner transport, injected touch, fold mode and
  iOS 17 process/version gating tests passed. GLES AIR fixtures compiled to
  metallibs, loaded into the host's Metal and linked a textured render pipeline.
  These host tests do not claim that every existing guest acquired new kernel
  patches or that guest OpenGL ES was exercised live by this merge task.
- Launchpad bundle naming, machine binding and product-type checks passed.

Logs are `/tmp/vphone-merge-20261102-*`. Xcode outputs are
`.build/XcodeBundle/Build/Products/Debug/VPhone.bundle` and
`.build/XcodeLaunchpad/Build/Products/Release/vphone-launchpad.app`.

## Installation

The signed app has replaced `/Applications/vphone-launchpad.app`; copies of
the previous installed app are retained in the task artifact directory.
The owner completed Host Setup verification to update the helper's changed
build bytes (version 22). Host Setup then passed all checks. Bundle
`2.15.3-local.849976d2` is installed as the default and passed policy and
preflight, without manual acceptance. No host security setting was changed;
the machines retain their recorded boot-chain bundle bindings, and this task
did not run a restore or kernel update.

Both machines were first updated to `2.15.3-local.92535d80`. Duo booted in 8 s;
its inner display was reported as built in (`displayType=0`, `external=false`)
from the disposable runtime probe, with no probe errors. The actual titlebar
opened the inner panel at 90°. A Mac mouse click opened Settings (RunningBoard
PID 342), the titlebar rotated to 180°, and another actual click selected
Accessibility. Inner Home wallpaper and four corners were visually correct at
both tested orientations. The titlebar then returned the visible cover to 0°,
exposing the stale record corrected above. iPad booted in 30 s and launched
Settings with `frontmost_verified:true` (PID 446).

The final bundle differs from that first installed build only in the
FoldDisplay library among all guest resources. On the final bundle, Duo booted
in 13 s. A complete round trip through the actual titlebar reported inner/90°
with hinge 180° when open, then cover/0° with hinge 0° after closing. The final
fold log records `panel owned by the cover` and `shown=0` together in the power
path, eliminating the stale inner record. Both reads were nonsweeping. Final
owner records are `/tmp/vphone-merge-20261102-owner-final-open.json` and
`/tmp/vphone-merge-20261102-owner-final-close.json`.

Both Duo and iPad now have host and guest-environment bindings to
`2.15.3-local.849976d2`. Duo is running on the cover; iPad is stopped after its
environment update. Launchpad's host checks, helper and bundle preflight are
ready. The final build's VM cdhash is
`a797eb28ed6d8bad910769cb599c110f1d507f26`; its bundle SHA-256 is
`e89ed12f84e4a0442b48cb6ca1556b344ce853dce2531e29179122cc09ae219d`.
