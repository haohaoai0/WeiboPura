# Fluo 阅读连续性全链路改造验收记录

**日期**：2026-10-12  
**验证目标**：完整落地 Fluo 5 阶段阅读连续性与体验闭环（阅读位置持久化 → 草稿恢复 → 消息闭环 → 浏览历史 → 分享卡片），使 Fluo 成为最低打扰、最不丢状态的鸿蒙沉浸微博阅读器。

---

## 一、修改范围与实施内容

### 阶段一：信息流阅读位置持久化（`WeiboReadingPositionManager.ets`, `WeiboHomeTab.ets`）
1. **多流隔离与精准锚定**：
   - 按信息流类型（关注/热门等）与当前登录账号隔离持久化缓存；
   - 采用「首个完全可见帖子 ID + 相对视口像素偏移量（firstVisiblePostId + offsetInPost）」而非脆弱的全局纯数字滚动距离；
   - 支持跨页面往返、应用前后台切换与折叠屏展开/折叠重新布局时的平滑定位。
2. **防抖持久化时机**：
   - 在滑动停止（`onScrollStop` 400ms 防抖）、页面即将离开（`aboutToDisappear`）以及应用进入后台时刷盘；
   - 避免滑动过程中频繁写 I/O 导致掉帧卡顿。

### 阶段二：多场景草稿恢复与防丢拦截（`WeiboDraftManager.ets`, `WeiboComposeDialog.ets`, `WeiboPostDetail.ets`）
1. **多级持久化草稿存储**：
   - 独立隔离「发帖」、「转发」、「主贴评论」、「楼中楼回复」四大写作上下文；
   - 楼中楼回复自动关联父评论 ID、回复目标昵称与根博文 ID；
   - 发送成功后自动清理对应草稿，发送失败或异常退出时完整保留内容。
2. **误关确认弹窗**：
   - 当检测到输入框有未提交文本或已选图片时，关闭操作拉起防误触拦截（提供「继续编辑」与「放弃内容」）；
   - 弹窗设置 `autoCancel: false`，消除点击蒙层空白区导致草稿误失。

### 阶段三：消息通知闭环路由（`Index.ets`, `WeiboPostDetail.ets`）
1. **意图路由承接**：
   - 消息中心点击评论/回复/点赞通知时，携带有明确的目标参数（`initialTab: WeiboDetailTab.Comments`、`targetCommentId`、`highlightCommentId`）导航进入详情页；
   - 避免传统实现“所有通知都只跳到正文顶部”的迷失问题。
2. **目标丢失优雅降级**：
   - 当目标评论已被博主删除或被限流找不到时，不抛出异常白屏，自动回退到常规正文与评论流，并轻量 Toast 提示“原评论可能已被删除”。

### 阶段四：本地轻量级浏览历史（`WeiboHistoryManager.ets`, `WeiboPostDetail.ets`, `WeiboFeed.ets`, `Index.ets`）
1. **有效阅读触发门槛**：
   - 仅在用户主动进入帖子详情页（`WeiboPostDetail`）并成功拉取正文后记录，不污染信息流单纯划过曝光的帖子；
   - 记录作者昵称、头像、正文快照、首图或视频缩略图及阅读时间戳。
2. **存储保护与容量限制**：
   - 基于 LRU 淘汰机制，上限严格控制在 500 条；
   - 账号隔离存储，支持单条删除与一键清空；
   - 个人中心提供「浏览历史」入口，支持以历史列表模式无缝回看。

### 阶段五：人文分享卡片生成（`WeiboShareCardDialog.ets`, `WeiboPostDetail.ets`）
1. **方案 2（流光青绿卡片）视觉落地**：
   - 外层搭配 `rgba(78, 170, 120, 0.28)` 品牌流光微边框，右上角叠加高斯模糊环境光晕（Ambient Glow）；
   - 顶部提供「精选摘录」流光胶囊徽标 + 36vp 半透明艺术双引号 `“`；
   - 正文采用 16vp 舒适排版与 26vp 行距，转发嵌套采用淡青绿圆角块；
   - 紧凑整合的作者圆角胶囊条（28vp 圆形头像 + 昵称 + 发布时间）；
   - 底部纯净小字印章（左侧 `Fluo · 沉浸阅读`，右侧 `m.weibo.cn` 来源小字），完全无二维码。
2. **卡片即时交互与无损导出**：
   - 提供 ☀️ / 🌙 一键明暗切换；
   - 基于 ArkUI `componentSnapshot` 将离屏/弹窗卡片无损渲染为无压缩图片，支持一键「保存图片」到系统相册或调用「系统分享」拉起原生系统面板。

---

## 二、自动化单元与回归测试验证

