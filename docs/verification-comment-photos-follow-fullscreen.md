# Comment photos, feed follow state, and fullscreen video controls

## Report

The user supplied screenshots showing a comment with only a picture marker, an
already-followed feed author with a `+ 关注` button, and fullscreen video without
playback controls. No device-side response for that particular comment has been
captured during this investigation.

## Source changes

- `WeiboService.toPost` now carries `author.following` into `isFollowed` instead
  of leaving the field undefined. Post-copy paths for likes and expanded text
  preserve it. Both home list keys include follow state so a changed relationship
  invalidates the previous builder snapshot. Following-feed membership is not
  used to invent relationships for repost authors or recommended entries.
- `toComment` keeps mobile `pic`/`pics` support and also reads desktop comment
  `url_struct[].pic_infos`, in `pic_ids` order where available. It prefers
  server-provided `woriginal`/original URLs, falls back through available image
  sizes, skips missing entries, merges/deduplicates attachments and normalizes
  protocol-relative URLs. Nested replies use the same parser.
- `WeiboVideoPlayer` uses the custom overlay in embedded mode and enables the
  native controller in native fullscreen. Fullscreen callbacks restore embedded
  controls on exit. Embedded slider dragging suspends auto-hide and prevents
  playback updates from overriding the thumb until seeking completes.

## Evidence and limits

The desktop comment attachment schema is corroborated by the public example at
<https://github.com/wpf9264/weibo_spider> (`url_struct`, `pic_infos`, `pic_ids`,
`woriginal.url`). This is schema evidence, not a capture of the user's comment.

The installed Huawei official Video reference, section `requestFullscreen`,
states that native fullscreen moves only video content and cannot display custom
controllers. The `controls` property and `onFullscreenChange` callback provide
the native-controller path used here. Custom fullscreen styling is not implemented.

## Validation

- Node regression suite: **78 passed, 0 failed** (including seven added checks).
- ArkTS compilation and signed HAP assembly: passed. Signing requires both
  `JAVA_HOME=D:\DevEco Studio\jbr` and its `bin` first in PATH; an initial attempt
  without the PATH override selected incompatible host Java and failed signing.
- `hap-sign-tool verify-app`: passed.
- Packaged identity: `sh.fluo.client`, version `1.0.0` / `1000000`, module `entry`.
- Artifact: `entry/build/default/outputs/default/entry-default-signed.hap`.
- Size: **7,521,647 bytes**.
- SHA-256: `36E4536409698CE7A12750EE7BA54F89076014B23D9DD414A295F251B7754EDA`.
- Installation: **passed on 2026-10-10** after the private UU mapping was restored.
  Expected USB device `6HQ0226407035966` connected. Eight chunks transferred;
  phone-side byte count and SHA-256 matched. `bm install -r` explicitly succeeded,
  package/version verified, updateTime advanced from `1791540053221` to
  `1791593098738`. Existing application data was preserved.
- Launch / real-device UI validation: **blocked by lock screen**. `aa start`
  returned `10106102`; no interaction or visual success is claimed.
- Installation evidence: `C:/Users/User/.frp/fluo-uu-20261010-084456/`.

## Pending acceptance

Unlock the phone and open Fluo (the new HAP is already installed).
Revisit the user's image comment and verify thumbnail plus full-image preview;
verify followed and unfollowed authors after refresh/like/detail navigation;
verify fullscreen play/pause, progress seeking, controller reveal/hide and exit,
including a paused entry and returning to embedded playback. No account-writing
interaction should be performed automatically as part of verification.
