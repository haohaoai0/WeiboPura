# 评论排序、滚动收起与回复面板 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 评论默认按热度，允许切换实时；阅读评论时评论框随滚动隐藏；点回复打开参考截图中的遮罩底部多行编辑面板。

**Architecture:** 服务通过微博 buildComments 的 flow=0/1 取得服务端排序，使用 max_id 游标分页，不对一页结果做本地伪排序。详情页以请求世代、账号版本和排序共同屏蔽过期响应。纯逻辑滚动状态机驱动常驻评论胶囊的位移/透明度，编辑器采用原生 bindSheet 和系统输入法避让。

**Tech Stack:** ArkTS / ArkUI / UIDesignKit，现有 WeiboService / WeiboEmojiPanel / Node test / DevEco Hvigor。

**Spec:** 本会话用户的三项要求及参考图；界面遵循现有 Theme/fontScale/darkMode。

## Global Constraints

- 保留全部现有已修改/未跟踪成果及三个 skip-worktree 本地签名适配文件。
- 不自动发评论、点赞或关注；构建、逻辑测试与真机验证分别记录。
- 初次进入默认热度；快速切换不能混用排序、缓存、分页游标或楼中楼展开状态。
- 评论框隐藏不改变 Scroll 高度；反向滑动恢复；编辑、选图、发送期间不能自动收起。
- 回复面板保留草稿与图片；发送失败不关闭、不清草稿；成功才关闭并刷新当前排序。
- 参考截图下半部是系统输入法，使用系统键盘而非自绘假键盘；工具按钮只提供实际实现的图片、@、表情、更多和发送。
- 不把整个脏工作树提交为本任务成果。

---

### Task 1: 真实排序与分页

**Files:** Modify `entry/src/main/ets/model/WeiboModel.ets`, `entry/src/main/ets/service/WeiboService.ets`, `entry/src/main/ets/pages/WeiboPostDetail.ets`; Test `tests/weibo-regression.test.cjs`。

**Interfaces:** `WeiboCommentSort.Hot=0 / Latest=1`; `fetchComments(postId, page, sort=Hot, maxId='0'): Promise<WeiboCommentsPage>`；`switchCommentSort(sort): void`。

- [x] 编写默认 flow=0、实时 flow=1、按排序隔离首屏缓存、按 max_id 继续翻页、失效首屏不能被旧预取重新缓存的失败测试。
- [x] 运行 `node --test tests/weibo-regression.test.cjs`，确认新断言失败。
- [x] 实现服务排序参数、数组响应、字符串游标和桌面 like_counts 字段；缓存加入排序及失效世代；只允许首屏使用缓存。
- [x] 详情页增加默认 Hot 的状态、切换按钮和 cursor；切换清旧评论/展开状态；每个异步阶段验证请求世代与账号版本。
- [x] 编写快速切换和旧分页迟到的详情方法回归并执行。

### Task 2: 阅读滚动收起胶囊

**Files:** Create `entry/src/main/ets/common/CommentComposerScrollState.ets`; Modify `WeiboPostDetail.ets`; Test `tests/weibo-regression.test.cjs`。

**Interfaces:** `CommentComposerScrollState.update(delta, commentsVisible, editing): boolean`；`reset(): void`。

- [x] 先测试小幅抖动不隐藏、累计向下阅读隐藏、反向滑动恢复、编辑时始终显示、尚未到评论区域不隐藏。
- [x] 实现 24vp 隐藏 / 12vp 反向恢复阈值；方向改变时清累积；只返回隐藏状态。
- [x] 接 Scroll.onDidScroll，按评论区域位置判定可见；固定 Scroll 的底部预留；仅动画平移/透明度，不删布局节点。
- [ ] 真机验证旧评论框隐藏时无触摸/无障碍命中，点回复/编辑强制恢复。（屏蔽属性与恢复方法已实现并通过编译/逻辑回归，实际命中仍待设备。）

### Task 3: 参考图回复编辑面板

**Files:** Modify `WeiboPostDetail.ets`; Test `tests/weibo-regression.test.cjs`; Verification `docs/verification-comments.md`。

**Interfaces:** `openCommentEditor(): void`；`beginCommentReply(comment): void` 设置真实回复对象并打开；`ExpandedCommentEditor()` 原生 Sheet builder。

- [x] 为回复目标、打开编辑器、失败保留草稿及图片、成功关闭并重新读取当前排序写失败测试。
- [x] 改常驻输入区为编辑器入口；多行 TextArea、回复用户名占位、灰色圆角输入区、图片/@/表情/发送工具栏和真实表情快捷行。
- [x] Sheet 使用底部形态、背景遮罩、FIT_CONTENT、TRANSLATE_AND_RESIZE；出现时请求焦点；关闭保留草稿，发送中禁止被手势/遮罩关闭。
- [x] `node --test tests/weibo-regression.test.cjs`、Hvigor assembleHap、`git diff --check`；记录结果。
- [x] 查询远程 HDC；连接可用则安装并做只读 UI 验证，不可用则明确标记未做真机排序/键盘/回弹验证。

## 独立审查补充与最终记录

- [x] 重复页仍有前进游标时不提前结束；连续三页无新增暂停自动加载，保留手动续页。
- [x] 点赞按 ID 校正当前评论树、失效缓存；读取/成功写的版本保护迟到页，后启动读取仍信任服务端。
- [x] 楼中楼收起使线程请求过期，旧回执不能重新展开或清除新请求锁。
- [x] 三项 P2 修复复核通过；60/60 本地逻辑回归与最新签名 HAP 构建通过。
- [ ] 真机排序、隐藏/触摸/回弹、原生面板与键盘、用户授权后的真实写入验收。

验证证据及 HAP 哈希见 `docs/verification-comments.md`。HDC 返回 `[Empty]`，本轮新包未安装，不将原生组件编译或模拟接口测试视为真机验收。
