# Virtual camera transport and capture hooks

## Duo preview investigation (2026-10-27, validation pending)

On iOS 27.1 (24A94425), Camera displayed black despite successful synthetic
source registration, increasing shared-frame counters, and the client logging
its first frame to two preview layers. The host test pattern also stayed black;
reading its shared buffer confirmed nonblack BGRA pixels with opaque alpha.
Relaunching Camera did not recover the preview.

The current candidate draws into a dedicated ordinary CALayer child instead
of AVCaptureVideoPreviewLayer.contents, separating the fallback image from
AVFoundation's backing store. It preserves centered aspect fill and disables
implicit animations while updating the surface bounds. First-use diagnostics
record the parent layer geometry and visibility.

The full bundle build, host camera-frame checks, and 1,183 frame-geometry
checks passed. Bundle 2.13.8-local.0925619b was installed and the Duo rebooted,
but live preview verification was interrupted to publish the code. This is
an unverified repair candidate, not a confirmed camera fix. Next: start the
test-pattern source, inspect the new layer diagnostics and screenshot, then
restore the Mac built-in source and verify moving preview and capture.

## Runtime boundary

### Mac built-in camera source (2.10.3)

Choose **Camera → Source: Mac Built-in Camera**, grant macOS Camera access,
then choose **Start Streaming**. `VPhoneBuiltInCameraProducer` captures the
built-in wide-angle camera at 1280×720 BGRA. It keeps only the latest copied
frame, including the actual row stride; the existing 30 Hz producer sends it
over the same VSOCK 1338 connection as Test Pattern and Video File. Switching
the guest between front and back does not open another host camera or socket:
`CamFixFrontCamera.m` already aliases both positions to the single vcam device.
Stopping streaming, selecting Off, switching sources or closing the VM releases
the capture session. A transport reconnect resumes only a requested stream,
so a stopped camera is not silently reopened.

Launchpad also needs its new `NSCameraUsageDescription` and
`com.apple.security.device.camera` hardened-runtime entitlement. Rebuild and
sign Launchpad with `Build/SignLaunchpad.sh`; updating only VPhone.bundle under
an older hardened Launchpad does not supply that entitlement. No guest patches
or new transport protocol are required. Permission denial, a missing built-in
camera and session failures are reported in the VM window.

In 2.10.4, the producer normalizes native sizes and YUV pixel buffers with
Core Image instead of rejecting anything other than 1280×720 BGRA. A session
preset does not guarantee output buffer dimensions (including Center Stage
capture). Frames are scaled with their aspect ratio preserved and letterboxed
to opaque black, then copied as BGRA for the same guest transport.

In 2.10.8 (build 50), built-in camera BGRA frames are reflected horizontally
with Accelerate before transport. Capture connection mirroring stays disabled
to avoid a double reflection. Both guest aliases receive the same mirrored
frame; file and test-pattern producers keep their own orientation. The host
checks include asymmetric left/right pixels across multiple padded rows.

In 2.10.9 (build 51), client preview layers use aspect fit with a unit
contents rectangle and black background. This preserves the full landscape
Mac camera field of view inside a portrait guest preview, with letterboxing
instead of the previous aspect-fill crop. The shared source pixels, mirror
and capture dimensions are unchanged. Live `2.10.9-local.b4e70b26` on
Hom-iPhone was verified with the Mac built-in source streaming: the guest
screenshot showed the complete 16:9 room/person view centered with black
letterboxing, rather than the earlier enlarged face crop.

In 2.10.10 (build 52), the requested framing returns to centered aspect
fill: use the middle portrait strip of the landscape source and fill the
preview height, cropping the sides without stretching. This supersedes the
2.10.9 full-field letterbox preference; horizontal mirroring is retained.
Verified live on Hom-iPhone with `2.10.10-local.bfa49d1b`: Camera.app
screenshot shows the centered portrait crop filling the preview height.

Host frame checks: `zsh VPhoneExecutable/VPhoneVirtualization/Tests/run-camera-frame-tests.sh`.

### iOS 27.0.1 black preview confirmed (2026-10-19)

