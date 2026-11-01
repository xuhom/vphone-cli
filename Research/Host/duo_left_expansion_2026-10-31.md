# Duo expands to the left, 2026-10-31

Requested behavior: opening a folded Duo extends its canvas to the left,
keeping the window's right edge at the same position.

The old viewer immediately fitted a changed panel around the window center
using the previous orientation, then separately rotated to the newly reported
orientation. Both operations could move the right edge and shrink the image.

The dynamic viewer now holds the original window frame when it sees a panel
change and applies the new panel and settled interface orientation together.
The new frame keeps the screen height and top-right corner, increasing width
to the left. Closing retracts along the same edge. If the left side has too
little room, the canvas scales down within the available area while keeping
the right/top anchor. Coordinates on monitors left of the main screen work
the same way. Full-screen windows keep their existing frame and letterbox.
Ordinary rotation still resizes around the center, and fixed-inner startup
does not participate in dynamic folding.

For external folds (such as Device Hub), orientation now waits for the same
two consistent hinge reads used to accept the panel, preventing an intermediate
center-based turn of the old panel. A locally completed posture request can
be adopted on the next read. The completed frame flows through the existing
window state persistence and corner geometry.

Host frame dimensions are rounded once around the fixed anchor before AppKit
receives them. This prevents fractional titlebar-gap arithmetic from growing
the window a point at a time during repeated folds.

Closing through the host's fold control restores the cover orientation saved
before opening. The guest's raw posture RPC can retain the inner orientation
after a close; a landscape cover at the same height is slightly wider than
the inner panel. Restoring the original cover direction makes closing the
inverse layout operation. Startup still restores its separately saved pose.

Version: VPhone.bundle 2.14.7 build 75, compatible with Launchpad 2.14.x.

## Validation

- CoreKit orientation, posture and window-state tests: 25 tests in three
  suites passed. New cases open/close 50 times at half, normal and double
  scale for both landscape directions, with no anchor/size drift. The left
  screen boundary, including a negative-origin monitor, fits the canvas while
  retaining the right/top anchor and panel aspect.
- Baseline live Duo: closed, orientation 0, window (1403, 1430), 476 x 754.
- Full final bundle build and validation passed. Installed build 75 is
  `2.14.7-local.e7b90bcd`, with Launchpad policy and AMFI preflight passed.
  Duo is bound to it; iPad remains on its existing 2.14.6 bundle. No guest
  components were changed by this task.
- Before the Mac locked, actual titlebar clicks on the first candidate opened
  a 476 x 754 cover at (1514, 1429) into a 986 x 754 inner window at
  (1004, 1429): both had right edge 1990 and top 2183. Native capture showed
  the full upright wallpaper, correct inner aspect and all rounded corners.
  That run exposed the one-point AppKit rounding accumulation on the return,
  which the final host-frame quantization removes.
- Final build was checked by the guest API with the same close sequence the
  host now uses: posture closed, then rotation to the remembered cover's 0
  degrees. Open uses posture open, whose resulting orientation was verified
  as 90. Actual host frame records through two complete cycles were:

  | State | Origin | Size | Right | Top |
  | --- | --- | --- | --- | --- |
  | Open | (-91, 1737) | 868 x 671 | 777 | 2408 |
  | Closed | (357, 1737) | 420 x 671 | 777 | 2408 |
  | Open | (-91, 1737) | 868 x 671 | 777 | 2408 |
  | Closed | (357, 1737) | 420 x 671 | 777 | 2408 |
  | Open | (-91, 1737) | 868 x 671 | 777 | 2408 |

  There was no size or anchor drift. Independent `display.orientation` reads
  confirmed angle 0 / rotation 0 when closed and angle 180 / rotation 90 when
  open. The machine is left open, as it was immediately before the final
  install. Records and the checking script are in the task artifacts folder
  `artifacts/duo-left-expand-2026-10-31/`; `verification.txt` has the checks.
- After the user unlocked the Mac, the final build's actual titlebar fold
  button passed two full open/close cycles. No guest API was used to change
  posture or orientation in this check; API reads independently confirmed
  the button's resulting 90-degree inner / 0-degree cover directions.
  The actual window states were:

  | State | Origin | Size | Right | Top |
  | --- | --- | --- | --- | --- |
  | Closed | (636, 428) | 420 x 671 | 1056 | 1099 |
  | Open | (188, 428) | 868 x 671 | 1056 | 1099 |
  | Closed | (636, 428) | 420 x 671 | 1056 | 1099 |
  | Open | (188, 428) | 868 x 671 | 1056 | 1099 |
  | Closed | (636, 428) | 420 x 671 | 1056 | 1099 |

  The final native capture also showed upright inner wallpaper and correct
  screen aspect and corner masks. The current Duo is left running, closed,
  at its original frame and direction for this native check. Evidence is in
  `native-0-closed.json` through `native-4-closed.json` and
  `native-verification.txt` beside the earlier API records. No validation
  blocker remains, and no rebuild was needed after the unlock.

Logs: `/tmp/vphone-duo-left-expand-build-20261031-final.log` and
`/tmp/vphone-duo-left-expand-tests-20261031.log`.
