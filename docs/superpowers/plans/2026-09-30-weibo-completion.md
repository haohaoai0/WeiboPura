# WeiboPura 全功能补齐 Implementation Plan

> **For agentic workers:** Inline execution with review checkpoints. Preserve the complete inherited worktree; do not create a replacement implementation.

**Goal:** 补齐除桌面热搜服务卡片之外的全部功能，并分别报告实现、编译、逻辑测试、真机和登录写操作的验证状态。

**Architecture:** 保留 ArkUI 页面和 WeiboService 的现有分层。登录状态由 AuthManager 单点管理，以递增 session revision 隔离异步请求；服务缓存按会话失效。测试直接 transpile 非 UI ETS 并 mock SDK，避免复制被测逻辑。

**Tech Stack:** ArkTS / ArkUI / ArkWeb / RCP / HarmonyOS SDK / Node test runner。

**Spec:** 用户全功能补齐交接，验收清单复制到 `docs/weibo-functional-acceptance.md`。

## Global Constraints
- 桌面热搜服务卡片不做；其余全做，不用入口或标签代替功能。
- 保留所有继承的 tracked/untracked 修改；不自动提交调查文件与构建日志。
- 保留 bundle `com.weibopura.harmony` 和三个 skip-worktree 本机构建适配文件。
- 禁止未经许可用用户账号发测试微博、评论或关注随机用户。
- 构建和测试日志落盘，工具输出有界；不把编译通过当成真机验证。

### Task 1: 恢复最新构建
**Files:** `pages/WeiboPostDetail.ets`, `components/WeiboEmojiPanel.ets`。
- [x] 运行 handoff 构建，复现 `Property enabled does not exist on type void`（1283/1286）。
- [ ] 将 enabled/accessibility/onClick 下沉到 CommentToolButton 实际 Button，通过参数传入，不在 Builder 调用后链式修饰。
- [ ] 重新运行 assembleHap，保存退出码及错误位置。

### Task 2: 可重复逻辑回归与账号退出/切换
**Files:** `tests/ets-loader.cjs`, `tests/weibo-regression.test.cjs`, `cache/CacheManager.ets`, `service/WeiboAuthManager.ets`, `pages/WeiboLogin.ets`, `pages/Index.ets`。
**Interfaces:** AuthManager.getSessionRevision(): number；clearCookie(): Promise<void>；CacheManager.putStrict(key,value): Promise<void>。
- [ ] 创建 ETS transpile/mock harness，用真实模块验证 Cookie 持久化失败传播、清 Web 会话、revision 失效。
- [ ] 先运行测试确认当前退出未清 Web Cookie、持久化异常被吞。
- [ ] Auth 写入使用严格持久化接口，退出即时撤销内存会话，清 Web Cookie/storage，失败明确上报。
- [ ] 增加明确切换账号，清会话成功才进入登录页；阻断旧页面/旧请求恢复账号。
- [ ] 修复 Index accountProfile 在途加载回写旧用户，测试再构建。

### Task 3: 缓存与多账号隔离
**Files:** `cache/ImageCache.ets`, `service/WeiboService.ets`, `pages/WeiboPostDetail.ets`, `pages/WeiboUserProfile.ets`, `components/WeiboComposeDialog.ets`。
**Interfaces:** ImageCache.clearAllCache() 返回删除字节数/失败文件数；WeiboService 最近微博缓存不得跨 revision。
- [ ] 添加 unlink 失败与下载完成晚于清理的回归用例。
- [ ] 清理开始递增 generation，在途下载禁止写缓存；删除失败报告部分失败，不显示旧总大小为已清理量。
- [ ] 最近微博缓存按会话 revision 失效，旧异步响应不得写入新账号缓存。
- [ ] 检查详情/用户主页/发布器各个 await 后是否仍是原会话，隔离读取回写与写操作。
- [ ] 发布器限制高度并滚动，禁用提交中编辑；测试并构建。

### Task 4: 其余功能逐项验收
**Files:** `tests/weibo-regression.test.cjs`, `common/WeiboText.ets`, `common/WeiboMediaMetadata.ets`, `service/WeiboMedia.ets`, `service/WeiboService.ets`, `components/WeiboRichTextView.ets`, `components/WeiboVideoPlayer.ets`, `pages/ImagePreview.ets`, `docs/weibo-functional-acceptance.md`, `resources/rawfile/README.md`。
- [ ] 测试 catalog/HTML 表情、LivePhoto URL 配对、GIF 短读、图片上传失败、消息/收藏/点赞 JSON shape、mutation 参数和错误传播。
- [ ] 审核关注、图文发布/带评转发、收藏/点赞历史、评论/楼中楼/定向回复/点赞/图/表情、话题/@/网页、GIF/Live/保存、视频全屏/比例/倍速/手势、三类消息分页、退出/切换/清缓存、触觉。
- [ ] 给实际遗漏补实现和 regression case，不擅自做有副作用的线上测试。
- [ ] 查明表情目录来源并提供说明；不打包 `.ref`/临时日志。
- [ ] 运行全部逻辑测试、git diff --check、签名构建；能连接设备则验证无副作用的页面/媒体操作。
- [ ] 更新验收矩阵，登录写操作与真机未测项明确保留，不能宣称全部完成。
