# Upstream merge and per-VM window pinning, 2026-11-04

Merged Lakr233/main through `0b0377f1cc21d514b9a1c4bf57af44e807e1d662`
into the local `23cc03fb` baseline (68 upstream commits). A rollback branch,
`backup/local-before-upstream-20261104`, retains that baseline. Release identity:
Launchpad and Core Bundle 2.15.4; bundle build 80, helper protocol/build 22.

## Resulting behavior

The VM's Window menu includes a checked **Always on Top** toggle (Simplified
Chinese: **窗口置顶**). It changes only the display window belonging to that
VM between AppKit's `.normal` and `.floating` levels. It keeps targeting the
display when a shell/file/diagnostic window is key, and can be switched off
without restarting. Pinning lasts for the current window session.

## Merge decisions

- Keep the local built-in camera source, frame normalization, error callbacks
  and explicit stream-request/reconnect state. Add upstream's optional system
  camera picker beside it. Both sources feed the existing camera transport.
  Deduplicate their identical producer lifecycle declarations and the camera
  entitlement; retain the upstream Continuity Camera opt-in.
- Keep the tested active-panel geometry initializer, flipped-coordinate and
  letterbox handling, without applying a second backing/panel ratio to pointer
  coordinates. Also retain upstream's independent viewport helper and tests.
- Keep fixed-inner startup guards, four-way rotation, final-panel corner sizing,
  window restoration, right-edge fold anchors and committed panel-owner records.
  Integrate upstream's external-display adapters and always-on panel power state.
- Merge translation catalogs structurally: retain local-only entries and
  upstream additions/edits, and remove entries deleted upstream. Keep both
  branches' camera and patch research histories.
- Known experimental iPhone 14 Pro/iPhone 15 identities remain explicit-source
  experiments. Update catalog tests to distinguish those from curated devices;
  the XS Max's new iOS 18 catalog is covered separately from the iOS 26 loop.

Upstream also brings GLES renderer/compiler/cache corrections, optional host
shortcut/mouse capture, iOS 18 research-board support and iOS 16 experiments,
minimal/watch boot-chain and userspace-debugging fixes, smaller restore-tree
clones/undo records, localization corrections and the documentation website.
No new local kernel or binary patch is added by window pinning.

## Build and regression evidence

- Complete VPhone Debug scheme, bundle admission and resource signing passed.
- Launchpad Release scheme and the existing local Developer ID signing workflow
  passed; nested signatures and camera/microphone/location entitlements checked.
- CoreKit: 105 tests across 8 selected suites passed (fold completion/posture,
  touch geometry, orientation, saved frames, guest identity, catalog, confinement).
- Firmware patcher: 170 tests across 18 selected suites passed (patch model,
  catalog/resolution/drift, GLES point/restart, Metal cache/vertex formats,
  shared-cache undo/migration, trust cache, compiler cache, ARM64 encoders).
- Daemon logic: 426 checks, zero failures.
- Native hinge, panel-owner, injected-touch and fixed-inner mode checks passed.
  iOS 16 surface/lab and Mach-port compatibility checks passed. GLES AIR fixtures
  compiled, linked and rendered the expected point-coordinate gradients on the
  host GPU. These are selected regressions, not a fresh full firmware corpus.
- Launchpad bundle naming, machine binding and product-type scripts passed.

Installed bundle: `2.15.4-local.576f11da`, admission/preflight passed.
SHA-256: `33f237cea958cbd55fedc9c0898e5f5c44af05c14bf4df2f6ca3ebd319b450d8`.
VM CDHash: `d6c0d7d4bf26382875fcb7d512f0f4b91518b603`.
Live installation and UI acceptance are recorded below after completion.
