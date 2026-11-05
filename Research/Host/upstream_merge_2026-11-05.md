# Upstream merge and Watch window adaptation, 2026-11-05

## Merge

Merged Lakr233/main through `8c3630c79c6b1f016fe189bf21933b8850590357`
into the local xuhom branch, starting at `7f8023a2`. The previous local head
is retained as `backup/local-before-upstream-20261105-watch`. Merge commit:
`3aec8723`.

This brings the four-language manual and research website, Duo iOS 27.2
catalog/hinge/locationd changes, iOS 18 GPU submission compatibility and icon
cache invalidation, the persistent CoreDevice developer tunnel, shared guest
bundle seal handling, VirtualAudio discovery for 27.2, EXC_GUARD discovery,
the optional Frida fork patch, and native TXM executable-remap classification.

The manifest, config updater and CLI conflicts keep both the local
`duoDisplayMode` and upstream `holdsDeveloperTunnel` options. Catalog tests
use upstream's off-catalog list while retaining the XS Max's separate iOS 18
assertions. The existing Duo dual boot entrances, live posture/leftward fold
behavior, camera bridge, LAN Remote, per-machine frame/rotation/pinning,
pinned Command-Tab fix, physical corners and native iPhone island remain.

## Watch corners

Kiwi is an existing Watch7,18 on watchOS 26.4 (23T240). A read-only
`script.eval` call to `UIScreen.mainScreen._displayCornerRadius` returned
50 guest points; its panel is 208 × 248 points at 2x (416 × 496 pixels).

The display container now receives `isWatchGuest` and includes it in its
transparent physical-screen clipping. Its radius is 50 times the uniform
scale from that unturned guest panel to the viewport, clamped to half the
short edge. The same layout path handles resizing and orientation. It also
uses the existing 3 mm titlebar gap and rounded titlebar bottom. This does
not change iPhone, Duo or iPad radius calculations.

The owner then requested focused mouse/trackpad scrolling for every VM and
Watch-specific titlebar controls. Final 2.15.9 implements those in
`17c512af`; see [the focused-input note](focused_scroll_and_watch_controls_2026-11-05.md).
The live Watch window exposes only Side Button and Digital Crown, with its
native physical corners visible at the resized window scale.

## Pairing preparation

The existing Hom-iPhone runs iOS 26.6.2. Its trimmed service profile, with
the accounts group selected, disabled NetworkRelay and the companion sync
services. Both guests already had
`EnableBTVCLeConnection.Enabled = true` in the system feature-flags plist;
no Bluetooth patch or runtime flag change was needed. Both use NAT with
the existing default peer reachability.

Kept the phone's profile and groups, merged the pairing labels into its
allow list, and enabled these known companion jobs:

- `com.apple.terminusd`
- `com.apple.identityservicesd`
- `com.apple.nanobackupd`
- `com.apple.nanoprefsyncd.2`
- `com.apple.nanotimekitcompaniond`
- `com.apple.security.otpaird`
- `com.apple.watchpresenced`
- `com.apple.magicswitchd.companion`

The six labels owned by the trimmed profile are now recorded as allowed;
the other two overrides were enabled explicitly. The prior profile snapshot
is retained outside the repository in the task artifacts/logs. Restarting
the phone loaded terminusd, which ran when Bridge began pairing. The owner
completed the pairing code and personal setup in the phone window. Bridge
then showed "Apple Watch is Syncing". Initial sync completed: pairedsyncd
reported `initialSyncState=Complete`, `hasCompletedInitialOrMigrationSync YES`
and `syncState=Completed`; Bridge reached the welcome screen and then My
Watch. After the phone's first restart its Watch settings and face gallery
were still available. No pairing code or credentials are stored in this note.

## Validation and installation

- CoreKit: 104 tests across six selected suites passed. A subsequent 17-test
  manifest run also passed after adding combined Duo/tunnel retention
  assertions to cover the merge conflict.
- FirmwarePatcher: the selected 81-test run across six suites passed; two
  fixture-dependent cases were skipped (real vphone600 kernel and supplied
  TXM). Discovery, rejection, idempotence and patch-catalog checks ran.
- Native hinge tests passed. iOS 18 GPU transport passed with address and
  undefined-behavior sanitizers enabled.
- Launchpad bundle naming/binding checks passed. Both complete Xcode builds
  succeeded, and both final products passed deep strict signature checks.
- The additional 44-test geometry/orientation/window run passed for the final
  focused-scroll policy. The earlier red run failed on the missing policy
  type, as expected. Machine product-type checks also passed.
- Launchpad 2.15.9, signed with the existing matching Developer ID, replaced
  `/Applications/vphone-launchpad.app`. The former app is retained in the
  task's `artifacts/upstream-20261105` directory. The helper is ready (22).
- Bundle `2.15.9-local.898b95fb` is installed as the default, with execution
  policy and host preflight passed; VM cdhash
  `2e2f93565dc7b1129fc89ac78c29d32771cec7e0`.
- All four existing machines use the new host bundle. Hom-iPhone and
  Hom-iPhoneDuo also received the 2.15.8 guest environment. The final 2.15.9
  guest-resources tree is byte-identical to 2.15.8, so it required no second
  guest write. Kiwi's pre-restore
  customised system rejects an environment update to protect its seal, and
  iPad's system volume refused the writable APFS mount (77); both retain
  their 2.15.7 environment. No restore, kernel update, manual acceptance or
  host security change was performed. Each boot-chain binding stays intact.

The Mac's old `trackpadGesturesDisabled` preference was true. It was turned
off under the owner's new request to enable scrolling, and Kiwi was restarted
to load it; the live diagnostic now reports `scroll_input_enabled=true`.

Final cold starts restored both Kiwi and Hom-iPhone to running on 2.15.9.
Kiwi showed its configured watch face; Bridge verified its foreground launch
and returned to My Watch with the paired device and its settings, including
the owner's selected face. Hom-iPhone's environment binding advanced to
2.15.9 on startup; stopped Duo remains on the identical 2.15.8 environment.
The other two guests remain stopped, as at the beginning of this task.

The owner subsequently confirmed that Kiwi's titlebar buttons and actual
scrolling work normally on 2.15.9, completing its physical-input acceptance.
This supplements the visual inspection and regression tests; the desktop
automation interface itself had refused targeted input. The owner also
confirmed completion of the administrator verification. The installed App
and Bundle remain unchanged.