On the existing `Hom-iPhone` guest (27.0.1, 24A446), both Core Bundle and
guest environment were `2.10.4-local.a953de6c`. Camera.app was the verified
foreground process. After starting the Mac built-in source,
`vphone-vcam.log` published 1280×720, 5120-byte-row frames through #10307,
but `vcamcaptured.log` reported `filter-chain scan: pc=0x0`,
`per-source filter not located`, `init-statics block-invoke lookup failed`,
and `data global resolve failed: _sSourceList not located`.
The microphone-only provider was installed instead. Frame receipt alone
does not establish the pixel contents or client delivery; synthetic video
source registration has independently failed, so a host format conversion
change cannot complete camera support on this guest. This reproduces the
open iOS 27 source-registration issue described in
`ios27_capture_microphone_source.md` §4. No guest restart, hook replacement
or firmware reinstallation was performed for this diagnosis.

### iOS 27.0.1 registration adaptation (2.10.5–2.10.6)

The pristine V54 24A446 SystemOS cryptex confirms the onceToken branch enters
the dispatch_once argument setup directly, rather than starting with a BL to
an outlined helper. The old scanner skipped it. Its per-source ownership
filter also uses x28/x20 instead of the hardcoded x25/x22. The new read-only
`VCamSourceScan` handles both wrapper shapes and verifies saved-register flow
and identical forward CBZ destinations. Against the complete pristine
CMCapture text it uniquely returns block `0x1ec331160` (invoke
`0x1b08b48f0`) and ownership filter `0x1b046e1c0`. These addresses are research
observations, not runtime constants. Live 2.10.5 confirmed both locations,
but stopped at the removed `FigCaptureSourceCreateFromBacking` export.

In 2.10.6 the prewarming-chain scanner follows the saved signing-id register
(x20 in 24A446, previously x22), with matching forward rejection branches.
The accessor is local, not exported, on 24A446: the full text scan uniquely
finds the call at `0x1b046df24` and accessor `0x1b04746c8`. Source creation
uses the exported `FigVideoCaptureSourceCreateFromBacking` when the legacy
export is absent. Its real caller at `0x1b04523b4` passes eight arguments:
allocator, backing, audit-token pointer, flags, two optional backing options,
client context, output pointer. The output moved from x4 to x7; the adapter
uses a separate function type and supplies nil optional objects, as the stock
caller does. The function stores its successful output through the saved x7
at `0x1b0a70ffc`. The legacy five-argument path remains available.

Run `make -C VPhoneGuestComponents test-vcam-source-scan` for the inline,
outlined, register-allocation, bounds and ambiguity cases. Registration
validates image data bounds, the invoke address and a heap CFArray; it no
longer guesses that the first init-store global is the list. No new kernel,
firmware or shared-cache file patch is involved. Live acceptance must show
`appended source`, enumerate a video device in Camera.app, and display
changing host frames; compile and offline scan success alone are insufficient.

Live 2.10.6 on `Hom-iPhone` created the source with status 0, appended the
list from 0 to 1, and Camera.app created an input with one port and
`canAddInput=1`. Frames reached the hook, but the screenshot remained black.
Camera initialized `AVSpatialOverCaptureVideoPreviewLayer` before adding its
input (`forVcam=0`), then polled `isRunning` while the real graph stayed stopped.
The preview pump started, but discovery was gated on `_setRunning:YES`, which
never arrived. In 2.10.7, newly tracked vcam sessions start layer discovery as
well as the pump, including the existing isRunning fallback. Idle processes
with no vcam session still do not start the scan. First successful image delivery
is logged once with dimensions and layer count.

Live 2.10.7 (`2.10.7-local.b38ac618`, build 49) passed preview acceptance on
`Hom-iPhone`: Camera.app PID 330 had one vcam input, discovered two preview
layers, mapped shm and logged `[preview] first frame 1280x720 to 2 layer(s)`.
A guest screenshot after source streaming showed the Mac built-in camera
image inside Camera.app rather than the prior black preview. Photo saving,
video recording and stop/reconnect behavior have not been revalidated in
this run; successful preview must not be reported as full capture acceptance.

