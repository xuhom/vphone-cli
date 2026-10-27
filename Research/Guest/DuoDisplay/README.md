# Duo display investigation

`inspect.js` is a read-only guest runtime probe for the actual registered
Core Animation displays, CoreMotion fold-event availability, and the presence
of SpringBoard's display-swap service. It runs in vphoned's disposable script
session and makes no display or preference changes. It is not a fold driver.

From the repository root, with the intended Duo already running:

```sh
vphone-launchpad-cli guest rpc "$machine" script.eval \
  "$(jq -n --rawfile source Research/Guest/DuoDisplay/inspect.js \
      '{source: $source, timeout: 15}')"
```

Choose `machine` from `vphone-launchpad-cli vm list`. The script result is a
JSON string inside the RPC's `result.result`. Inspect `result.ok` and `errors`;
a class missing on another iOS build must not be interpreted as a false value.
The probe does not use `device.screen` as a display inventory: that only describes
the current main screen. Wireless placeholders are not inner panels.

The raw display configuration and the probe's UIKit initial context are recorded
separately. They can disagree during the fixed-inner experiment; neither a
larger mode nor the disposable process's UIKit bounds proves that SpringBoard
has selected the inner surface. Verify native framebuffer screenshots after
boot settles, app layout, and touch coordinates separately.

The baseline and failed dual-port experiment are recorded in
[iphone_duo_bringup.md](../iphone_duo_bringup.md). Do not expose an Unfold button
based solely on the presence of `SBSDisplayToolService` or a successful callback.
A working implementation must verify a second rendering target, correct physical
surface selection, landscape geometry, input mapping, and return to the cover.
