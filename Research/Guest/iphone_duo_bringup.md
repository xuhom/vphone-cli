# iPhone Duo single-display bring-up

## Kernel CSSC fallback (2026-10-25)

This branch starts from upstream main, without the static CSSC trampoline
experiment. On an independent Banana clone, the installed experimental image
panicked with PID 1 SIGILL at user PC 0x2bd6380e8, ESR 0x02000000. The kernel's
exception codes contained the copied instruction 0xdac1a7fe (PACIBSPPC), matching
/usr/lib/libSystem.B.dylib at image offset 0x10e8. CSSC allocation had aborted
the entire X1 cache operation, leaving PAuth/CPA conversion unapplied; the
installer nevertheless continued. The new route retains upstream PAuth/CPA
conversion and handles CSSC independently in the kernel.

Reveal procedure for `kernelcache.research.vphone600`, UUID
784F88D3-2AF5-3D4A-AB00-365607646E44:

1. Find the unique function referencing `Undefined kernel instruction: pc=%p
   instr=%x`. Identify it as XNU handle_uncategorized by decoded control flow,
   not a recovered symbol (the indexed research symbol JSON is absent).
2. Validate its copyin of four bytes from the saved PC and its EL0/EL1 gate.
   Hook only the user path before undefined-instruction triage. The observed
   handler file offset is 0x1e626ec; the hook is 0x1e62918.
3. Follow the handler's existing signed-state manipulation sequence to recover
   ml_check_signed_state (0x1caa37c), ml_sign_thread_state (0x1caa32c) and its
   interrupt disable/restore helpers. Validate register and saved-state ABI,
   PACGA bodies, and the original stack-canary checked epilogue. These names
   are source correlations; offsets are observations, never runtime constants.
4. Plan the complete fixed-size payload and one entry branch before writing.
   Restrict it to persistent __TEXT_EXEC; do not use boot-only reclaimed text.
   Unknown or ambiguous layouts abort the selected operation.

The fallback accepts only 64-bit user saved states with an uncategorized
exception and successful instruction copyin. It evaluates scalar ABS/CNT/CTZ
and signed/unsigned MIN/MAX register and immediate forms, preserving the
saved NZCV and all unrelated registers. W results zero-extend and register 31
is ZR. A successful operation verifies the old signed state, updates the
destination and PC, and re-signs with the new LR/X16/X17 when applicable.
There are no stack accesses while SPSel selects the interrupt stack. The
original canary check and epilogue remain in use. Unknown words preserve the
original instruction, registers, kernel flags and exception path.

Kernel emulation has per-execution exception overhead. Native CSSC execution
does not enter this fallback; PAuth/CPA retain the existing X1 conversion path.

## Scope and inputs (2026-10-23)

This experiment attempts to boot the iPhone Duo userland on the existing
vphone600 virtual hardware. It registers one outer panel, not two displays or a hinge.
The inner panel, folding poses and physical Duo hardware are not emulated.

- Host: Apple Silicon, macOS 27.0.1 (26A434), without CSSC, CPA or PAuth_LR.
- Guest: `iPhone19,4`, board `v68ap`, iOS 27.1 (24A94425).
- IPSW: <https://updates.cdn-apple.com/2026FallFCS/3f41a447-d8a6-48ae-83ae-056a64f57fd4/iPhone19,4_27.1_24A94425_Restore.ipsw>.
- Size: 12,724,731,538 bytes.
- SHA-256, verified after download:
  `58fbfda85615e90221136d55288f64c9f41386510f8cd77feb8c9d20cc0a782e`.
- CloudOS: 26.4 beta (23E5207q), the existing recommended vphone600 image.
- Preset: `standard`; boot ROMs: the bundle's OpenAVB and OpenSEP.
- VM configuration: 8 CPUs, 8192 MiB RAM, 64 GiB disk, created without a template.
- Core Bundle: a local 2.12.0 build; installed and passed execution policy
  and host preflight.

## Evidence and initial implementation

The restore archive's `BuildManifest.plist` and `Restore.plist` both name
`iPhone19,4`, build 24A94425 and device class `v68ap`. Restore.plist records
CPID 33120 (`0x8160`), BDID 14 (`0x0e`), platform `t8160`.

The archive contains `Firmware/all_flash/DeviceTree.v68ap.im4p`. Its `/product`
records `app-macho-architecture = arm64e.x1`, `artwork-device-idiom = phone`,
`artwork-device-subtype = 2034`, `artwork-scale-factor = 3`, plus `display0`
and `display1` children. The former has display index 0, rotation 0 and scale
3; the latter has index 1, rotation 270 and scale 3. Those are source device
properties, not proof that both panels work in the VM.