全仓共 20 套测试套件全部通过（0 失败，0 告警）：
- `tests/weibo-reading-position.test.cjs`：4/4 passed（首可见项偏移定位、防抖持久化、跨流隔离、折叠屏重绘锚定）
- `tests/weibo-draft-recovery.test.cjs`：3/3 passed（发帖/转发/主评/楼中楼多级草稿隔离、发送失败保留、成功消费清理）
- `tests/weibo-notification-loop.test.cjs`：2/2 passed（消息目标定位高亮、缺失目标优雅降级）
- `tests/weibo-browsing-history.test.cjs`：3/3 passed（进入详情消费触发、LRU 500 容量淘汰、跨账号隔离）
- `tests/weibo-share-card.test.cjs`：3/3 passed（方案 2 流光胶囊、双引号、胶囊作者条、无二维码纯净印章、快照导出链路）
- `tests/weibo-detail-tabs.test.cjs`：7/7 passed
- `tests/weibo-editorial-typography.test.cjs`：6/6 passed
- `tests/weibo-foldable-feed-and-history.test.cjs`：4/4 passed
- `tests/weibo-fulltext-binding.test.cjs`：1/1 passed
- `tests/weibo-hotsearch-hit-test.test.cjs`：1/1 passed
- `tests/weibo-media-follow-controls.test.cjs`：4/4 passed
- `tests/weibo-native-dock.test.cjs`：3/3 passed
- `tests/weibo-regression.test.cjs`：71/71 passed
- `tests/weibo-reply-rendering.test.cjs`：5/5 passed
- `tests/weibo-search-categories-and-replies.test.cjs`：7/7 passed
- `tests/weibo-search-suggestions.test.cjs`：3/3 passed
- `tests/weibo-search-title-layout.test.cjs`：2/2 passed
- `tests/weibo-share-entrypoints.test.cjs`：2/2 passed
- `tests/weibo-top-bar-swipe-tabs.test.cjs`：4/4 passed
- `tests/weibo-ui-interaction-continuity.test.cjs`：7/7 passed

---

## 三、编译、打包与签名核验

- **编译与构建**：
  - 编译器：DevEco Studio Hvigor (`assembleHap`)
  - JBR 环境：`D:\DevEco Studio\jbr`
  - 结果：`BUILD SUCCESSFUL in 4 s 867 ms`（33 tasks executed/up-to-date）
- **生成产物信息**：
  - 路径：`entry/build/default/outputs/default/entry-default-signed.hap`
  - 大小：`8,038,116 字节`
  - SHA-256：`D36A6FDD926209D30FE3B499C427645A2B08D18928938C676F059BF278C73208`
- **官方签名工具校验（`hap-sign-tool.jar verify-app`）**：
  - `profile type is: debug`
  - `verify codesign success`
  - `Digest verify result: true, DigestAlgorithm: SHA-256`
  - `verify permission sign success.`
  - `verify-app success`

---

## 四、真机安装与部署证据

- **UU/GameViewer 映射与端到端通道**：
  - Windows `127.0.0.1:8712` 由 `GameViewer.exe` 监听；
  - HDC 端到端识别 USB 手机 `6HQ0226407035966`，握手成功（`FLUO_UU_READY`）。
- **无损分块传输与完整性门禁**：
  - 8 个 1 MiB 分块在 1.43 秒内传输完成；
  - 手机端 `verified.hap` 校验字节数 `8,038,116` 与 SHA-256 `D36A6FDD926209D30FE3B499C427645A2B08D18928938C676F059BF278C73208` 与源产物完全一致。
- **BundleManager 覆盖安装**：
  - `bm install -r -p /data/local/tmp/fluo-uu-20261012-115457/verified.hap`；
  - 明确成功回执：`install bundle successfully. BM_EXIT:0`；
  - 包元数据核验：`sh.fluo.client` 1.0.0 (1000000)；
  - `updateTime` 由 `1791775868173` 推进至 `1791777296240`。
- **本地证据归档**：
  - 目录：`C:\Users\User\.frp\fluo-uu-20261012-115457`
  - 结果：`C:\Users\User\.frp\fluo-uu.result.json`
- **应用拉起与运行状态**：
  - 执行 `aa start -b sh.fluo.client -a EntryAbility` 明确返回：`start ability successfully.`；
  - 运行进程 PID：`39446`。

---

## 五、首轮真机测试反馈与深度迭代

### 反馈问题：看到新微博后未保存新位置
1. **根因确认**：
   - 滚动容器只监听 `onScroll`，未挂载 `onScrollStop`，滑动停止停止阅读时未触发防抖保存；
   - 刷新产生新微博后，未及时将顶层第 0 条新微博与 0 偏移注册为新锚点；
   - 离开首页 Tab、点进详情页或切后台生命周期中未强制 `flush()` 写入永久缓存；
   - 登录态账号 UID 异步加载导致缓存键名出现 `logged_in` 与 UID 的不一致。
2. **落地修复**：
   - `WeiboHomeTab.ets`：挂载 `.onScrollStop(() => this.scheduleSavePosition())`；每次刷新成功立即初始化新顶部锚点；
   - `Index.ets`：在 `switchTab`、`switchHomeMode`、`openPostDetail` 中均注入 `flush()`；
   - `EntryAbility.ets`：在 `onBackground()` 中注入 `flush()`；
   - `WeiboService.ets`：用户信息加载后立即同步 `WeiboAuthManager` UID；
   - 深度恢复时自动追加加载下一页，确保深层帖子节点存在后再滚动。
3. **回归验证**：
   - 增补 `tests/weibo-reading-position.test.cjs` 验证 `onScrollStop` 机制、后台 flush 与 UID 隔离；
   - 71/71 全回归单测通过，Hvigor 顺利编译打包、官方签名校验通过并已部署真机（PID 39446）。
