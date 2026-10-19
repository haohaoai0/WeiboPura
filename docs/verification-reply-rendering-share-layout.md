# Reply rendering, sharing entry points, and search title layout

## User reports

- Expanded comment thread remains stuck at “加载更多回复”.
- Author-profile list sharing does nothing; detail has no share action. User clarified these are the affected sharing surfaces, not home/category search.
- Search title overlaps status bar on unfolded device.

## Changes

- `WeiboPostDetail.ets`: plain nested replies previously mutated under a root ForEach keyed only by comment ID. Root thread identity now includes expanded/loading state, cursor and reply IDs. Explicit array updates trigger reconciliation on request start/end and collapse; unaffected thread keys remain stable. Existing epoch/session guards remain intact.
- Duplicate nonempty reply pages with an unchanged cursor remain retryable rather than silently becoming terminal. Terminal threads show an explicit end label. Privacy-minimal `FluoReplies` logs record IDs/cursor and counts, not reply text or credentials.
- This change does not claim a live endpoint diagnosis: no matching live response for the user's exact thread has been captured. Existing service fallback is unchanged.
- Profile and legacy search ThreadCard instances now connect sharing to ShareUtil. Detail restores one accessible share button.
- Search category strip moves from the MINI stack slot into HDS bottomBuilder; system safe-area avoidance remains enabled.

## Verification (2026-10-10)

- Node regression suite: 92/92 passed, including two-page append beyond ten, deduplication, stable unrelated-thread key, loading/terminal keys, collapse and duplicate-page retry.
- These method/static checks do not execute the ArkUI renderer or establish physical-device acceptance.
- ArkTS/HAP build: BUILD SUCCESSFUL (20 s).
- Official hap-sign-tool verify-app: success.
- Artifact: `entry/build/default/outputs/default/entry-default-signed.hap`
- Bytes: 7,602,426
- SHA-256: `4C8E1841EA3423240E07EA756222EF2531AA05AA28B8DB8F7954B38942CDEB5C`
- Initial attempt stopped before transfer because enumeration omitted the device; this did not establish physical disconnection. A later serial-targeted handshake succeeded.
- 14:11 retained-data cover-install succeeded: 8 chunks, phone size/SHA-256 matched, `install bundle successfully.` and `BM_EXIT:0`; bundle updateTime advanced from 1791597758704 to 1791612686982. Ability launch succeeded.
- Successful installation evidence: `C:/Users/User/.frp/fluo-uu-20261010-141125/`.

## Pending physical-device acceptance

Installed package awaits interactive acceptance. Verify the user's exact reply thread grows after loading more, including visible loading/end state and diagnostics if it fails. Verify profile/detail share sheets without sending to a recipient, and search title safe areas in folded/unfolded configurations.
