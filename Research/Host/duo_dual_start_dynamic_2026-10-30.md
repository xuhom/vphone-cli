# Duo dual startup and dynamic posture, 2026-10-30

Requested behavior: keep Launchpad's fixed-inner and outer startup entries.
The outer entry uses the dynamic cover/inner topology, allows runtime folding,
and resumes its last dynamic posture. Fixed-inner retains its hardware display
UUID and four-way rotation. Both keep the transparent physical screen mask.

Baseline is xuhom `2bfe1f32`, installed bundle `2.14.4-local.b95ab9f8`.
Hom-iPhoneDuo was stopped and Hom-iPadMini running. The Duo's manifest selected
fixed `inner` at 2007 x 2853, scale 3. The patch receipt already included the
foldable product identity, panel nodes, subtype and FoldDisplay hook. An APFS
snapshot `pre-dynamic-fold-20261030` was taken before testing; original host
config/posture records are in the task artifact directory
`artifacts/duo-dynamic-fold-2026-10-30/`. iPad is not part of this change.

## Cause and implementation

The window wrote `display-posture.plist`, but no startup code read it. The
outer entry unconditionally requested closed after connecting, overriding
the guest's stored hinge. The host also kept using the cover's logical panel
dimensions while showing the software inner display.

`VPhoneDuoPosture` owns the three stable states and their persisted record,
including compatibility with the existing `position` dictionary. Dynamic
startup reads that record (closed for a missing/invalid one). The control
restores it and suppresses window polling during restoration; later successful
postures update the reconnect target. Fixed-inner startup neither loads nor
overwrites the dynamic record and keeps its existing pose/rotation route.

The dynamic viewer selects logical cover 466 x 678 or inner 669 x 951.
FoldDisplay fills its cover scanout with the inner image with a small aspect
distortion; the host compensates with an ordinary AppKit parent's
scanout-shaped bounds inside a panel-shaped frame. The VZ view itself keeps
identical frame and bounds, so its hosted display layer needs no independent
nonuniform scaling. AppKit converts mouse coordinates through the parent's
same transform. The existing transparent mask follows the logical panel, so
open/book have four R55 corners scaled from the final inner size; closed keeps
the physical hinge edge. Fixed-inner layout is untouched.

Launchpad's two startup buttons already select these two topologies and need
no change. It remains 2.14.4; the compatible bundle candidate is 2.14.5.

## Validation

- Existing dynamic mode boots and replies `source: coremotion` to open. A
  baseline Home capture shows the desktop wallpaper in the inner layout.
- CoreKit posture/geometry/orientation tests: 36 tests in three suites passed.
  Nine parameterized AppKit cases cover closed/book/open at half, normal and
  double scale, checking actual NSView coordinate conversion through stretch.
  Persistence tests cover all states, old XML records and invalid records.
- Full Xcode `VPhone` bundle build passed. Installed bundle
  `2.14.5-local.c2c477b7` passed Launchpad policy and AMFI preflight. Duo's
  binding and guest environment were updated to it. Launchpad stays on the
  compatible 2.14.4 app; the running iPad stays on its previous bundle.
- Dynamic open survived a complete stop/start: `display.orientation` reported
  `fold_angle: 180`, `degrees: 90`. Closed was also recorded, then survived a
  round trip through fixed-inner startup before returning to the outer entry.
  Fixed-inner did not overwrite that closed record. Final dynamic state is open.
- Fixed-inner rotation requests 0, 90, 180 and 270 were each confirmed through
  `display.orientation`, independently of the rotation command's reply.
  The dynamic path was checked at 0, 90 and 180. This does not claim dynamic
  270 support; fixed-inner remains the fallback for the full four-way route.
- Native VZ touch injection through the host machine socket opened Settings,
  then its About page at a second control position. Home-page swiping also
  changed pages. `apps.foreground` and the accessibility tree can still report
  the cover's identity in dynamic inner mode, so screenshots were used to
  verify the actual visible results.
- Guest Home captures show upright wallpaper in dynamic landscape, portrait
  and upside-down portrait. The 180-degree screenshot is normalized for
  viewing; `display.orientation` confirmed the underlying 180-degree pose.
- The first candidate's settled open geometry reported a frame of
  684.47634 x 973 points (669:951) around bounds of 684.47634 x 995.86901
  points (1398:2034). The input display rect equals those bounds. Build 71
  moves this frame/bounds difference to the plain AppKit parent and keeps
  the VZ view's frame equal to its bounds. The full hardware scanout still
  receives touches while the window shows the inner panel's real aspect.
  At the example panel size the corner is about 56.27 host points.
  Previously the cover's 466-point reference made the same R55 corner about
  43.6% too large.

After manual unlock, native mouse input opened Settings and the actual fold
button switched back to the cover. Native window inspection also revealed a
narrow black strip on the right of the expanded panel, absent from guest
captures. The first candidate applied the nonuniform transform directly to
VZ's bounds; moving it to the ordinary parent removes that dependence on VZ's
hosted layer layout. This follow-up is build 71, bundle
`2.14.5-local.cbb280b6`; full bundle build and the same 36 tests passed again.
Native window acceptance passed:

- Expanding with the titlebar button removes the right-edge black strip.
  All four transparent corners follow the inner panel. The lock and Home
  wallpapers fill the landscape panel.
- Actual desktop mouse clicks opened Settings and About in dynamic inner
  mode; after using the titlebar rotation button, a click on About's in-app
  back button worked at 180 degrees. The window resized to the portrait
  inner aspect without changing its physical corner proportions.
- Fixed-inner was cold-started with this final build. Native window captures
  at 0, 90, 180 and 270 show the wallpaper upright, with the matching window
  aspect and four scaled corners. A desktop mouse click opened Settings in
  portrait as well. Its startup still has no dynamic fold button.
- The dynamic record stayed open during fixed-inner testing. The final build
  is installed, bound to Duo and selected as the default bundle. iPad remains
  on `2.14.4-local.b95ab9f8` without interruption.
- Returning to the outer entry and cold-starting restored open at 90 degrees;
  the native fold button reported open, the full panel had no black strip,
  and a desktop mouse drag from the bottom edge revealed Home. Duo is left
  running in that dynamic landscape state.

The native window observations are in this task's desktop-tool results;
the PNG files below are guest captures and do not show the host mask.

Live screenshots and baseline records are in the task's
`artifacts/duo-dynamic-fold-2026-10-30/` directory. Useful captures include
`live-open-settings-settled.png`, `live-open-about-settled.png`,
`live-open-portrait-wallpaper.png`, `live-open-180-wallpaper.png` and
`live-open-swipe.png`.

Logs: `/tmp/vphone-duo-dynamic-20261030-*.log`.
