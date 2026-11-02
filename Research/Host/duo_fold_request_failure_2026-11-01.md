# Duo fold request refusal (2026-11-01)

## Symptom and evidence

The user saw `VPhoneGuestControl.ControlError error 2` when using the Duo
titlebar expand/collapse button on bundle 2.15.0-local.b0f9da63. For this Swift
enum, the bridged NSError code 2 is the associated `guestError(String)` case,
not `protocolError`. `ControlError` had a description but no `LocalizedError`
conformance, so the alert discarded the guest's diagnostic text.

The VM log includes `[rotate] portrait refused: The device did not apply the
requested rotation.` The host's collapse implementation awaited
`display.posture` and then sent an independent `display.rotation` write to
restore the cover direction. `GuestAPI.setDevicePose` already accepts a
physical `orientation` in the posture request. The CoreMotion path publishes
hinge angle, duration, and orientation together through `vp_hinge_sweep`;
its reply acknowledges publication, not completion of the scene transition.
Rotation and posture use different guest locks. A second rotation can race
the transition it is meant to finish.

Separately, the host's two-second button availability timer ignored
`foldRequestsInFlight` and `isChangingOrientation`. It could re-enable a fold
button while its original action was pending. The Controls panel's rotation
write also bypassed the menu's rotation counter. Slow native-button open and
close both succeeded before the fix; the reported refusal is intermittent.

## Change

* Restore the remembered cover direction in the same posture request. The
  physical cover mapping is 0°→1, 90°→4, 180°→2, 270°→3, matching
  `setFoldableRotation`. The CoreMotion guest still rejects physical code 2;
  this change does not claim to add unsupported dynamic rotations.
* Do not send a follow-up rotation. Keep the fold pending through a declared
  asynchronous sweep and two agreeing `display.orientation` reads. Check the
  requested hinge target and expected interface direction with a bounded
  deadline. A timeout reports the observed direction; no forced retry or
  compensating rotation is issued.
* Keep startup's separately saved rotation, legacy SpringBoard pose handling,
  right-anchored panel resizing, and final-resolution corner geometry.
* Reject overlapping host fold/rotation writes, including direct rotation
  writes from the Controls panel. Availability and polling honor pending
  display changes. Publish the new panel before its confirmed direction.
* Preserve guest diagnostic messages through `LocalizedError`.

Live testing showed that the sensor's target and current angle could both be
0° while the visible primary content was still the inner display. AX then
reported 90°, and `vphone-folddisplay.log` had no corresponding ownership
handoff to the cover. Instant and timed sensor requests both exhibited this.
LCD `currentOrientation=rot0` alone was insufficient evidence: the LCD is also
the scanout onto which the still-active inner display is composited. Reading
direction from the requested panel would hide the failed swap and draw that
inner content sideways. The original AX bridge remains unchanged.

The host now adds `use_display_tool: true` to its posture request. With a
CoreMotion relay, this asks the existing `SBSDisplayToolService` to perform
and complete the actual screen swap, then publishes the final hinge/physical
orientation. It must not publish a relay target before acquiring the native
swap: that could start a competing sensor-driven transition. The service's
absence retains the sensor fallback. DeviceHub's continuous slider does not
set this option and keeps the upstream relay path. The legacy non-relay path
retains its existing target publication and restoration behavior.

The display tool defers sensor input after a swap. A direct relay rotation
immediately after an otherwise successful fold was reproduced refusing the
new direction. Host rotation writes in dynamic-outer mode therefore request
the same synchronous display tool at the current hinge angle before final
sensor publication. Fixed-inner rotation and DeviceHub's direct controls
retain their existing paths and capabilities.

The cover direction is snapshotted before the host's first await.
`display.orientation` also exposes provider sweep state/current angle so a
target publication cannot prematurely release the controls. AppKit's applied
window frame is anchored to the old frame's right edge after minimum-size
adjustment; live testing had exposed an 8-point shift per close.

The vphoned update requires updating the guest environment and
restarting the guest. No boot-chain or kernel patch changes are needed.
Bundle version is 2.15.2 (78), compatible with Launchpad 2.15.x.

## Validation

The focused CoreKit run passed 35 tests across DuoFoldRequestTests,
DuoPostureTests, DisplayOrientationTests, and WindowStateTests. The new fold
tests cover one-write direction restoration, delayed/inconsistent reads,
startup, malformed replies, stale hinge targets, timeout, legacy sweeps, and
preserving a guest refusal's text.

No hinge-provider or AX bridge change remains. Neither replaying an unchanged
physical direction nor selecting a display based on the requested hinge angle
proved an actual native ownership handoff. Final live checks follow installation.

### Previous-build installed validation (2.15.1, superseded below)

* Full bundle builds and admission passed. Installed bundle and Duo guest
  environment are both `2.15.1-local.91c8c1b5` (build 77).
* The synchronous-swap build's actual titlebar was exercised through two
  complete open/close cycles. Each close reported 0° and its fold-display log
  recorded `panel owned by the cover` and `shown=0`; open reported 90°.
  Visual inspection confirmed upright outer Home Screen content rather than
  an inner frame rotated into the cover window.
