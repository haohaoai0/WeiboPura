# Hot-search input hit testing — 2026-10-09

Device layout before patch: C:/Users/User/.frp/fluo-hotsearch.json (17:57).
The enabled TextInput with hint 搜索微博、话题、用户 occupied [150,142][1186,252].
Navigation's empty TitleBar occupied [0,107][1264,261], zIndex=2, default hit testing;
its HdsTitleBar child also covered the input. Clearing mainTitle had not removed
this overlay. A later tap attempt was inconclusive because the page changed to
Mine during inspection; do not describe that attempt as a controlled reproduction.

Change: Index.ets hides the root HdsNavigation title bar only for the accepted-
privacy Discover tab. Other tabs and detail destinations keep their title bars.
Official reference: https://developer.huawei.com/consumer/cn/doc/harmonyos-references/ui-design-hdsnavigation
hideTitleBar(hide: boolean, animated?: boolean).

Checks: Hvigor assembleHap success, 71/71 Node tests (including source guard),
official hap-sign-tool verify-app success.
HAP: 7,513,879 bytes, SHA-256
B0A024CB9F732B5D558DC5E0000AFF46820ED57C60C048720FB8CC8B57F31141.
UU 8 chunks, phone byte count/hash matched, cover install succeeded (BM_EXIT:0),
updateTime 1791540053221. Receipt: C:/Users/User/.frp/fluo-uu-20261009-180050/.

Agent-side verification was blocked by screen-lock error 10106102 after install.
The user subsequently confirmed “可以了” in response to this search fix. Record
this as user-confirmed recovery, not as an agent-observed focus/keyboard/submission
trace. This HAP also contains the native comment-dock change; its detailed visual
and interaction acceptance remains pending in verification-native-comment-dock.md.
