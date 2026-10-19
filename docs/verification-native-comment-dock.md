# Native comment dock material — 2026-10-09

## Requested correction

The detail comment capsule must use the feed Tab bar's actual material and the
same gradient blur/backplate below the floating capsule, not a visual approximation.

## Implementation

- Added common/WeiboDockStyle.ets: shared `createWeiboDockStyle` for the feed and
  detail. IMMERSIVE material; existing homeTabMaterialLevel mapping; accent light;
  bottom margin 30vp. Leave gradientMask unset for the same HDS default light/dark
  backplate in both places.
- Index.configureHdsTabs now uses this shared factory. Feed geometry unchanged.
- Detail uses a real HdsTabs container with its existing Scroll as TabContent and
  BottomComposer as the custom tabBar. HDS owns material, outline, shadow and
  gradient backplate. The composer no longer draws its opaque white/gray background,
  COMPONENT_ULTRA_THICK blur, border or card shadow.
- Comment capsule requests a 400vp native width in all size buckets; HDS handles
  available-width constraints. It no longer stretches across an unfolded display.
- Scroll hiding and editor opening use the native HdsTabs controller's hide/show
  animation so the capsule and backplate are controlled together. Draft attachment
  previews remain a separate overlay above the dock; editor contents unchanged.
- Shares homeTabMaterialLevel and appAccentColor storage values with the feed.

## Official API reference

https://developer.huawei.com/consumer/cn/doc/harmonyos-references/ui-design-hdstabs
Sections: barFloatingStyle, HdsTabsFloatingStyle.gradientMask, HdsTabsController,
HdsBarWidthRangeOptions. Native default floating backplate: light #CCF1F3F5,
dark #99000000, default bar height +16vp. No manually painted replacement mask.

## Validation performed

- Hvigor assembleHap successful; existing warnings remain.
- 70/70 Node tests pass: existing suite with corrected native-dock assertion,
  full-text binding source guard, material factory tests, slot/source checks and
  controller-visibility ordinary-method tests. These do not simulate native rendering.
- Official hap-sign-tool verify-app successful.
- Signed HAP: 7,513,987 bytes; SHA-256:
  0E2A390D2427FB561329C83B05622D60C81194A2A9A07D508A3DDA1FB9386B5D
- UU: 8 chunks, phone-side byte count and SHA-256 match.
- Cover install: install bundle successfully / BM_EXIT:0.
- Device updateTime: 1791538982993 -> 1791539663471.
- Receipt directory: C:/Users/User/.frp/fluo-uu-20261009-175420/.

## Pending device acceptance

Launch was rejected with error 10106102 (screen locked). Visual comparison to the
feed Tab bar, custom-slot hit targets, input/keyboard return, scroll hiding, and
folded/unfolded layout are NOT yet device-validated for this build. User was asked
to unlock and leave Fluo on the feed so these can be checked before claiming parity.
