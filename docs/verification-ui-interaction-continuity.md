# Fluo UI 交互连续性与状态恢复完整改造验证记录

**日期**：2026-10-11  
**验证目标**：落地交互审计中确定的 4 阶段交互连续性改造，消除“从哪里进从哪里出”割裂、突兀放大缩小、回复上下文丢失与跨页状态不一致。

---

## 一、修改范围与实施内容

### 阶段一：防误操作与草稿保护
1. **回复对象与草稿完整保护**（`WeiboPostDetail.ets`）：
   - `closeCommentEditor()` 不再清空 `replyTargetComment`，仅关闭编辑器展示；
   - 只有在评论成功发布（`publishComment`）或用户主动点击关闭取消时才复位回复目标；
   - 彻底解决“输入回复内容后收起键盘，再次唤起变为主帖评论”的严重交互缺陷。
2. **发帖/转发草稿放弃二次确认**（`WeiboComposeDialog.ets`）：
   - `handleClose()` 增加未保存内容检查：当 `content.trim().length > 0` 或 `selectedImages.length > 0` 时，弹出 ArkUI 警告弹窗（`AlertDialog`），提供“继续编辑”与“放弃内容”选项；
   - 弹窗控制器配置 `autoCancel: false`，避免空白区域误触导致辛辛苦苦编写的内容直接丢失；
   - 关闭按钮点击触控区由 32vp 扩大至 44vp。

### 阶段二：统一进出、意图导航与跨页状态同步
1. **详情路由参数意图承接**（`WeiboModel.ets`, `WeiboPostDetail.ets`, `WeiboHomeTab.ets`）：
   - `WeiboPostDetailRouteParam` 扩充 `initialTab?: WeiboDetailTab`、`autoFocusComment?: boolean`、`targetCommentId?: string`；
   - 首页卡片底部“评论”、“转发”与“神评卡片”点击进入详情时携带明确操作意图，自动切换到对应 Tab 或唤起编辑器，告别“所有入口进去都一样”；
   - 键盘监听器改用具名引用函数 `onKeyboardHeightChange`，在 `aboutToDisappear()` 中精确移除 `win.off('keyboardHeightChange', this.onKeyboardHeightChange)`，绝不误伤宿主或全局其他页面的键盘监听。
2. **跨页面实体状态统一同步**（`WeiboService.ets`, `WeiboPostState.ets`, `WeiboHomeTab.ets`, `WeiboSearchResult.ets`）：
   - `WeiboService` 点赞（`setLike`）、收藏（`setFavorite`）、关注/取关（`followUser`/`unfollowUser`）成功后，分别向 `AppStorage` 发送 `weibo_sync_like`、`weibo_sync_favorite`、`weibo_sync_follow` 事件；
   - 首页与搜索结果页实时监听关注同步事件，通过不可变状态更新函数 `withWeiboFollow` 局部更新对应作者卡片，返回页面时无需重新刷掉整个列表导致阅读位置丢失。
3. **导航栈分栏状态统一回收**（`WeiboBrowser.ets`, `WeiboSearchResult.ets`, `WeiboNavigationLayout.ets`）：
   - 网页浏览页、搜索结果页等次级页面在退出与返回时统一调用 `syncWeiboSplitNavigation(this.weiboNavStack)`，保证大屏分栏与单栏状态的准确恢复。

### 阶段三：图片转场来源与真实图片比例排版
1. **图片预览平滑退出与系统手势拦截**（`ImagePreview.ets`）：
   - 增加 `onBackPress(): boolean` 生命周期拦截系统侧滑返回手势，统一走 `closePreview()` 退出流；
   - 退出动画前调用 `restoreStatusBar()` 恢复系统状态栏；
   - 关键视觉修复：将进入与退出的 `scale({ x: this.previewScale, y: this.previewScale })` 限制在 `Swiper` 内容区，外层根节点只保留背景淡入淡出（`previewOpacity`），彻底消除顶栏页码、返回按钮和底栏安全保存按钮的突兀跳跃与缩小。
2. **排版纠偏与图片展示优化**（`WeiboHomeTab.ets`, `WeiboPostDetail.ets`）：
   - 3 图微博排版使用 `aspectRatio(3 / 4)` 黄金比例；
   - 去除硬编码标签与错误判断，仅在真正长图或实况/GIF 时显示相应标记。

### 阶段四：加载、切换与视频生命周期
1. **正文优先展示**（`WeiboPostDetail.ets`）：
   - `loadPost()` 在 `fetchPost` 返回成功后立即将 `this.loading = false` 并展示正文，避免被后续分享预览生成、当前用户信息拉取和评论列表网络请求阻塞。
