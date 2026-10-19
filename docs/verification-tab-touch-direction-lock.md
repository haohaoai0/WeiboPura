# Tab swipe correction — 2026-10-12

## User regression
Home Following/Recommend swipe still did not work; search/detail vertical reading still accidentally switched categories. Earlier source-string tests and installation did not validate interaction.

## Implementation
- `Index.ets`: disable outer HdsTabs swipe while Home is selected; dock buttons remain operational. Replace home PanGesture with a passive touch observer.
- `WeiboSearchResult.ets`: remove category-switch gestures from text input/title and horizontally scrolling category bar. One observer on results only.
- `WeiboPostDetail.ets`: keep standard title, observer only on CommentsSection, editor-open guard retained.
- `common/WeiboTabSwipe.ets`: track window coordinates from Down, not directional PanGesture terminal offsets. At 12vp first meaningful movement require horizontal dominance 3:1, otherwise reject until next Down. Reject any trajectory exceeding 24vp vertical excursion, even if it curves back. Require 72vp horizontal travel, 60–800ms; no velocity shortcut. Cancel/multiple fingers invalidate; only one switch on Up.

## Evidence
- `node --test tests/*.test.cjs`: 139 passed, 0 failed. Includes executable trajectory tests for vertical/diagonal/curved drags, fast short jitter, cancel/multitouch and duplicate release; source binding tests are not device gesture tests.
- Hvigor assembleHap successful, 19.434 seconds. Build has warnings; not a warning-free build.
- Official verify-app: codesign, permission-sign and overall success.
- Signed HAP: 8,010,896 bytes; SHA256 `2280580C9140F139ECF0BF61ADE2B6EF82727F0D2335740E0293CC6C4736ADDC`.
- UU retained-data install: eight chunks, matching on-device size/hash, `install bundle successfully. BM_EXIT:0`; updateTime `1791775037760`.
- Evidence: `C:/Users/User/.frp/fluo-uu-20261012-111718`.
- Launch blocked by screen lock (10106102). Real-device gestures NOT validated.

## Required device review
1. Home: left from Following to Recommend, right back, no bottom destination change; vertical and curved feed scrolling retain mode.
2. Search: clear horizontal result swipe switches exactly one category; normal/diagonal/curved scrolling and category-strip scrolling do not switch unexpectedly; input selection stays usable.
3. Detail: comment-area horizontal swipes select Reposts/Comments/Likes, ordinary scroll retains selected tab, no redundant title tabs; editor text operations do not switch.
4. Repeat small-screen and unfolded; check nested media/player controls and system-edge back gesture for interference.
