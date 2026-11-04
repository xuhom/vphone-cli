# iPhone capsule alignment

## Evidence

Hom-iPhone (iPhone17,1, iOS 26.6.2) displayed a wide native capsule with a
small raised section in the middle of its top edge. The guest panel is
1206 × 2622 pixels, or 402 × 874 guest points at 3x.

A read-only LLDB inspection of the running 2.15.6 VM found the host's
`phoneOverlay` CAShapeLayer above `_VZFramebufferView`. At the current window
size its path was 96.412 × 36.042 AppKit points, inset 15.318 points from
the panel top. It was the only capsule shape layer in the host hierarchy.

The framebuffer layer's contents were a 1206 × 2622 BGRA IOSurface. Reading
that surface into a PNG showed a complete, wider capsule already present in
the displayed pixels. The framebuffer layer had no filters or mask. The
guest screenshot returned through the control socket omitted this native
capsule, so that screenshot alone was misleading when evaluating whether a
host mask was needed. The host's narrower shape extended slightly above the
native one and caused the visible bump. All debugger sessions detached
without changing the view or layer state.

## Change

2.15.7 removes the extra host capsule. The displayed framebuffer owns the
iPhone capsule's position and dimensions, including its relationship to the
system status bar. The container still clips the physical screen corners
and keeps the 3 mm titlebar gap. Its existing panel scaling and rotation
apply to the complete framebuffer, so there is no second capsule to align.
No guest firmware, binary patch, or Duo/iPad corner calculation changes.

## Validation

- The complete Xcode `VPhone` scheme build succeeded. Its bundle validation
  passed, as did `codesign --verify --deep --strict` and `git diff --check`.
- Launchpad installed `2.15.7-local.3cd2a9b2` with execution policy and host
  preflight both passed. Hom-iPhone was stopped normally, rebound and
  restarted; its guest environment and boot chain remain on 2.15.6 because
  this change only affects the host window.
- The actual Settings window now has one smooth capsule without the raised
  central section seen in the report. The clock and battery line remain
  aligned with the native capsule.
- Safari was rotated to 90 degrees. A second read-only IOSurface capture
  confirmed that the native capsule remains at the physical panel top even
  when the app content is landscape. The actual zoomed landscape window
  showed one capsule at the right edge, with the panel corners and titlebar
  gap intact. Window zoom and a subsequent portrait view also showed clean
  capsule edges at their different display scales.
- Returned the guest to portrait and Settings after verification. Duo and
  iPad remain stopped on their existing bundles.

Installed VM cdhash: `0a8f9c91a53a181164dad7329a5107f0f6039ffd`.