2. **搜索分类阅读状态记忆**（`WeiboSearchResult.ets`）：
   - 引入 `SearchTabSnapshot` 机制，分类切换时记录当前分类的帖子列表、用户列表、分页游标和 `hasMore`；
   - 切回已有分类时毫秒级恢复快照，消除白屏重刷。
   - 搜索结果页中的搜索行为接入 `weiboSearchHistory` 持久化，保持历史记录全局一致。
3. **网页加载抖动消除**（`WeiboBrowser.ets`）：
   - 将 `LoadingProgress` 调整为 `Stack` 悬浮层，彻底解决加载圈插入和移除时整个 Web 容器高度上下跳动 24vp 的问题。
4. **视频离开可视区域自动暂停**（`WeiboVideoPlayer.ets`）：
   - 挂载 `.onVisibleAreaChange([0.0])`，列表快速滑走、视频移出视口时自动暂停并复位控制条，防止后台声音串播。

---

## 二、自动化回归验证

运行全套 13 个独立测试套件（共 118 个断言）：
- `node tests/weibo-ui-interaction-continuity.test.cjs`：7/7 passed
- `node tests/weibo-detail-tabs.test.cjs`：7/7 passed
- `node tests/weibo-editorial-typography.test.cjs`：6/6 passed
- `node tests/weibo-foldable-feed-and-history.test.cjs`：4/4 passed
- `node tests/weibo-fulltext-binding.test.cjs`：1/1 passed
- `node tests/weibo-hotsearch-hit-test.test.cjs`：1/1 passed
- `node tests/weibo-media-follow-controls.test.cjs`：4/4 passed
- `node tests/weibo-native-dock.test.cjs`：3/3 passed
- `node tests/weibo-regression.test.cjs`：69/69 passed
- `node tests/weibo-reply-rendering.test.cjs`：3/3 passed
- `node tests/weibo-search-categories-and-replies.test.cjs`：6/6 passed
- `node tests/weibo-search-suggestions.test.cjs`：5/5 passed
- `node tests/weibo-search-title-layout.test.cjs`：1/1 passed
- `node tests/weibo-share-entrypoints.test.cjs`：4/4 passed

**回归结果**：13 suites / 118 assertions **全部通过，0 失败**。

---

## 三、编译与签名打包结果

- **Hvigor 构建**：
  ```powershell
  hvigorw.bat assembleHap --mode module -p product=default -p module=entry@default --no-daemon
  ```
  **结果**：`BUILD SUCCESSFUL in 17 s 513 ms`（33 tasks: 17 executed, 16 up-to-date）。
- **官方签名工具校验（`hap-sign-tool.jar verify-app`）**：
  ```
  profile type is: debug
  verify codesign success
  verify permission sign success
  verify-app success
  ```
- **生成产物信息**：
  - 路径：`entry/build/default/outputs/default/entry-default-signed.hap`
  - 大小：`7,827,237 字节`
  - SHA-256：`A78FF175A1F093BAC2802D0E1F534C79438E2B522A9C02D24BB7456D1C064CFF`

---

## 四、真机安装与部署证据

- **UU/GameViewer 映射与端到端通道**：
  - Windows `127.0.0.1:8712` 由 `GameViewer.exe` 监听；
  - HDC 端到端识别 USB 手机 `6HQ0226407035966`，握手成功（`FLUO_READY`）。
- **无损分块传输与完整性门禁**：
  - 8 个 1 MiB 分块在 1.48 秒内传输完成；
  - 手机端 `verified.hap` 校验字节数 `7,827,237` 与 SHA-256 `A78FF175A1F093BAC2802D0E1F534C79438E2B522A9C02D24BB7456D1C064CFF` 与源产物完全一致。
- **BundleManager 覆盖安装**：
  - `bm install -r -p /data/local/tmp/fluo-uu-20261012-084140/verified.hap`；
  - 明确成功回执：`install bundle successfully. BM_EXIT:0`；
  - 包元数据核验：`sh.fluo.client` 1.0.0 (1000000)；
  - `updateTime` 由 `1791629059876` 推进至 `1791765700425`。
- **本地证据归档**：
  - 目录：`C:\Users\User\.frp\fluo-uu-20261012-084140`
  - 结果：`C:\Users\User\.frp\fluo-uu.result.json`
- **拉起与真机验收状态**：
  - 执行 `aa start` 返回 `10106102 The device screen is locked during the application launch, unlock screen failed.`；
  - 手机当前处于锁屏状态（`SCBScreenLock15`），待用户手动解锁后即可拉起 Fluo 进行交互体验验收：
    1. 评论回复草稿收起与再唤起时回复目标保留；
    2. 发帖/转发编写后点击关闭时的防丢确认弹窗（“继续编辑” / “放弃内容”）；
    3. 图片大图预览系统侧滑返回与控件不缩放；
    4. 搜索结果不同分类往返切换无白屏重刷。