The initial model entry uses the outer display's 1398 x 2034 pixels at 460
ppi and 3x, as published in [Apple's technical specifications](https://www.apple.com/iphone-duo/specs/).
The catalog adds only the released 27.1 IPSW, paired with the existing
recommended cloudOS. No new instruction patch or preset is introduced;
the current iOS 27 and ARM64E_X1 patches are exercised on this new userland.

`VPhoneCoreKitTests/GuestDeviceTests` and
`VPhoneCoreKitTests/FirmwareCatalogReportTests` passed: 26 tests total.
The complete `VPhone` Debug build passed. Its finished bundle and a ZIP
round-trip both passed strict, nested, all-architecture signature validation
before the local bundle was installed through Launchpad.

## Boot validation

**Result: does not boot to userspace on this host.** Firmware preparation,
boot-chain patching, DFU restore and CFW installation completed. Template
setup failed while waiting for vphoned because the guest panicked. A subsequent
windowed `vm start <name> --wait --timeout 300` reproduced it before any guest
agent connection or SpringBoard UI:

```text
initproc failed to start -- exit reason namespace 2 subcode 0x4 description: none
Panicked task ... pid 1: launchd
Kernel UUID: 784F88D3-2AF5-3D4A-AB00-365607646E44
```

Namespace 2/subcode 4 reports SIGILL. The saved user-space backtrace LR is not
a recovered fault PC or a verified unslid symbol address. Do not infer an
exact instruction from it without the image load address and fault state.
Runtime addresses and local machine identifiers are omitted from this record.
The VM was stopped after preserving the console log. Its disk,
firmware and installed guest environment remain available for investigation.

### Identified instruction compatibility gap

Host feature queries return zero for `hw.optional.arm.FEAT_CSSC`,
`hw.optional.arm.FEAT_CPA` and `hw.optional.arm.FEAT_PAuth_LR`.
The installed, already X1-lowered `/usr/lib/dyld` still contains scalar CSSC
instructions: for example `UMIN X8,X8,X1` at image offset `0x9570`, `UMAX`
at `0x8ba8`, and `CTZ W10,W21` at `0x1af04`. These are measured offsets in
the 24A94425 dyld, for investigation only, never patch-site constants.

`VPhoneArm64eX1Lowering` and the runtime X1 handler currently lower PAuth_LR
and CPA forms, not these CSSC operations. CSSC therefore is a confirmed
compatibility gap and a candidate explanation for the SIGILL, not yet a
proved fault-site attribution. The cache's early-boot closure and later
runtime code also need auditing before claiming 27.1 support. A safe fix
needs correct register width, operand aliasing, NZCV preservation and immediate
forms; replacing a min/max with an unconditional move is not equivalent.

### Other observed gaps

- Four optional VirtualAudio patches failed together because the old reveal
  expected a `retab` after the throw at `0x171cd0`:
  `system-virtualaudio-cfw-mute_set_throw`,
  `system-virtualaudio-cfw-speaker_protection_gate`,
  `system-virtualaudio-cfw-speaker_route_throws`, and
  `system-virtualaudio-cfw-volume_mode_precondition`.
- The shared-region preflight attempted the ordinary arm64e filename and
  skipped its check; later cache patching correctly found 79 X1 chunks and
  measured `sharedRegionSize = 0x17ce04000`, `maxSlide = 0x20000000`, then
  zeroed maxSlide. No cache-size overflow was reported by that later stage.
- Existing X1 lowering reported 2735 instructions in launchd, with zero
  unvisited candidates. This only counts the instruction forms it recognizes;
  it does not establish support for every instruction in the binary.

The registered model and catalog entry are experimental bring-up inputs,
not a claim of successful Duo support. No CSSC or audio patch was added by
this experiment. Supporting this firmware on hosts without CSSC requires
additional instruction compatibility work; emulating both displays and the
hinge is a separate gap. These results establish limitations of the current
implementation, not that supporting the device is technically impossible.

The original manifests and device tree were extracted by HTTP ranges with
the repository's `VPhoneRemoteZip`. Raw logs and scratch artifacts remain
local; host paths, per-machine identifiers and runtime addresses are not
included in this research record.

## Inner panel probe (2026-10-27)

The earlier host Unfold button only enlarged the outer framebuffer. The
current vphone600 Mac graphics configuration has one display, and the macOS
Virtualization.framework header for `VZMacGraphicsDeviceConfiguration.displays`
states that a maximum of one is supported. A runtime call to
`VZGraphicsDisplay.reconfigure(configuration:)` on the running Melon VM failed
with "The display does not support reconfiguration at this time". No guest
display change occurred.

Two separate, temporary boot configurations used the real Duo inner panel
resolution in both orientations: 2670 x 1878 at 430 ppi, then 1878 x 2670 at
430 ppi. The guest agent booted in both cases, but the VZ framebuffer captures
were entirely black. The guest still reported `device.screen` as 669 x 951
points at 3x and the console logged
`IOMFB: default_fb_surface: No Default FB Surface found. Return error`.
The guest's IOMobileFramebuffer userclient mapped display type 0, so changing
the host scanout size alone did not register the DeviceTree's `display1` as an
active inner panel. The host configuration was restored to the original
1398 x 2034 outer-display mode after this probe. In follow-up boots, the
guest still stopped at the Apple logo with an all-black guest screenshot,
including one boot using the previously working host bundle. The guest agent
responded and reported the original 466 x 678 points, but SpringBoard-backed
RPCs hung. Do not treat the display restoration as a recovered guest UI.

A real fold implementation therefore needs guest-side display registration
and a fold-state transition that swaps the active panel without relying on
runtime VZ display reconfiguration. The old zoom-based host control is hidden
until that display path exists; it was not an inner-screen implementation.

## Outer baseline and fold service investigation (2026-10-27)

On the installed 2.13.8 local host and guest environment, two cold boots reached
an interactive outer display at 1398 x 2034. The first agent ping (12–17 seconds)
preceded usable SpringBoard UI by substantially more time. Early black captures
and blocked SpringBoard queries are not a completed boot test. After allowing
startup to settle and unlocking, Settings launched with `frontmost_verified`
and rendered; a second cold boot rendered the Home screen. No guest preference
reset or firmware reinstall was needed. This establishes a working baseline on
this build, not a diagnosed permanent fix for every earlier black-screen case.

Runtime evidence from iOS 27.1 (24A94425):

- `CADisplay.displays` contains `LCD primary` plus five wireless placeholders.
  The physical display has ID 1, type 0, and one mode, 1398 x 2034. There is no
  second physical display in this configuration.
- `CMMagicPoseManager.isAvailable` is false. Its events distinguish `Closed`
  (1), `PartiallyOpen` (2), `OpenFlat` (3), `OpenAmbiguous` (4) and
  `OpenTransitioning` (5); these values were read using
  `CMMagicPoseEvent.stringForHingeState:`, not inferred from UIKit's enum.
- `SBFDevicePoseProvider` feeds `SBDisplayContentModeCoordinator` through
  `poseProvider:didUpdateFromPose:toPose:`. The framework contains
  `SBFFoldingDualDisplayContentModeResolutionPolicy`, with
  `preferredPrimarySurfaceTypeForDevicePose:` and
  `resolvedModeForDisplayProxy:devicePose:`. `SBContinuousFoldController`
  observes the resulting transition. UIKit receives `_UISceneHingeState`,
  including magicPose, status, nextStatus, progress and angleDegrees.
- `SBSDisplayToolService` exposes `swapDisplayWithSettings:completionHandler:`.
  The measured ABI is `v88@0:8{?=qdqqBqdd}16@?80`. Its connection serializes
  duration (offset 8), deviceOrientation (16), profileOverride (24),
  waitForCompletion (32), targetMode (40) and targetHingePosition (48).
  An isolated signed test client received a successful callback for an instant
  swap, twice. Neither changed the framebuffer dimensions or created another
  physical display. Callback success alone is not successful unfolding.

Host evidence on macOS 27.0.1:

- `VZMacGraphicsDeviceConfiguration` has private `_displayPortCount` and
  `_setDisplayPortCount:` methods. Both the default port count and
  `_maximumAllowedDisplayCount` return 1.
- Two configured displays fail validation with "Number of displays is greater
  than the configured display port count." Setting the port count to 2 fails
  with "The display port count is invalid, it must be between 1 and the maximum
  supported."
- An isolated test process replacing only the class maximum with 2 passes this
  validation. This does **not** establish backend or guest support. A boot probe
  must verify both framebuffers and recovery before any fold UI is exposed.

The machine was shut down and an APFS clone backup of Disk.img plus matching
SEPStorage, nvram.bin and configuration was retained before the dual-port boot
probe. No host security settings were changed.

### Dual-port boot result

The temporary host change set the port count and configuration to two, with
outer 1398 x 2034 and inner 1878 x 2670 panels, and replaced the maximum-count
method only inside that VM process. The full signed bundle built and passed
Launchpad preflight. Configuration validation succeeded, but VM start failed
**before guest boot** with `VZErrorDomain Code=1` (internal virtualization error).
The host's `com.apple.Virtualization.VirtualMachine` process logged
`com.apple.VirtualizationCore:DeviceFactory: Failed to initialize device` (the
device name is private/redacted). This does not identify an exact backend
function, and does not prove every single-scanout design impossible. It does
prove that relaxing the front-end display-count check is insufficient on this
host. The temporary host override and second-display configuration were removed;
the machine was rebound to the verified outer-display bundle.

A reusable read-only probe is in `DuoDisplay/inspect.js`. Remaining work is the
rendering transport/registration underneath the discovered fold-state chain.
No functional Unfold UI or inner-screen support is claimed by these probes.

### Fixed-inner single-scanout experiment (2026-10-27)

Tested on the existing Duo, with its exact Preboot IMG4 and outer manifest
saved before changes. The original personalized manifest and restore-info
bytes were retained when replacing the device-tree IM4P. No kernel, shared
cache, or host security changes were made in this experiment.

The donor `/product/display1` describes a 270-degree mounting orientation,
surface type 2, scale 3 and four radius-55 corners. Its fold-region frame has
width 1878 and midpoint 1335. A temporary tree copied this presentation to
virtual `display0` (index 0), omitting the physical framebuffer UUID and
phandle. A second variant also copied the presentation to the root product
fallback and set the chosen display rotations to 270. Neither is a released
patch: the missing physical-identity association remains unproven.

Observed results:

- One 1878 x 2670 scanout at 460 ppi boots and produces native framebuffer
  images, including Settings with two-column content. Earlier black startup
  frames alone were insufficient evidence of permanent rendering failure.
- Starting the same mapping at 2670 x 1878 produces a wide framebuffer, but
  Home and Settings remain vertically laid out and clipped with a black right
  region. This is not a successful landscape inner-screen boot.
- The raw `FBSDisplayConfiguration` follows the scanout, while the disposable
  probe's UIKit initial context reports 669 x 951 points (2007 x 2853 pixels)
  with other modes including 626 x 890. This is a measured mismatch, not proof
  that the probe's UIKit context equals SpringBoard's live configuration.
- `CADisplay.nativeOrientation` and `currentOrientation` remain `rot0`, even
  with the donor/chosen rotation experiment. `display.rotation` is refused
  with "The device did not apply the requested rotation."
- Constructing `SBSDisplayConfigurationContext` with an arbitrary screenClass
  is NOT a valid surface-classification probe. Inspection of its factory shows
  surface type derived from the supplied class (24/25), so passing 0 and then
  reading type 0 says nothing about the live display registration.

The experiment's Preboot tree and host resolution were reverted to the exact
saved outer configuration. Do not add an "inner" startup switch that only
changes width/height: correct system display classification, pose, compositor
geometry and input mapping still need validation. `DuoDisplay/inspect.js` now
records both raw and probe UIKit configurations plus the actual CA direction.

## PR #728 integration: CPU and fold posture (2026-10-27)

Source: https://github.com/Lakr233/vphone-cli/pull/728 at
b03f0b823e7a48bafde6c0eabcafd8acedebcfc0. The initial fixed-inner experiment
above did not test Apple's `V68VM2025` subtype or
`SBSTestAutomationService.setDevicePoseOverride`. These are now integrated,
along with full X1 cache lowering and the accompanying VirtualAudio guard and
service-profile fixes. The local CSSC kernel fallback is retained.

Pre-update measurements on the existing Duo after about 80 minutes uptime:
host VM process sampled at 163–181% CPU, guest launchd at 28.3% over 41 seconds.
`timed` had over 1,400 starts and a 6 MB per-process limit; multiple daemons
reported JETSAM_REASON_MEMORY_PERPROCESSLIMIT with normal global memory
pressure. The restart loop is real, but not sufficient to attribute all CPU
load: the PR identifies launchd's per-process on-demand X1 conversion and its
private code-page copies as an additional mechanism. Test full cache lowering
before increasing service ceilings. No Jetsam limit change is deployed here.

Deployment validation on the same guest:

- Installed bundle `2.13.8-local.51658268`; retained the existing CSSC-patched
  boot chain. A stopped-state APFS clone was saved before the update.
- The environment update lowered 24,606,071 instructions across 4,508 X1
  images (4,664 images visited, none skipped), then reattested the cache.
- About five minutes after boot, two successive five-second host VM samples
  measured 16.9% and 17.2% CPU. Guest launchd used 0.68% over an earlier
  59-second interval that included UI/RPC activity. These are short-term
  measurements, not a long-duration stability result.
- `timed`, `donotdisturbd`, `powerexceptionsd`, `CommCenter`, and `healthd`
  each reported one start and never exited. The timed limit remained 6 MB.
  audiomxd retained its original PID. Home and Settings rendered successfully.
- `display.posture` accepted open-flat/landscape-left and
  partially-open/landscape-right requests, but `device.screen` remained
  466 x 678 at scale 3 with orientation 0. The bounded SpringBoard log capture
  supplied no pose-application confirmation. RPC success alone does not prove
  a display transition. Restored closed/portrait after probing.
- The single outer scanout remains configured; second-display registration
  and compositor switching are still unresolved. No functional inner-display
  toggle is claimed by this integration.
- Full bundle build and signature verification passed; 91 focused firmware
  tests and 387 daemon logic checks passed. `git diff --check` passed.

## Fixed expanded startup (2026-10-27)

Scope was narrowed to a fixed expanded boot; runtime panel switching is not
required. The current prototype adds `vm config NAME --duo-display inner|outer`.
The selection survives manifest edits and firmware metadata refreshes; outer
remains 1398 x 2034. This is one primary scanout, not a second registered CA
display or a working physical display1 switch.

New evidence and changes:

- A bounded live SpringBoard log records the pose override, landscape-right
  orientation, 90-degree partially-open hinge and the subsequent settled event.
  The pose chain works, but its surface is still `.default`.
- Replacing only the VM product-id with the V68 donor product-id did not bring
  up SpringBoard and produced background-service failures. The exact original
  Preboot IMG4 was restored and a cold boot reached Home. Do not ship that
  product-id substitution.
- At a 1878 x 2670 scanout, this iOS 27.1 guest chooses a 669 x 951 at 3x UI
  mode (2007 x 2853), clipping its right and bottom edges. A fixed 2007 x 2853
  scanout matches the actual UI mode and renders the complete Home/Dock and
  two-column Settings. It retains the inner panel's portrait aspect ratio
  within rounding. No donor DeviceTree edits are required for this mode;
  the temporary display mapping and rotation edits were reverted too.
- The fixed startup option requests open-flat/portrait on a new guest agent
  connection. Outer explicitly restores closed/portrait. It does not expose
  a runtime fold button.
- The host inner outline has four transparent rounded corners, with radius
  `shortSide * 55 / 626`, from the donor inner panel's 55-point corner and
  626-point reference width. This scales the radius with the panel, including
  when using the larger render mode, resizing and rotating. The outer panel
  keeps its existing hinge edge.

Validation in progress: full bundle build and 27 focused manifest/geometry
checks passed. A host-window capture confirms the full canvas, four rounded
corners and titlebar gap. Automated touch injection has not yet produced a
verified navigation; do not claim input acceptance or full inner-panel support
until that is resolved. The original manifest and full VM clone were retained
for rollback. Host security settings and the camera implementation were not
changed.

### Expanded-mode touch interception investigation (2026-10-27)

The user confirmed that edge gestures work while ordinary taps do not, and
that dismissing Control Center restores taps for a few seconds. A disposable
UIKit touch probe confirms this is not merely an automation failure. The outer
466 x 678 mode delivers exact coordinates; the expanded 669 x 951 mode normally
does not deliver touch events to the foreground app.

A temporary SpringBoard diagnostic found touch suppression disabled with no
assertions, but a 669 x 951 `SBStatusBarWindow` whose midpoint hits
`STUIStatusBarForegroundView`. Full-height status-bar views also occur in the
Home and main scene-layout hierarchies. A two-second diagnostic sweep reducing
oversized status-bar frames restored complete began/ended events at known
points (210/310, 410/610, 260/360, 300/600 and 280/380 in separate trials).
The active DynamicSplitSmallIsland provider reports a native height of
53.6667 points; this worked in place of the initial diagnostic value of 62.
This is evidence for status-bar geometry/event-region interference, not proof
of its upstream cause or a completed display1 registration.

Do not ship the diagnostic unmodified. Returning nil from status-bar hit-test
methods did not restore delivery. Clamping four status-bar classes' frame and
bounds setters also failed. Repairing frames synchronously from layoutSubviews
caused a repeated-layout CPU loop and was immediately removed. The polling
probe still needs a long-delay/Control Center regression and a version without
logging, hit-test inspection or UIKit linkage before it can be considered a
bounded compatibility workaround. No firmware patch has been added for this
investigation; the original accelerometer library is backed up for restoration.

The user subsequently confirmed sustained manual taps after opening/dismissing
Control Center and waiting ten seconds. A reduced probe with no hit-test calls,
no diagnostic logging, and no UIKit link also delivered exact began/ended
coordinates (310/410). The compatibility implementation now lives in
`Accelerometer/VPhoneDuoStatusBar.m`. It is explicitly enabled by the host's
Duo `inner` selection file and rejects outer-sized screens. It repairs only the
four observed status-bar classes, using the existing provider's native height.
It runs every two seconds outside layout callbacks; this is a bounded polling
workaround, not a native display1 fix. There may be a short interception window
before the next repair when iOS reconstructs these views. Final cold-boot and
Control Center validation of the packaged build is pending.

Final validation: `2.13.8-local.c930073d` is installed and bound to Hom-iPhoneDuo
with `duoDisplayMode=inner`. The full bundle build, signature verification,
accelerometer regression checks and diff whitespace checks passed. After a
cold boot, the guest library hash matches the packaged artifact
(`aa40d4fc8abdf0d99d8398ee3445e7d7deb36fd46374a3c5be4246b3eb1c1b86`)
and the root filesystem is read-only again. A screen-derived tap on the Home
Settings icon launched Preferences, and tapping Display & Brightness changed
the right pane as verified by the accessibility tree. These used a 150 ms
complete down/up sequence; the automation helper's short tap intermittently
did not activate Settings rows despite the probe receiving its touch events.
The same repair source passed Control Center open/dismiss followed by a delayed
exact-coordinate touch; the user also confirmed continuous manual taps after
a ten-second wait. The temporary probe app and diagnostic files were removed.
Camera and host security configuration were not changed. Fixed inner remains a
single-primary-display compatibility mode with outer startup retained.

### Landscape startup / rotation investigation (2026-10-27)

A default usable landscape boot has NOT been implemented. The fixed-inner mode
still starts portrait. Testing found the following distinction between motion,
arbitration and applied scene geometry:

- The backboardd accelerometer sink reports enumerated and delivered landscape
  (device orientation 4), while `display.orientation` still returns 0.
- This iOS 27 SpringBoard uses `SBFDevicePoseProvider`, not the old
  `accelerometer:didChangeDeviceOrientation:` callback on the traits pipeline
  manager. Its live pose is unknown even after successful posture RPC replies.
  Backlight is on, live rotation is supported and no deferral or orientation
  lock assertion explains the refusal.
- `TRAArbitrationDeviceOrientationInputs` can be experimentally supplied with
  landscape, but the layout remains portrait. Forcing supported orientation
  masks makes the compositor report 270 degrees, with clipped portrait Home
  content and incorrectly transformed app snapshots. Rejected: a changed
  orientation readback alone is insufficient acceptance.
- In a disposable probe, screen class 24 produces surface type 1 and no full
  orientation support; class 25 produces surface type 2 with full support.
  These constructors do not prove live inner registration. SpringBoard-only
  overrides of the context factory, initial UIKit context, context accessors
  and UIScreen screen type did not produce a usable landscape layout.
- Disabling continuous-fold input in a temporary provider and delivering its
  native accelerometer callback produced a valid landscape pose and a
  landscape system-arbitrated interface orientation, while the layout
  coordinator and applied interface still remained portrait. The scene/display
  classification and actuation path therefore remain the blocker.

All runtime overrides, forced orientation inputs and diagnostic timers from
this investigation were removed. The guest library was restored from installed
bundle `2.13.8-local.c930073d` and the guest cold-started in the existing fixed
portrait mode. No donor DeviceTree or host security changes were applied.

Separately, the old orientation gate installer had no guard against its
constructor's five-second retry saving its own wrapper as the original IMP.
The source now installs each available legacy hook once, and allows both setup
and accelerometer callback hooks when available. A regression invokes the
installer twice and verifies that native pipeline setup still runs exactly
once per call. The accelerometer native tests passed. This source correction
is not claimed as a fix for iOS 27's different pose/scene path and has not been
deployed as a new bundle in this investigation.

### Duo startup picker and framebuffer identity probe (2026-10-27)

Launchpad 2.14.0 adds an inner/outer startup menu only for a single selected,
stopped iPhone19,4 machine. Other models and batch actions retain ordinary
Start. The choice runs the bound bundle's `vm config --duo-display` before
launching; an older CLI without that option fails with an update message.
Existing 2.13.8 machine bindings remain compatible. Product-type and bundle
compatibility tests passed, and the signed Launchpad was built and installed.
Interactive menu verification is pending owner unlock of the Mac.

A new, unvalidated host experiment sets the inner display's private
`VZMacGraphicsDisplayConfiguration._setDisplayIdentifier:` to the donor
DeviceTree display1 framebuffer UUID. Runtime introspection confirmed that
this setter accepts an NSUUID and reads it back. The existing host uses nil,
and the guest reports a null CADisplay UUID. Donor display0 and display1 have
different framebuffer identifiers; earlier profile experiments omitted these
identifiers, so they did not test association with the actual virtual output.

A temporary DeviceTree containing both donor display child profiles (retaining
their UUIDs and removing physical phandles) booted with the previously approved
bundle. Both nodes appeared in the guest registry, but the display UUID remained
null, as expected for that unchanged host. This establishes only metadata
transport, not native inner classification or landscape support. Original
Preboot firmware was restored and the machine stopped after this probe.

The UUID host experiment compiled as a 2.14.0 bundle. Installation is waiting
for Launchpad's normal macOS administrator authorization after the app update.
It has not been bound or booted. Do not treat the UUID setter, an orientation
RPC success, or a constructed class-25 context as proof of working inner
registration. Required acceptance remains cold landscape startup plus actual
scene geometry, rotation, window aspect, scaled four-corner clipping and touch.

Follow-up after owner authorization: Launchpad's actual Duo menu was opened
and showed both localized startup actions. Selecting the existing iPad showed
an ordinary Start button; it was not started or rebound.

The first UUID prototype incorrectly passed NSUUID to `_setDisplayIdentifier:`.
Virtualization's full configuration validation raised an Objective-C exception.
Runtime ivar inspection identifies that property as NSString; the inherited
`_setUUID:` property is NSUUID. The corrected prototype sets both with the
appropriate types. Bundle `2.14.0-local.3f5383a3` booted and the guest's actual
CADisplay and FBSDisplayConfiguration both reported the donor inner UUID.
This is verified identity transport, not verified inner scene registration.

Adding donor product-id plus both UUID-bearing profiles enabled
CMMagicPoseManager availability but did not produce a usable SpringBoard
screen. Mapping only the inner profile to index zero also did not establish
usable startup. The exact original personalized Preboot DeviceTree was restored.

UIKit's legacy UIScreen `_screenType` derives a cached value from a geometry
matching table. Its numeric values are NOT the SBS display-class namespace:
for example UIKit types 24/25 describe 1179x2556 and 1290x2796 screens, whereas
the SBS factory maps its classes 24/25 to surfaces 1/2. Do not infer an actual
Duo registration from a UIKit numeric override or an SBS test constructor.

A factory-only SpringBoard probe, pose-provider bridge and native primary
content assertion are being tested as a fixed-inner compatibility path. They
are not a released solution. Important test correction: the host runs
`syncEnvironment()` on guest connection and replaces hand-uploaded hook
libraries with the bound bundle's versions. A respring can also reconnect the
guest and trigger that synchronization. Always compare `environment.status`
with the intended artifact; old diagnostic files are not current evidence.
Some manual hook/cold-boot observations above therefore remain provisional.
The next test packages the diagnostic component in a complete signed bundle,
so synchronization cannot silently replace it. Installation again awaits the
owner's administrator authorization after the Mac auto-locked. The Duo is
stopped and the original Preboot firmware is restored; no working default
landscape startup or rotation acceptance has yet been demonstrated.

The packaged staged probe (`2.14.0-local.ff84c0c9`, stage 0, read-only) produced
live SpringBoard evidence after explicitly writing and verifying the stage
file and relaunching SpringBoard. Its resolver description is more specific
than the SBS factory probe: `FoldingDual` is the prevailing policy, wants
primary content on `.inner`, and the only connected SBFDisplayProxy has the
correct inner UUID but `surfaceType: .default`, with applied/target content
modes `.unknown`. The coordinator has no primary or active window scene.
This is a live object observation, not a constructed test context.

The next staged experiment hooks the resolver's existing
`_surfaceTypeForWindowScene:` classification for the single main scanout to
return inner (2), rather than changing an SBS test-context factory. It is
stage 5 in the temporary, opt-in `VPhoneDuoInnerExperiment.m`; the explicit
`/var/db/vphone/duo-experiment-stage` file is required. It is not enabled by
ordinary startup and is not production code. Bundle
`2.14.0-local.d561523c` compiled and passed signature validation; its install
is waiting for renewed owner administrator authorization. Previous staged
factory/pose combinations did not establish stable usable startup and must
not be promoted as fixes. The Duo is stopped pending this classification test.

### Fixed-inner primary scene and landscape follow-up (2026-10-27)

The resolver classification test subsequently established a primary/active
`SB-main` scene. The compatibility component now scopes inner classification
to hardware identifier `BF0DC480-5EE2-4EC1-B02B-C75E94759832`. For the single
connected inner proxy it releases the resolver's two-display readiness gate
and invokes its existing content-mode update. It does not synthesize a cover
display or change `SBWindowScene.surfaceType` from its physical default.
The original Preboot DeviceTree remains installed; donor product identifiers
caused Recovery Assistant startup and were reverted.

Cold startup into landscape and a matching wide host window have been
observed. AX's legacy active-interface-orientation getter stayed portrait
while CADisplay rotated, so the daemon now reads updated CADisplay orientation
for this exact inner identifier. Native pose requests keep the hinge open;
four-angle mapping/fallback unit checks pass. This is not yet complete
rotation acceptance: touch remains under investigation.

Live opt-in SpringBoard diagnostics show no touch-suppression assertion, but
full-screen status-bar foreground/legibility views intercept body points,
including in the app-switcher window. The main status-bar window can already
shrink to 53.6667 points. A follow-up changes subtree repair from transformed
`frame` coordinates to local `bounds`; the complete signed diagnostic bundle
`2.14.0-local.1cbee490` is awaiting the normal helper installation. Do not
claim touch or four-direction rotation fixed until the probe receives events
after rotation and after Control Center dismissal. Temporary routing probes
and debug files must be removed from the final build.

Further validation rejected the bounds-only repair: it moves a window's
visible status bar toward its center, and the probe still receives no taps.
Explicit status-bar orientation and selecting the native
`AxisAlignableSplit2853_VM` provider also did not restore input. Those are
temporary, opt-in diagnostics, not production fixes. Setting the VZ digitizer's
association to the display configuration UUID, then also aligning that UUID
with the framebuffer identifier, likewise has not restored injected taps.

A simultaneous input/unified-log capture finally exposed a separate, earlier
failure: backboardd repeatedly reports
`BKDisplayConvertCAScreenLocationToContext: unknown displayUUID/systemDisplayIdentifier:(null)`.
The events reach BackBoard, but its default-display lookup cannot resolve the
new explicit inner scanout. The old no-UUID touch/status-bar observations
therefore do not validate this native-identity configuration. Adding
`BKSHIDEventSetDigitizerInfo` to an ordinary HID client event is rejected as
"non-redirect attribute data"; do not promote that experiment either.

Read-only inspection of the guest's `/usr/libexec/backboardd` resolves the
failing path through `BKDisplayController`'s coordinate conversion and target
lookup methods. The next packaged compatibility probe maps their nil display
argument to the real inner UUID only when CADisplay's main UUID exactly
matches V68 display1. Explicit IDs and other machines retain native behavior.
`Tests/DuoTouchDisplayTests.m` exercises mapping, outer fallback, point/target
arguments and output pointer ABI; it passes on the host. Complete bundle
`2.14.0-local.935ea9ec` compiled, but its installation is currently waiting for
the owner's renewed administrator authorization. Actual input acceptance and
four-direction regression remain pending. No firmware/security change was
made for these probes.

### Fixed-inner follow-up, 2026-10-28 (validation in progress)

The BackBoard nil-display compatibility must cover geometry and embedded target
lookups as well as point conversion. Mapping only coordinate conversions gives
finite points without delivering application events. The expanded set includes
the 64-byte geometry result and 128-byte transform result; standalone ABI and
argument/output tests pass. An earlier live probe received distinct ended events
at (400, 300) and (700, 450) in a 951 x 669 application canvas with the temporary
status-bar crop. That crop is unsuitable for the requested native Duo sidebar.

On this guest, legacy synthetic magic-pose events leave panel orientations and
stable orientation ambiguous. Supplying the missing fields only for synthetic
fixed-inner requests, and resolving the inner surface's ambiguous orientation,
allows CADisplay and AX to agree at all four requested interface rotations. The
inner panel has a +90-degree physical mount offset: UI 0/90/180/270 requests use
device poses 3/1/4/2 respectively. The daemon and startup request use that map.
This is not yet four-direction input acceptance: the full native sidebar canvas
still interferes with application input in current tests.

The user's requested sidebar uses the native AxisAlignableSplit status provider
and live round battery view. UIKit hit-test filtering of empty transparent views
alone did not restore input. Merely changing `_visualProviderClass` also leaves
already-created DynamicSplitSmallIsland provider instances in app overlays;
provider lifecycle must be verified, not inferred from the class override.
SpringBoard's status-bar window was observed retaining orientation 1 while its
wrapper and the main scene were orientation 4. A scoped status-window orientation
mask and provider reconstruction are being tested. Diagnostic files/stages remain
temporary, and this state is not a production acceptance result.

Live acceptance checkpoint, 2026-10-28 02:00 CST:

* Bundle `2.14.0-local.31049e9e` delivered exact probe ended coordinates at all
  four turns: UI 0 -> (230,320), 180 -> (240,330), 270 -> (250,340),
  90 -> (260,350). Portrait bounds were 669 x 951, landscape 951 x 669.
* Existing STUI visual-provider instances must be cleared before native
  `resetVisualProvider`, then the explicit AxisAlignableSplit2853_VM class
  selected and preparation requested. Setting only its class ivar, or reset
  without clearing the old instance, leaves DynamicSplitSmallIsland active.
* In modern scene-based mode `SBStatusBarWindow.setOrientation:` does not
  update the window. An orientation-mask override did not solve that. The
  packaged probe uses `_setStatusBarWindowOrientation:` plus UIWindow's
  `_updateToInterfaceOrientation:duration:force:`; its window/bounds now
  match 951 x 669, and application sidebars show upright time and round
  battery at the upper right. The earlier mask experiment is redundant.
* Home's original status-bar view is hidden/hosted separately. A new wrapper
  attached to Home had no current native provider/data, so it did not render.
  The next full bundle reuses the existing live system wrapper in the Home
  window rather than constructing a second status-server client.
* Full bundle `2.14.0-local.67db9b49` compiled successfully and is waiting
  at Launchpad's administrator-install step. It has NOT been live-validated.
  Desktop tooling explicitly refuses SecurityAgent access, so the owner's
  administrator dialog remains the external blocker despite authorization
  to automate entry. Do not bypass it through another route.

The cleaned inner identity/pose file removes stage-8 Darwin/motion experiments;
BackBoard file diagnostics have been removed. Status/sidebar diagnostics,
file-based stage 9 and temporary guest flags still remain pending the Home
acceptance result. Before release, consolidate status handling, remove those
probes, align the stopped guest environment, and cold-test default landscape,
all four input rotations and outer rollback. Control Center gestures are not
accepted yet: the automated top-right and alternate edge swipes did not open it
in the current run. Do not claim system gesture regression complete.

### Clean sidebar acceptance and wallpaper follow-up, 2026-10-28

The previous pending sidebar checkpoints are superseded by live acceptance of
`2.14.0-local.0194d9ee`. Its stopped guest environment was updated and cold
booted into UI 90 (951 x 669). Home shows native time and circular battery at
the upper right; a direct host-window click opens Settings. The native probe
received ended events at the requested coordinates at UI 90/0/180/270/90:
(250,330), (265,340), (280,350), (295,360), (310,370). Portrait bounds were
669 x 951 and landscape bounds 951 x 669. Sidebar-hit, BackBoard-display and
daemon-orientation standalone tests passed. Temporary input/status flags and
the input diagnostics source were removed.

Home requires `SBMainDisplaySceneLayoutStatusBarView`'s native owner lifecycle
(`beginRequiringStatusBarForReason:`); manually attaching a wrapper does not
subscribe it to live state. Its generic-phone landscape frame has zero height.
The exact-inner, associated custom Home owner now supplies the full canvas
from `_statusBarFrameForOrientation:` while preserving native item layout and
empty-canvas hit filtering. Other owners and other display UUIDs pass through.

Wallpaper remains a separate open issue. At UI 90 the inspected
`_SBWallpaperSecureWindow` still has interface orientation 1 and 669 x 951
bounds, including its PBUIPosterSceneLayerHostView children. CoverSheet's
window is already 951 x 669/orientation 4, but its poster replica retains the
portrait canvas. UI 0 lock wallpaper is upright; UI 180 wallpaper is inverted;
landscape Home is dark. These are native wallpaper/scene geometry failures,
not a host-wide image flip (application text and touch remain correct).
An explicit-request diagnostic snapshot and a scoped wallpaper-window
orientation repair are compiled for investigation; this repair has not yet
been live-validated. Installation is waiting for the owner to unlock the Mac
and complete Launchpad's administrator authorization. Do not claim wallpaper
acceptance until both Home and lock screen have been checked in all four turns.

Control Center acceptance also remains open: high-level `input.swipe` rejects
some landscape coordinates as outside the screen even while `device.screen`
reports 951 x 669 and native `touch_sequence` succeeds. Earlier rejected swipe
attempts do not establish a native Control Center gesture failure.

Wallpaper native-controller checkpoint, 2026-10-28:

* `2.14.0-local.e963da43` was installed, environment updated and cold booted.
  Calling UIWindow's forced orientation update alone leaves the wallpaper
  backing window at orientation 1 / 669 x 951. It does not fix the issue.
* `2.14.0-local.9c52f004` was installed, environment updated and cold booted.
  Exact-inner landscape-content support plus
  `SBWallpaperController.willAnimateRotationToInterfaceOrientation:duration:force:`
  changes its `_WallpaperOrientationNotForYou` to 4. However, its root controller
  and `PBUIPosterWallpaperRemoteViewController` both still report supported mask
  2; the remote controller refuses autorotation. The nested
  `PBUIPosterWallpaperViewController.activeOrientation` is 4 while its
  `PBUIPosterViewController.activeOrientation` is 1. The wallpaper window remains
  portrait. This separates accepted controller state from actual scene layout.
* CoverSheet's window/controller interface orientation is 4, but
  `CSCoverSheetViewController.effectiveInterfaceOrientation` is still 1 and its
  override is 0. Its effective orientation governs the native lock content.
* The next compiled probe scopes all-orientation support to the two wallpaper
  controllers on the exact inner UUID, updates CoverSheet's effective override,
  and retries the native window/controller rotation path. It is waiting for
  Launchpad administrator installation; no live acceptance yet.

Darwin notify delivery is asynchronous: after requesting the explicit snapshot,
wait for completion and check its date before reading the file. Pulling it
immediately can return an old snapshot and falsely suggest that the new library
was not loaded. The installed, built and guest library SHA-256 values matched
for the native-controller checkpoint.

`2.14.0-local.2d213605` live follow-up: both wallpaper orientation masks are
now 30 and both controllers allow autorotation. CoverSheet's effective
orientation/override now correctly reports 4. The wallpaper UIWindow and the
nested PBUIPosterViewController still report orientation 1, and the lock
wallpaper remains sideways. Thus the mask/cover correction is insufficient.
The next diagnostic build adds an explicit-request, file-selected sequence to
compare Poster will/did-rotate callbacks, the wallpaper window's own orientation
setter, and its canvas layout. It is not an accepted release and is waiting
for the current Launchpad administrator install. Remove diagnostic actions and
snapshots before the final build.

Explicit-request wallpaper actions on `2.14.0-local.0e995a6f`:

* Stage 1 (Poster will/did-rotate) leaves its active orientation at 1.
* Stage 2 additionally sets the wallpaper UIWindow's own orientation. Its
  getter becomes 4, but bounds remain 669 x 951 and the image is still sideways.
* Stage 3 also changes the wallpaper window/root canvas to 951 x 669. Poster
  still remains portrait and the image is cropped; this is not a valid fix.
  The action file was removed and SpringBoard relaunched to discard the
  temporary geometry before installing another build.
* Read-only native call inspection identifies the cause of the Poster clamp:
  `PBUIPosterViewController.willRotateToInterfaceOrientation:` obtains
  `pui_fbsDisplayConfiguration`, calls exported `PBUISupportsDynamicRotation`,
  and substitutes orientation 1 when unsupported before notifying its variants.
  Thus manually issuing its rotation callbacks cannot overcome this check.
* The next diagnostic build compares actual FBScene settings updates (frame
  and interfaceOrientation, with the native Poster active orientation) and
  UIKit's complete window rotation routes. It compiled successfully and is
  waiting for administrator installation. No wallpaper fix is accepted yet.

Actual renderer checkpoint (`2.14.0-local.133e5fdf` / `.48c3bc0c`):
setting PBUIPosterViewController.activeOrientation plus both variant FBScene
frame/interfaceOrientation produces upright landscape wallpaper content.
However, `_UIScenePresentationView` remains 669 x 951 despite its scene frame
being 951 x 669. The image is cropped and the floating clock layer is incomplete.
The regular and legacy UIWindow rotation helper routes did not update the
wallpaper controller tree's cached interfaceOrientation (still 1).
Directly resizing the presentation/portal views moved clipping rather than
solving their coordinate-space mismatch, so this path is rejected.
A further diagnostic synchronizes UIViewController.setInterfaceOrientation:
through the wallpaper controller tree while retaining native scene updates;
its installation is pending. No wallpaper acceptance, outer rollback, or final
release is claimed. The file-selected temporary geometry was removed and
SpringBoard relaunched after these experiments.

### Evidence review before further wallpaper changes (2026-10-28)

This review makes no executable changes and does not install or start a VM.
Previous diagnostic stages are interventions, **not an unmodified baseline**.
A reduced, hash-linked extract is retained in
[Evidence/duo_wallpaper_geometry_2026-10-28.json](Evidence/duo_wallpaper_geometry_2026-10-28.json).
The original JSON timestamps use UTC. A snapshot taken in the action callback
can precede a remote scene's asynchronous acknowledgement; do not infer client
completion from a successful setter or a single immediate snapshot.

#### Corrected geometry findings

| Recorded stage | FBScene frame / orientation | Presentation view bounds | Remaining evidence |
| --- | --- | --- | --- |
| 9 | 951×669 / 4 | 669×951 | CoverSheet floating replica 669×951; image cropped |
| 13 | 669×951 / 4 | **951×669** | CoverSheet floating replica still 669×951; image cropped |
| 14 | 669×951 / 4, device orientation 3 | **951×669** | Lock snapshot metadata 951×669/orientation 4; image still cropped |

Stage 13 disproves the earlier blanket statement that the presentation view
cannot acquire landscape bounds. Keeping the FBScene frame in native/system
coordinates is consistent with an oriented presentation size. It does not
alone solve the renderer and floating-layer layout. Stages 13 and 14 differ
in both scene getter override and device orientation, so they do **not** isolate
either of those changes as a cause.

The Stage 14 lock controller owns a live FBScene. The Home controller has
`scene = 0x0` and uses a cached 669×951 snapshot whose orientation metadata is 4.
Thus the prior loop that updates only existing child FBScenes does not exercise
Home's snapshot-production/invalidation path. A size plus orientation field
alone does not establish a bad cache: native and oriented coordinate spaces
must be identified before interpreting it.

The private client-settings field `(20715)` contains `NSSize {669, 951}` in
these records. Its semantic accessor has not been identified. Do not label it
as the renderer's final canvas merely because its value resembles a size.

#### Native rotation gate and identity propagation

Previously retained native instructions for
`PBUIPosterViewController.willRotateToInterfaceOrientation:` show:

1. It gets `pui_fbsDisplayConfiguration` and calls
   `PBUISupportsDynamicRotation`.
2. `cmp w0, #0; csinc x23, x20, xzr, ne` selects requested orientation when
   supported, otherwise portrait (1).
3. It queries support again and selects update reason 64 or 32 before
   `_updatePosterScenesForReasons:updater:completion:`.

This is more than a getter mismatch: overwriting `activeOrientation` bypasses
part of the native rotation/update decision. The support function forwards to
soft-linked helpers. The actual trait names and value provenance behind those
helpers remain unresolved; do not replace them with unconditional YES based
only on this call site. The bytes and call-target observations were collected
by the earlier read-only guest probes, not newly decompiled by REA this round.

Current `VPhoneDuoInnerDisplay.m` DOES override `SBWindowScene.surfaceType` for
the exact inner hardware identifier. The earlier chronological note saying it
does not change this getter predates the current implementation. Its constructor
runs only in SpringBoard and adjusts the SBS context factory and resolver too;
this does not prove that serialized properties reach remote Poster scenes.

In stages 9/13/14, the Poster scene's ShellSceneKit settings still contain
`ssk_surfaceType = 0`, while the local root-scene compatibility getter returns
2. This is a **candidate propagation gap**, not proof that the serialized field
must be 2. Its producer, native consumer and enum namespace must be traced first.
`systemDisplayIdentifier` changes between these captures while the hosting
space remains `SB-display-BF0DC480-5EE2-4EC1-B02B-C75E94759832`. Do not mistake
a per-session system identifier for the hardware UUID or overwrite one with
the other without proving their mapping.

#### Kernel versus user-space boundary

The host deliberately supplies one graphics display, with inner dimensions
2007×2853 and an explicit inner UUID; it does not expose a complete two-panel
DCP topology. Existing measurements establish transport of that UUID into
CADisplay/FBSDisplayConfiguration. Donor DeviceTree experiments were reverted.

The existing IOMFB force-kern and SwapEnd-size compatibility work repairs the
framebuffer submission path: `_virt_Swap*` does not drive the vphone600 scanout,
whereas `_kern_Swap*` does. The size gates accept the matching request structure.
This differs from the current observed failure, where application text and
four-way touch work but wallpaper/replica geometry does not. It makes a global
swap failure a weaker explanation; it does not exclude every compositor or
kernel layer bug. No new kernel patch is justified by the present evidence.

The kernel skill's index/database exist, but its referenced per-image JSON
symbol dumps and XNU reference tree are absent in this checkout. No new kernel
dump, import or reverse mapping was performed here. Kernel-path conclusions
above are from existing source/research, not a fresh kernel disassembly.

#### Upstream and public references

- [PR #728](https://github.com/Lakr233/vphone-cli/pull/728) remains WIP at
  `b03f0b823e7a48bafde6c0eabcafd8acedebcfc0` in `0xJacky/vphone-cli`.
  Its [research record](https://github.com/0xJacky/vphone-cli/blob/b03f0b823e7a48bafde6c0eabcafd8acedebcfc0/Research/Guest/iphone_duo_bringup.md#L265)
  explicitly describes one outer panel and no inner destination for content.
  The [October 28 verification comment](https://github.com/Lakr233/vphone-cli/pull/728#issuecomment-6456703776)
  also excludes dual-display validation. It supplies useful posture/performance
  work, not an accepted inner-wallpaper fix.
- [PR #752](https://github.com/Lakr233/vphone-cli/pull/752) concerns X1/CSSC
  startup compatibility; [PR #702](https://github.com/Lakr233/vphone-cli/pull/702)
  concerns native orientation delivery; [PR #724](https://github.com/Lakr233/vphone-cli/pull/724)
  restores gravity/pointer state when rotation is rejected. None establishes
  Duo inner PosterBoard layout acceptance.
- Apple's [UIWindowScene.Geometry](https://developer.apple.com/documentation/uikit/uiwindowscene/geometry)
  distinguishes systemFrame, coordinateSpace and interfaceOrientation. Its
  [legacy interfaceOrientation](https://developer.apple.com/documentation/uikit/uiwindowscene/interfaceorientation)
  documentation directs callers to effectiveGeometry. This supports keeping
  these concepts separate, but does not document private FBScene or PosterKit
  contracts and cannot substitute for their implementation evidence.

GitHub search was bounded to this repository's Duo, wallpaper, inner-display
and rotation results plus the cited PR files/comments. No applicable wallpaper
fix was found in that scope; this is not a claim of absence across all sources.

#### Required evidence before another bundle

1. Resolve `PBUISupportsDynamicRotation`'s soft-linked trait queries and compare
   their actual input with an ordinary app on the same inner display.
2. Trace how Poster scene creation obtains ShellSceneKit display traits and
   rendering geometry. Determine whether the root getter override misses this
   serialization path, and identify the consumer of private size field 20715.
3. Trace Home snapshot generation/selection separately from the live Lock
   scene, including orientation and hardware/configuration cache keys.
4. Trace CoverSheet's floating replica frame from its native owner. Do not
   resize portal subviews or rotate the complete host framebuffer again.
5. Only after an identified producer/consumer mismatch, implement one scoped
   correction. Validate clean cold boot and Home/Lock in all four orientations,
   touch, scaled corners and outer fallback before promoting a bundle.

REA 6.7.0 registration and native Mach-O inspection were verified. BackBoard
artifact SHA256 is `bade2cec2b463615ac141a2aaf11156757ef9f3118a9090c82eb6e3903258dfe`,
UUID `7D0A0640-658B-3B39-AB78-31AAF5BCAB30`, arm64e.x1, iOS SDK/minimum 27.1.
Evidence ID:
`ev_ad17252e988a7e085ae8a02942a746c78a07070bb29c392aa310e6f3159cab18`.
Initial Hopper bridge attempts failed with `Cannot launch Hopper! Connection
is invalid.` and reported incomplete cleanup. This is an engine-connection
failure, not a missing REA skill. A user-reported Hopper recovery is being
verified separately; successful metadata inspection is not successful native
function analysis.

After the owner reported Hopper recovery, desktop inspection showed a healthy
empty `Untitled` Hopper window (`Hopper is ready`, no loaded strings/document).
REA nevertheless retained its prior owner with `open:false`,
`cleanup_pending:true`, no provider binding and no observed process lineage.
A query on that same connection returned `target_unavailable`; a new CLI open
was refused because the retained owner still held the target. No further open
loop, manual lock deletion or application/security modification was performed.
The remaining tool prerequisite is REA MCP connection recovery and confirmed
cleanup of its retained runtime, not another Hopper GUI launch. No additional
native function result was obtained, and no wallpaper fix was deployed.

### Desktop-first wallpaper compatibility path (2026-10-28, verified on Duo)

The owner prioritized Home wallpaper and deferred Lock Screen work. Replace
`VPhoneDuoWallpaper.m`'s staged window/scene mutations, global scene getter
hooks and forced rotation with a Home-only snapshot presentation fallback.
Read the native UIImage under `PBUIPosterHomeViewController`'s
`PBUISnapshotReplicaView`, and display it behind the root Home view's content
using aspect-fill and its existing oriented bounds/autoresizing. The fallback
is noninteractive, accessibility-hidden and exact-inner-UUID scoped. It uses
no wallpaper filename, private cache invalidation, global orientation setter
or Lock scene change. Missing native snapshots remove the fallback.
A bounded one-second controller/snapshot scan detects wallpaper image changes;
unchanged images are neither copied nor reassigned. This is a static snapshot
compatibility path, not native live PosterBoard rotation support.

The complete VPhone bundle compiled successfully, as did the standalone
sidebar-hit, touch-display-routing and daemon-orientation regression tests.
After the owner completed administrator verification, Launchpad installed
`2.14.0-local.22383718`. Hom-iPhoneDuo was stopped, bound to this bundle with
its guest environment updated, then cold-started and unlocked. The boot chain
was unchanged; no new kernel, DeviceTree or host security change was required.

Live acceptance on this bundle:

| UI rotation | Home wallpaper | Native tap on Settings |
| --- | --- | --- |
| 0 degrees | Upright portrait, full canvas | Opened com.apple.Preferences |
| 90 degrees | Upright landscape, full canvas | Opened com.apple.Preferences |
| 180 degrees | Upright portrait, full canvas | Opened com.apple.Preferences |
| 270 degrees | Upright landscape, full canvas | Opened com.apple.Preferences |

Each tap used input.touch_sequence on the screenshot-derived icon coordinates;
apps.foreground independently verified Settings. Home return at 270 and 90
degrees retained the wallpaper. The final macOS window screenshot at 90
degrees also showed the correct wide canvas and four rounded screen corners.
The source image remains aspect-fill: landscape crops the portrait snapshot
without stretching, black bars or the previous clipped wallpaper rectangle.

Screenshots were captured as /tmp/duo-home-fixed{0,90,180,270}.png and the
application-return checks as /tmp/duo-home-return{0,90,270}.png. The four initial
orientation images and final landscape image are also retained in this task's
artifacts/duo-home-wallpaper-2026-10-28 directory. The bundle SHA256 is
`a925d93318e2f8b88b6b02a5a8a77782fd25781acf0b6524c5454c5d581037a4`;
Launchpad preflight and policy passed. It is now the default bundle and Duo
is left running at UI 90 degrees. Hom-iPadMini's binding was not changed.
The temporary com.vphone.duotouchprobe test app was uninstalled after validation.

This accepts the static Home presentation fallback on the tested fixed-inner
configuration. Live PosterBoard effects, changing the selected wallpaper,
Lock wallpaper, and an outer-screen launch were not revalidated in this run;
it does not claim native PosterBoard rotation support or a Lock Screen fix.

### Application status-bar transition timing (2026-10-29)

The owner reports a normal top status bar briefly appearing when opening an
app, then being replaced by the right-hand time/circular battery. The accepted
sidebar code only corrected newly created/reused app bars on a one-second
timer, including suppression of SBStatusBarWindow's legacy wrapper. Thus a
new scene could commit its original provider before that correction. Cached
runtime method inventories confirm the native owner factory
`createStatusBarWithFrame:interfaceOrientation:reason:` and layout method
`_layoutStatusBarForOrientation:` on SBMainDisplaySceneLayoutStatusBarView.

Configure the returned wrapper synchronously before the factory caller can
present it, and reconcile before/after native layout to handle reused bars.
Use the same accepted provider reset and orientation logic. A per-view guard
avoids recursive configuration. Suppress only SBStatusBarWindow's own wrapper
when it is assigned or asked to unhide (including animated transitions).
Scene-owned status bars retain native visibility/alpha. All changes remain
SpringBoard-only and exact-inner-UUID scoped; the timer remains for Home and
window-orientation recovery, not app first-frame configuration.

Standalone lifecycle coverage verifies the wrapper at factory return, its
state on entry to the first native layout, reuse that resets the axis, all four
orientations, immediate legacy suppression, scene-bar visibility, inherited
base-view method isolation, and outer/missing-display pass-through. Existing
empty-canvas hit tests pass. The full VPhone bundle compiled successfully;
BackBoard touch-display and daemon orientation regressions also pass. Sequential
baseline screenshots of Settings return and cold launch were too slow to
establish frame-by-frame absence/presence of the reported brief flash; they are
not a substitute for validation of the new lifecycle path.

Launchpad install-local is currently waiting for administrator verification
(`installing=true`, `canInstallBundles=false`); the running guest and default
remain `2.14.0-local.22383718`. The replacement has not been deployed into Duo
and no live first-frame acceptance is claimed. A built-in VZ recording captured
Home throughout the attempted app-launch test, so that recording likewise
does not establish the state of the app transition.

Live follow-up: bundle `2.14.0-local.b704559b` installed successfully and was
deployed into Hom-iPhoneDuo. Settings renders an upright sidebar, but Home's
sidebar rotated sideways into the middle of the right edge. This build is not
accepted or promoted. The new hooks also ran on the custom Home owner, whose
rotation is already coordinated after its window by the existing refresh path.
Exclude the associated VPhoneDuoHomeOwnerKey owner from the new factory/layout
configuration, preserving Home's accepted lifecycle. A regression now verifies
that the custom owner's creation and layout pass through unchanged while app
owners are prepared synchronously. The scoped follow-up still needs live tests.

The Home-exclusion follow-up passes the complete bundle build and the extended
sidebar tests, including custom-Home pass-through. Its install-local request is
waiting at a new administrator prompt after the authorization cache expired.
Do not start a second install. The default remains the accepted wallpaper
bundle 22383718; the running Duo still uses the unaccepted b704559b test build.
After approval, bind the new bundle with --update-environment while stopped,
cold boot, and verify Home, app opening, four rotations and touch before
changing the default. Do not report the flash eliminated from build/tests alone.

The owner approved the follow-up, and `2.14.0-local.49d5f719` was installed
and bound with its guest environment updated. Home's sidebar and wallpaper
are correct again. However, a 16-frame host-window capture of opening Settings
still shows the rectangular top battery/time in frames 0 and 3, no indicators
in frame 7, and the intended sidebar in frames 11 and 15. The candidate is not
accepted; 22383718 remains the default. Settled Settings is correct, so a
settled screenshot alone would have missed this failure.

The retained live hierarchy `/tmp/duo-sidebar-switcher-full.txt` identifies a
separate app path: `SBDeviceApplicationSceneView` -> orientation wrapper ->
`SBFTouchPassThroughView` -> `STUIStatusBar_Wrapper` -> `STUIStatusBar` with
`STUIStatusBarVisualProvider_DynamicSplitSmallIsland`. Its time frame is
(392.667,20.3333;38.3333,23) and rectangular battery frame is
(782.667,24;32.6667,15), matching the captured transient positions after host
scaling. This branch does not contain SBMainDisplaySceneLayoutStatusBarView,
so the previous owner factory/layout hooks did not cover the observed app bar.
The current firmware method inventory confirms the application scene's
orientation getter, and wrapper layoutSubviews/didMoveToWindow signatures.

Replace the ineffective owner-factory/legacy-visibility hooks with wrapper
attachment/layout hooks gated by SBDeviceApplicationSceneView ancestry and
the exact inner UUID. Use that scene's orientation, preserving its transformed
coordinate space, visibility and alpha. Prepare before native layout/attachment
and reconcile replacement bars afterwards. A per-wrapper guard prevents
recursive layout; inherited UIView methods remain untouched. Home, Lock,
reuse-pool-only and other window bars remain on their prior lifecycle.
The revised regression fixture models the observed app ancestry without a
layout-status-bar owner and covers first layout, attaching an already laid-out
reuse-pool bar, native implementation replacement, all four orientations,
unknown orientation, outer/missing UUID, and Home/base-view isolation.
These tests pass; live acceptance of this new path is still required.

The app-scene-scoped replacement's complete VPhone build passed. A warm
Settings return on 49d5f719 also reproduced the top bar at frame 0, absent
indicators at frame 5, sidebar at frame 11 (~1.7s capture); its current time
rules out merely reusing the earlier 03:19 cold-launch screenshot. The new
install-local request is waiting at administrator verification. Do not retry
installation while it is pending. Running Duo remains 49d5f719; default stays
22383718. The next step is to complete this install, update Duo's environment
while stopped, and repeat cold/warm launch plus rotation/touch acceptance.

Live result for 738cab88: installation, environment update and cold boot
succeeded, but the first Settings launch still flashes the top bar. Recounting
hierarchy indentation reveals an error in the preceding interpretation:
SBDeviceApplicationSceneView is at depth 19, and the bar's orientation wrapper
is ALSO at depth 19. They are siblings under the same UIView (depth 18); the
status wrapper is at depth 22. It is not a scene descendant. Therefore the
scene-ancestry gate never matched; the earlier test fixture encoded that same
incorrect ancestry and could not catch the missed live path.

Correct the gate to the observed SBMainSwitcherWindow and use the status
wrapper's own orientation. The separate retained path report
/tmp/duo-sidebar-force-app-paths.txt explicitly confirms window=SBMainSwitcherWindow,
parent=SBFTouchPassThroughView, orientation=4, while the window remains portrait.
The corrected fixture now has sibling scene and bar branches, deliberately
leaves the scene's orientation invalid, and verifies all four bar orientations,
detached/reattached reuse, and Home/other-window exclusion. It passes. This
supersedes the earlier claim that the scene was an ancestor. 738cab88 is not
accepted and 22383718 stays default until live validation succeeds.

Live acceptance of `2.14.0-local.4d04cb46` (2026-10-29 evening): the corrected
SBMainSwitcherWindow gate is installed and Hom-iPhoneDuo's guest environment
matches this bundle. A cold Settings launch was captured in 18 consecutive
native-window screenshots over approximately 2.93 seconds. Inspected frames
0/2/5/9/13/17 show the right-side time/circular battery from the first sampled
frame, with no ordinary top time/rectangular battery. An 18-frame warm return
over approximately 1.74 seconds likewise has no ordinary top bar in inspected
frames 0/2/5/9/13/17; the sidebar appears as the native transition fades in.
This is sampled transition evidence, not an assertion about every display frame.

UI rotations 0/180 report 669x951 points; 90/270 report 951x669 at scale 3.
All four orientations show upright application sidebars, correctly proportioned
windows and rounded corners. Actual clicks opened Settings at 90 and 180,
selected Accessibility at 0 and General at 270. Return-to-Home checks at each
orientation preserve the full, upright static wallpaper and native sidebar.
No host or guest setting was changed by those Settings navigation tests.

The candidate passed the complete VPhone build, sidebar lifecycle/hit-region
regressions, bundle policy and preflight. It is now the default bundle; Duo
is running it at UI 90 on Home. Hom-iPadMini remains stopped and bound to
22383718. Duo's boot chain remains 2.13.5-local.cf4e2142. Bundle SHA-256:
`7daed8109176276f67e12c7b3452d0aaa2742b1a0a7b028ab7317026e6978dc8`.
The installed VM cdhash remains `793e453cfaa91dea58e2fa8e79248f554e64f36c`.

Settled guest screenshots and validation notes are retained in the local task
artifact directory `artifacts/duo-sidebar-transition-2026-10-29`; transition
frame samples are in the task's native-window tool output. This acceptance
does not extend the earlier static Home snapshot fallback to live PosterBoard
or Lock Screen wallpaper, and does not claim every third-party app was tested.