* A fold followed immediately by an unflagged raw sensor rotation reproduced
  the native deferral refusal. The final guest's same sequence with
  `use_display_tool:true` accepted 180°. Raw `vphone.sock` RPC intentionally
  preserves the caller's parameters; GUI `call` adds the option in dynamic
  outer mode. Do not mistake an unflagged raw probe for the GUI route.
* On the final guest, a screenshot at inner 180° was upright with wallpaper.
  A pixel tap on Settings opened `com.apple.Preferences` (RunningBoard
  verified, PID 385). A final native close returned `sweep.completed:true`,
  0° and hinge 1, with an actual ownership handoff and removal of the inner
  compositor in the fold-display log.
* The Mac locked during final checks. Final-build Mac mouse interaction and
  the early-captured window anchor still need an unlocked desktop; the user
  was asked to unlock it. The guest-side checks above do not claim to verify
  that remaining desktop interaction.

### Unlocked rapid-switch follow-up (2.15.2)

The first rapid titlebar round-trip after unlocking reproduced a remaining
failure on 2.15.1-local.91c8c1b5: the hinge target/current were 0°, while the
visible lock screen and primary content remained inner at 90°. Slow successful
cycles were not sufficient validation. The native helper's `seconds == 0`
branch treated an immediate refusal reply as completion.

FoldDisplay now publishes the coordinator's actual primary-content owner to
a shared mobile preference only when that owner changes, including its
SpringBoard PID. vphoned rejects malformed records and records from a dead
process. Synchronous host swaps require that ownership and the requested
direction to agree. An immediate native reply is retried only while that
condition is false, within the existing native-deferral window plus two
seconds of completion allowance. The hinge target is published afterwards.

The host verifies this independent `fold_panel` field on acknowledged swaps
and does not reshape a window from a hinge target inconsistent with the real
owner. Opening also wakes the display before requesting the native swap.
The fixed-inner path and the original AX orientation bridge stay unchanged.

The 35 CoreKit tests include a correct angle/direction with the wrong or
missing owner, proving it cannot complete a verified request. The native
panel-record transport tests passed binary-plist round trips and malformed
Boolean/PID inputs; the existing native AX bridge tests still pass.

### Final acceptance (2.15.2)

A later rapid-switch test identified a second native failure mode. SpringBoard
logged `SBDisplayToolServiceCoordinator: rejecting swap request — system is not
idle (state=idle transitionActive=YES)` persistently after a zero-duration
absolute swap. Waiting and repeating the same request did not release that
content-mode transition. This is distinct from a transient busy reply and from
the panel-owner readback. After restarting the guest, four consecutive swaps
with a 0.42 s sweep succeeded in 1.25–1.55 s each. Host fold requests now use
that short real sweep when their caller asks for duration 0; explicitly timed
requests and native per-direction defaults remain available. The raw guest API
retains its explicit instant-swap option. This avoids the observed zero-length
path; it does not claim to repair SpringBoard's internal transition lifecycle.

Hopper's launcher could not establish its bridge in this session. The native
request ABI and duration branch were cross-checked against the matching
24A94425 SpringBoard image with the installed LLVM disassembler, and the refusal
condition above is from the running guest's filtered SpringBoard log. No new
kernel or offline binary patch was introduced.

The compact-window drift had an independent cause: AppKit first accepted a
341-point cover frame, then widened it to 348 and 349 points in later titlebar
layout passes. The fold anchor is retained through those resize callbacks and
released by the existing debounced window-state save. User dragging, live
resizing, full screen and ordinary rotations do not retain that fold anchor.
The titlebar's larger declared minimum is not imposed on the compact window.

Final installed host bundle: `2.15.2-local.e071844a` (build 78). Duo's guest
environment remains `2.15.2-local.3032928c`; a byte comparison of its entire
`guest-resources` tree with the final bundle passed. The boot-chain binding
remains unchanged. iPad was not modified during this fix.

* Final full VPhone build, bundle admission, installed policy and preflight
  passed. The focused Xcode run passed all 35 tests in four suites.
* Two complete cycles through the actual titlebar button confirmed real inner
  and cover ownership with directions 90° and 0°. Window frames alternated
  `(1363,269,349,556)` and `(1008,269,704,556)` and returned exactly each time:
  right edge 1712, top 825, height 556. The five persisted frame records passed
  the existing strict fold-frame checker.
* An actual Mac mouse click on the cover's Settings icon launched
  `com.apple.Preferences`, verified through RunningBoard (PID 371). After
  unfolding and rotating with the titlebar to 180°, another actual mouse click
  selected Accessibility; the resulting page was visually verified.
* Home at inner 180° showed upright, complete wallpaper and four rounded
  corners. A third titlebar close from that rotated state succeeded and restored
  actual cover ownership, hinge 0° and interface 0°. No second rotation write
  was needed. The final Duo is left running on the cover.

Task-local acceptance records are `artifacts/duo-fold-fix-2026-11-01/release0.json`
through `release4.json`. Final build/test logs are
`/tmp/vphone-final-fold-native-build-20261101.log` and
`/tmp/vphone-final-fold-native-tests-20261101.log`. These checks cover the
exercised sequences; they do not establish that every iOS transition or app was
tested.
