# Focused scroll input and Watch controls

## Requested behavior

The focused VM display receives mouse-wheel and trackpad scrolling. Other
Mac applications, background VM windows, attached sheets and the VM's native
tool windows keep their own input. A Watch titlebar exposes only its side
button and Digital Crown press.

## Source findings

The existing display override replayed precise trackpad scrolling as touch
but sent an ordinary wheel to `VZVirtualMachineView`'s default handler. The
native pointer route was available only during explicit mouse capture.
There was no common focus check or application-level routing over titlebar
chrome. A focus loss could also deprive a synthetic touch of its final phase.

`VPhoneApplication.sendEvent` now offers a wheel event once to the key
window's display before VZ's local event monitors and ordinary hit testing.
The same handler accepts direct delivery to the view. Its policy requires an
active application, the key display window, a matching event window (or a
windowless event), no attached sheet and the existing gesture preference.
Accepted events stop before normal dispatch, so they are not injected twice.
No global event tap or system-shortcut capture was added.

Both precise and line-based deltas use the existing touch route; a wheel line
is 16 points before the touch gain and orientation transform. A wheel over
the focused titlebar starts at the display center. Phaseless wheel events
release their finger, and only precise gestures can select a system-edge
start. Mouse-captured pointer scrolling retains its existing native route.
Window/app focus loss and teardown release scroll touches, native scrolling
and pinch fingers before dropping the connection. The previous pinned
Command-Tab behavior remains unchanged.

The read-only `display.geometry` view report adds `scroll_input_enabled`,
`scroll_input_events`, `scroll_touch_active` and `native_scroll_active` to
help verify delivery and cleanup without synthesizing global Mac input.

## Watch behavior and limits

The Watch side button uses the existing Device menu action and its
`button.vertical.right.press` symbol. The other button uses the system
`digitalcrown.horizontal.press` symbol, localized as 数码表冠. It sends the
existing Crown/Home consumer usage 0x40, with press/release forwarding for a
held physical click. An accessibility click sends one complete press rather
than being lost by the held-button guard. The other five titlebar controls
are not allocated for a Watch, leaving room for its title and subtitle.

The existing Watch guest accepts a generic `input.scroll` request but showed
no response on its watch face during a bounded check. Watch wheel/trackpad
input therefore uses the working touch route. This provides screen scrolling;
it does **not** claim to synthesize native Crown rotation, which can also
control zoom, pickers and the Smart Stack. The titlebar Crown button simulates
its press. Neither host UI change requires modifying Kiwi's sealed guest.

## Validation

The added regression tests first failed because the shared input policy did
not exist. With the implementation, the 44-test geometry/orientation/window
run passed. It covers focus isolation, sheets, the disabled preference,
equivalence between wheel lines and precise travel, natural-scroll inversion,
and rejection of non-finite deltas. The complete VPhone and Launchpad 2.15.9
builds passed; both finished products passed strict deep signature validation.
The Crown SF Symbol was confirmed present on this Mac.

Final bundle `2.15.9-local.898b95fb` is installed and all four host bindings
use it. Its guest-resources tree is byte-identical to the installed 2.15.8
candidate. The actual Watch window shows only Side Button and Digital Crown,
with the title/subtitle now fitting and the 50-point proportional corners
visible. The Mac's previous gesture preference was disabled; the owner's
new request authorized enabling it. After restart the geometry diagnostic
reports `scroll_input_enabled=true`.

The desktop automation interface refused targeted button input as changed
app state. It could observe the live window; it did not exercise those
physical clicks or claim a native wheel event had arrived. The physical
button/wheel check remains unconfirmed. Final diagnostics showed the gesture
preference enabled, zero forwarded scroll events and no held scroll touch or
native scroll. Delivery is recorded as compiled, tested and installed, with
that hardware-input check still requiring confirmation.