Hardware acceptance still requires Camera permission for the rebuilt host app:
check a moving preview on both guest positions, photo and video capture, then
Stop Streaming / Off and confirm the Mac camera indicator turns off. Repeat
after restarting the stream and reconnecting the transport.

The host camera server sends BGRA frames over VSOCK port 1338. `vphoned`
receives them, writes a sequence guarded shared memory frame, and posts
`com.vphone.vcam.frame`. The optional `libvcamcaptured` hook reads that frame
and supplies it to camera clients. The host's **Camera server: connected**
status confirms the VSOCK connection only. It does not confirm that a camera
app or the capture hook is installed, loaded, or showing a preview.

The shared protocol and runtime paths are in
`VPhoneGuestComponents/VCamCaptured/VCamFrameProtocol.h`. All camera runtime
files live in `/var/mobile/Media/SimulatedCamera`: the shared frame
`vphone-vcam-frame.shm`, daemon log `vphone-vcam.log`, hook logs
`vcamcaptured.log` and `camfix.log`, and synthetic photo diagnostic
`vphone-synth-photo.bgra`. `vphoned` waits for the mobile home to be ready,
creates the directory with the mobile account as owner, and then opens the
shared file and binds port 1338. If setup fails during early boot, the
listener retries.

## Failure observed before the media path change

On 2026-09-24, the old daemon required a shared file and log under a directory
that this VM did not have. Shared memory initialization failed before the
VSOCK listener started. Its diagnostic went to the same nonexistent directory.
The host repeatedly logged POSIX error 54, `Connection reset by peer`. The
camera transport now uses the mobile media directory directly, without
installation-layout detection. A system log fallback retains diagnostics when
file logging fails.

At the 2026-09-24 transport test, the camera hook dylibs were not installed or
loaded. Since 2026-09-25, `cfw install` and the vphoned environment update
place both hooks in `/usr/lib`, and SystemHook loads them without a bootstrap;
see the camera hook note in `Research/0_binary_patch_comparison.md`. The
remainder of this section describes the earlier state. An initial check of fixed application directories also missed
Camera.app, but a later app registration query found
`com.apple.camera` in an application container under
`/private/var/containers/Bundle/Application`. The guest component archive
builds the camera hooks but does not install them; see
`VPhoneGuestComponents/README.md`. Camera.app preview and still/video capture
were therefore unverified.

## Transport acceptance on the media directory

On 2026-09-24, the integrated VM exposed `127.0.0.1:8765` for its guest API.
`/var/mobile/Media/SimulatedCamera/vphone-vcam.log` showed
`listening on vsock 1338`, `client connected`, and published frame counts.
The host Camera menu showed **Camera server: connected**. Shared memory was
read back through `GET /v1/files/content` with its `path` query set to
`/var/mobile/Media/SimulatedCamera/vphone-vcam-frame.shm`.

| Source and action | Shared memory observation |
| --- | --- |
| Test Pattern, streaming | Two samples were 8,388,672 bytes each. Frame index increased from 305 to 469 and the file hash changed. The header described 1280×720 BGRA, 5,120 bytes per row, and 3,686,400 pixel bytes. |
| Stop Streaming | Frame index remained 622 and the complete shared file hash stayed identical across two samples. |
| Video File, streaming | A generated 320×180 MOV was selected in the host menu. Frame index increased from 750 to 888 and the pixel payload hash changed. |
| Source: Off | Frame index remained 1,628 and the complete file hash stayed identical across two samples. The host menu returned to **Start Streaming**. |

This verifies the host-to-guest transport and shared frame publication,
including source selection and stopping. A full camera acceptance test still
needs a supported hook loading path: verify the hook is loaded, open
Camera.app's preview, compare visible frames against Test Pattern and Video
File, then test still and video capture separately. After the relocated path
passed its guest test, the stale
`/var/mobile/Library/vphone-vcam-frame.shm` and
`/var/mobile/Library/vphone-vcam.log` files from the earlier build were
removed through the guest API. A subsequent directory listing contained
neither file.

