# Detail full-text reactive binding — 2026-10-09

## Reproduction

Device: 6HQ0226407035966; bundle: sh.fluo.client.
Post: 5352159130421183, 钟文泽「打卡梅兰芳故居」.
Before patch, the visible body stopped at “图” after the description of picture 4.
The visible “查看全文” row was enabled and clickable, but a tap did not change the UI.
Before-patch layout: C:/Users/User/.frp/fluo-click.json.

## Root cause and change

`PostBody(currentPost: WeiboPost)` was called as `this.PostBody(this.post)`.
ArkUI @Builder treats this as by-value parameter passing: replacing `@State post`
after fetching full text does not update the builder's captured text/condition.
Meanwhile expandLongText checks the live post.isLongText, which is cleared after
success. Thus a stale expansion button can remain visible but do nothing.

Changed only this builder's binding to `PostBody(params: PostBodyParams)` called
with the direct object literal `this.PostBody({ post: this.post })`, and read
`params.post` in its UI expressions. The full-text API fallbacks were not changed.
Added bounded HiLog diagnostics for entry and successful application: post ID,
pending/busy flags and character counts only, no cookies or response bodies.

Official reference:
https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/arkts-builder
Sections: 参数传递规则 / 按引用传递参数.

## Verification levels

- Source regression guard: tests/weibo-fulltext-binding.test.cjs, 1/1 pass.
  This checks the binding syntax only; it is not an ArkUI runtime test.
- Existing tests/weibo-regression.test.cjs: 66/66 pass.
- Hvigor assembleHap: successful, existing warnings remain.
- Official hap-sign-tool verify-app: success.
- Signed HAP: entry/build/default/outputs/default/entry-default-signed.hap
  - 7,511,751 bytes
  - SHA-256: 8C40D03A7A66E1DB24474958DF68037AE0F5A6FB15D6CDFF788F600E7DF99B2D
- UU transfer: 8 chunks; phone size and SHA-256 match.
- Cover install: `install bundle successfully.` and `BM_EXIT:0`.
  updateTime: 1791537926880 -> 1791538982993.
  Receipt: C:/Users/User/.frp/fluo-uu-20261009-174300/.
- On-device HiLog on the exact post:
  - 17:43:27 enter id=5352159130421183 pending=true busy=false chars=161
  - 17:43:28 applied id=5352159130421183 before=161 after=274
  - 17:43:39 another entry/application also completed, 161 -> 274.
- Actual on-device UI tree at 17:44 after the update contains the complete body:
  picture 5 costumes, picture 7 徐悲鸿《天女散花图》, picture 8 泰戈尔 meeting,
  and the final #小泽出去玩# hashtag. The expansion button is absent.
  Layout evidence: C:/Users/User/.frp/fluo-fulltext-after.json.

The measured result is verified for this reported post; it does not imply all
remote API failures or every other by-value builder in the app are resolved.