## The patch race that froze the whole VM (2026-10-05)

"Opening the camera freezes the VM" had two crashes behind it, both in
`cameracaptured`, and the freeze itself was never a camera-graph problem:
when the daemon crash-loops and launchd throttles it, every process that
first touches AVCapture — SpringBoard included — blocks in a synchronous
XPC to it, and the whole UI stops answering. The prewarm crash (row 23 of
the CFW table) was the first trigger; the second, still present after that
fix, was ours.

`vcc_patch_word` rewrites CMCapture shared-cache `__text` through
`vm_protect(RW|COPY)` → write → `vm_protect(RX)`. During that window the
whole 16K page has no execute permission, and the pages it touches are live
XPC server code the daemon runs constantly. Two crash reports caught the
race red-handed, both with the patching thread (`vcc_install_csp_requires_
master_clock_hook` → `vcc_scan_and_patch` → `vcc_patch_word`) in the same
process when another thread died fetching an instruction in a page mid-flip
(region snapshot: `r-x/rwx`, `SM=COW`):

| Report | Faulting queue | Dying frame |
| --- | --- | --- |
| `ipad-mini-01` `cameracaptured-2026-10-03-045638.ips` | `com.apple.coremedia.flashlight(34)-messages` | `__FigFlashlightGetClassID_block_invoke`, SIGBUS `KERN_PROTECTION_FAILURE` |
| `ipad-pro-13` `cameracaptured-2026-10-04-225558.ips` | `com.apple.coremedia.capturesource(523)-messages` | `captureSourceServer_handleRegisterNotificationForProprietaryDefaultChangesMessage`, same exception |

The capturesource queue is exactly what fires when a client opens the
camera: registering for source-change notifications is part of enumeration.
So "open camera" both restarts the daemon's traffic (after any crash or
restart, the hook reinstall at +3 s re-opens the window) and supplies the
thread that dies in it.

The fix (row 25 of the CFW table) stops the world around the flip:
`task_threads` + `thread_suspend` of every other thread, the two
`vm_protect` calls, the word write and the icache invalidation, then
`thread_resume`. The stopped section takes no locks, allocates nothing and
logs nothing — a frozen thread holding the malloc lock must not deadlock
the patcher — and all `vcc_log` calls moved after the resume. A mutex
serialises patchers. Kill-and-relaunch stress (killing `cameracaptured`
with Camera.app auto-reconnecting, the same collision the crashes came
from) is the validation.


## Idle cost (2026-10-09)

With no camera client, both camera hooks used to keep timers running for
the life of their process:

- `libvcamcaptured` armed its 30 Hz viewfinder and sink drive when it
  installed its hooks, three seconds after `cameracaptured` started. Each tick
  copied an empty stream list and an empty sink table and returned, which woke
  the daemon 27,000–28,000 times in 15 idle minutes (30.2/s, 2–3 s of CPU) on
  an iPhone 27.0 guest. The drive now runs only while it has a consumer
  (`VCamCaptured/Frames/VCamDriveGate.{h,c}`): `-[FigCameraViewfinderStream
  openWithDestination:]` and every new `BWImageQueueSinkNode` or
  `BWRemoteQueueSinkNode` start it, and the first tick that finds no open
  stream and no live sink stops it. A consumer that appears during a tick
  keeps it running; start and stop run under the gate's lock. The log shows
  `viewfinder drive started (30 Hz, start #N)` and `viewfinder drive stopped`.
  `make -C VPhoneGuestComponents test-vcam-drive-gate` covers the gate.
- `libcamfix` loads into every app-path process that has AVFoundation, which
  on a fresh guest includes SpringBoard, PosterBoard, AccessibilityUIServer,
  InputUI and most widget extensions. Each armed the 1 Hz preview-layer scan
  on its main queue as soon as AVFCapture loaded, walking the whole layer tree
  every second. The scan now starts with the first vcam-bound session that
  reaches `-[AVCaptureSession _setRunning:YES]`; the preview-layer
  initializer hooks still adopt layers directly. If `_setRunning:` cannot be
  hooked, the scan starts at install as before.

After both changes `cameracaptured` took about one wakeup a second in the same
window, and AccessibilityUIServer and InputUI dropped from about 900 each to
under 10. The numbers are in [`service_trimming.md`](service_trimming.md#idle-cost-of-vphones-own-components).
Camera frames were not checked live after the change: an iPhone 27.0 guest
publishes no synthetic camera at all (`libvcamcaptured` logs `_sSourceList not
located` on every boot), so nothing can start the drive there. That is a
separate open item ([iOS 27 capture sources](ios27_capture_microphone_source.md#4-the-virtual-camera-does-not-change-this)),
since closed ([below](#ios-27-the-camera-through-the-backings-provider-2026-10-22)).
On 26.6.2 the synthetic source is published and the Camera app starts.

## Front-camera clients and data-output frames (2026-10-10)

The synthetic source is published once, as a back camera
(`kFigCaptureSourceAttributeKey_Position = 1`). Checked on a 26.6.2 guest with
an app that asks for the front camera, records its
`AVCaptureVideoDataOutput` frames with `AVAssetWriter`, and serializes the
device's exposure numbers to JSON:

| Symptom | Cause |
| --- | --- |
| Preview shows frames, the sample buffer delegate gets none | The front lookup returned no device, so the session had no input; `cfx_session_is_for_vcam()` never matched and delivery skipped it. The preview layer pump draws every adopted layer regardless of its session, which hides this. `camfix.log` shows `forVcam=0` and no `[video delivery] tracking session`. |
| Delivered frames are 1280x720 landscape BGRA whatever the client asked for | Delivery ignored the connection's rotation and mirroring, the output's pixel format and the session preset. |
| `AVAssetWriter` fails with `-11800` (`-19642`) on the first frame | `-recommendedVideoSettingsForAssetWriterWithOutputFileType:` answers width, height and bit rate 0 because the graph never negotiated a format, and the delivered buffers were not IOSurface-backed. |
| `Invalid number value (infinite) in JSON write` | `lensAperture`, `ISO` and `exposureDuration` are 0 on the vcam device, so EV = log2(N²/t) − log2(ISO/100) is −inf. |

`libcamfix` now:

- answers an empty front or back lookup (`+defaultDeviceWithDeviceType:mediaType:position:`,
  `AVCaptureDeviceDiscoverySession.devices`) with the vcam device and reports
  its `position` as the side the process asked for last. A client that
  enumerates `+devicesWithMediaType:` and filters on position never says which
  side it wants; the `position` key of `SimulatedCamera/camfix-video.plist`
  (`front` / `back`) decides for it.
- delivers data-output frames the way a real camera would for that session:
  the preset's size (`AVCaptureSessionPreset640x480` → 640x480, 480x640 for a
  portrait connection), a centre crop of the upright shm frame, turned for
  180 / 270 and mirrored when the connection is, in the output's pixel format
  (BGRA, or 420v for 420v / 420f), in IOSurface-backed buffers carrying an
  `{Exif}` attachment. The crop and size plan is
  `CamFix/Frame/CamFixFrameGeometry.c`, covered by
  `make -C VPhoneGuestComponents test-camfix-geometry`.
- answers the recommended writer settings with H.264 at that size.
- reports aperture 2.2, ISO 100, exposure 1/30 s and 1/30 s frame durations,
  and stamps the same numbers, with a brightness value that follows the
  frame's mean luma, into each delivered frame's `{Exif}`.

With these, the app's front-camera session received frames, recorded and
uploaded its clip, and its back-camera photo capture still worked in the same
process. Limits: a 420f request gets 420v; delivery does not consult camera
authorization (the fallback calls the delegate directly, as before), so a
denied-permission path cannot be exercised; an iPhone 27.0 guest still
publishes no synthetic source (until the change below).

## iOS 27: the camera through the backings provider (2026-10-22)

[Issue #707](https://github.com/Lakr233/vphone-cli/issues/707) reported that
on an iOS 27.0.1 guest the Camera shutter and Safari's "Save Image" did
nothing, and blamed missing `photolibraryd`, `camerawriterd` and
`mediaassetd`. None of the three exists on stock iOS 27 (checked on the
mounted 24A435 System volume; `assetsd` is the Photos writer and is
present). On `photo707` (iPhone17,3, 27.0 24A435, default slimmed template,
bundle 2.10.1 from main) PhotoKit `performChanges` with an image, with
`addResourceWithType:fileURL:` and `UIImageWriteToSavedPhotosAlbum` all
saved, and so did Safari's "Save to Photos". The one real failure was the
Camera shutter: iOS 27 published no virtual camera at all, the open item
above.

### Where iOS 27 publishes sources

`_sSourceList` is gone. `-[FigCaptureSourceManager copySourcesWithType:
clientAuditToken:clientIsBincompat:]` makes each client's sources on
request: for every `FigCaptureSourceBacking` in
`+[FigCaptureSourceBackingsProvider sharedCaptureSourceBackingsProvider]
.sourceBackings` it calls `FigVideoCaptureSourceCreateFromBacking` (video)
or `FigAudioCaptureSourceCreateFromBacking` (audio), after filtering on the
backing's `attributes.deviceType` and `position`. The shared manager itself
is made from the same array (`+sharedCaptureSourceManager`'s once block ->
`-initWithBackings:fineGrainThermalMonitoringEnabled:…`). The provider keeps
the backings in an `NSMutableArray *_sourceBackings`, which
`-_addBackingsForSourceInfoDictionaries:` fills with
`-initWithMediaType:attributes:cachedProperties:formats:missingFormatNames:
synchronizedStreamUniqueIDs:unsynchronizedStreamUniqueIDs:` — the same
initializer `vcc_build_backing()` already used for 26.x, which wraps the
attributes dictionary in `FigCaptureSourceAttributes`. iOS 26.6.2 (23G90)
has the provider class but no `FigCaptureSourceManager`, and still serves
`_sSourceList`.

### The change

- `VCamCaptured/Synthetic/VCamProviderSource.m`: where
  `FigCaptureSourceManager` exists, the synthetic backing is appended to the
  provider's `_sourceBackings` once, when the microphone hook
  (`VCamMicrophoneSource.m`) builds the provider the daemon could not. That
  happens at the daemon's first source query, before the source manager is
  made. `vcc_install_synthetic` (the `_sSourceList` path) returns early there.
- `CamFix/Photo/CamFixCapturePhoto.m`: Camera.app on 27 takes photos with
  `-capturePhotoWithSettings:delegate:`, not the moment-capture trio. When the
  delegate is its `CAMCaptureEngine` (it answers
  `_resultsQueueRegisteredStillImageRequests`; the ivar is
  `__resultsQueueRegisteredStillImageRequests`), the hook now runs the
  moment-capture driver: the engine's request for the settings' uniqueID,
  then will/did/finish for it. With only `didFinishProcessingPhoto:` the
  engine filed the photo under captureID 0, logged "Have not received final
  callback", and saved nothing. Other delegates keep the single callback.
- `CamFix/Session/CamFixSessionGuards.m`: the `isRunning` lie made Camera.app
  log "Session is already running. Skipping call to startRunning", so
  `_setRunning:YES`, which started the preview-layer scan, never came and the
  viewfinder stayed black. The lie now starts the scan too.

The daemon only parses the session configuration (`cameraCfgs.count=1`,
"Wide back BGRA/1280x720"); it never builds a graph or asks the vendor for
the device, so preview and photos come from `libcamfix` in the client, as
the hook was designed.

### Validation

On `photo707` (iPhone17,3, 27.0 24A435):

- With a 1280x720 BGRA test frame written into the shared frame file,
  Camera.app showed the frame in its viewfinder, and each shutter press saved
  a 1280x720 JPEG of it to `DCIM/100APPLE` with the library thumbnail
  updated (three in a row).
- With the host streaming its test pattern (Features -> Source: Test
  Pattern -> Start Streaming), the viewfinder moved with the stream and the
  shutter saved the streamed frame.
- A third-party app got `vphone:vcam:0` from `+defaultDeviceWithMediaType:`,
  ran an `AVCaptureSession` and received a 24,635-byte photo from
  `AVCapturePhotoOutput`.
- Voice Memos recorded and saved a 14 s memo with the camera backing in the
  provider.
- No crash reports from Camera, cameracaptured or Voice Memos.

On `cam26` (iPhone17,3, 26.6.2 23G90), the source still goes into
`_sSourceList` (`appended source — list 0 -> 1`; no provider line). Camera.app
there also shoots with `-capturePhotoWithSettings:delegate:`: with the
previous `libcamfix` the shutter saved nothing, with this one it saved the
streamed frame, through the same callback sequence.

Camera.app video recording did not work on either at this point; see
[the next section](#cameraapp-video-recording-2026-10-22).

Restarting vphoned (or replacing the shared frame file) leaves the host
streaming into the old mapping: the host notices a dead connection only when
a send fails. Restart the VM, then start streaming again.

## Camera.app video recording (2026-10-22)

Camera.app's VIDEO mode records with `-[AVCaptureMovieFileOutput
startRecordingToOutputFileURL:recordingDelegate:]` into
`DCIM/.MISC/Incoming/<id>.MOV` and stops with `-stopRecording`; its
`CAMCaptureEngine` saves the file once the delegate gets
`-captureOutput:didFinishRecordingToOutputFileAtURL:fromConnections:error:`.
A vcam session's graph never runs, so the output never started: the timer
stayed at 00:00:00, no file was written, and with the request still open the
engine refused photos until Camera.app was relaunched.

`CamFix/Movie/CamFixMovieRecording.m` takes both calls for a vcam-bound
movie output and never calls the original:

- A recorder on its own queue writes the shm frame at 30 Hz with
  AVAssetWriter: H.264, 1280x720 (the frame as photos get it), in a
  QuickTime movie at the requested URL, timed from the first frame.
- After the first frame the delegate gets
  `-captureOutput:didStartRecordingToOutputFileAtURL:fromConnections:`; after
  `-stopRecording`, once the writer has finished, the didFinish callback
  with no error (or with one if the writer failed or no frame arrived).
- `-isRecording`, `-recordedDuration` and `-outputFileURL` answer for the
  recorder while it runs.
- When the session has an audio input the daemon records no sound either,
  so an AVAudioEngine input tap records the microphone into an AAC track,
  timed on the same uptime clock as the frames. The tap's buffer is copied
  into a CMSampleBuffer on the tap's thread, since the engine reuses it.

iOS 26.6.2's Camera.app lists VIDEO only when `-[CAMCaptureCapabilities
isVideoSupported]` is set. `-initWithHostProcess:` fills the `_videoSupported`
ivar behind it from `AVGestaltGetBoolAnswer(AVGQVideoCameraCapability)`,
which is NO on a guest, and other CameraUI code reads the ivar directly. The
hook sets the ivar after the initializer when the vcam device exists. iOS 27
dropped the ivar: `-[CAMUserPreferences supportedCaptureModesForCapabilities:
emulatingImagePicker:]` always adds photo and video, and
`-isSupportedMode:withDevice:` answers both with the camera. The hook does not
install there.

Validation, with the host streaming its test pattern:

| Guest | Result |
| --- | --- |
| `photo707`, iPhone17,3 27.0 | Timer counts; IMG_0013.MOV: H.264 1280x720 126 frames 4.13 s, AAC 44.1 kHz mono 4.12 s (mean -42 dB, the Mac's microphone); first and last frames differ; a photo right after the recording saves |
| `cam26`, iPhone17,3 26.6.2 | VIDEO tab appears; timer counts; IMG_0003.MOV: H.264 1280x720 130 frames 4.29 s, no audio track (the iPhone 26.x guest's Camera session has no microphone input); a photo right after saves |

No Camera, cameracaptured or assetsd crash reports on either. Not done: the
movie is landscape with no rotation metadata, like the photos; pause/resume,
slo-mo, time-lapse and cinematic modes; `-startRecordingMovieWithSettings:`
(the moment-capture movie path), which Camera.app did not call here.
