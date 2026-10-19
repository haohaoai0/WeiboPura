# Fluo 折叠屏信息流自适应、正文排版对齐与搜索历史持久化落地记录

## 一、需求背景与目标

1. **信息流折叠屏大屏（横屏/竖屏）自适应与排版增强**：
   - 保持 Fluo 现有的顶栏（关注 / 推荐 / 同城）与底栏原生 HDS `IMMERSIVE` 悬浮 Dock 完全不变；
   - 采用大屏宽卡自适应：卡片容器约束由原先生硬的 640vp 拓宽至 `maxWidth: 840vp`，在大屏横屏下呈现杂志式画报居中，彻底消除两侧 500vp 无效黑边；在大屏竖屏及折叠态下自然铺满（两侧 12~16vp 边距）；
   - **内嵌精选神评微卡片 (`HotCommentBox`)**：在信息流卡片底部直接呈现高赞/神评微卡片（Sage 绿 `[XX 赞]` / `精选神评` 胶囊标 + 用户名 + 评论摘要），点击直达详情页互动；
   - **3 图长图排版方案 A**：3 张竖向截图图片单元高度由原 106vp 压扁切片提升至 180vp（对齐 3:4 黄金画幅），展示微缩「长图」角标，消除居中腰斩；
2. **详情页图片与阅读栏大屏对齐**：
   - 详情页 3 图多图同样应用 3:4 画幅（180vp 单元高度与 `长图` 标识）；
   - 详情页主内容阅读区增加 `maxWidth: 840vp` 居中约束，大屏横屏展开时正文行长不失控；
3. **搜索历史持久化**：
   - 修复原先仅保存在内存 `AppStorage` 中导致退出/重启应用后搜索历史丢失的问题；
   - 接入底层持久化首选项缓存 `CacheManager`（键名 `weibo_search_history`），启动即加载、搜词自动落盘、清空同步更新；
4. **清理多余提示文案**：
   - 去除搜索建议面板中多余的「精确匹配用户」标题文字，使直达用户卡片以原生极简风格呈现。

---

## 二、代码落地明细

### 1. 数据模型与服务解析层 (`model/WeiboModel.ets`, `service/WeiboService.ets`, `common/WeiboPostState.ets`)
- **`WeiboPost` 模型扩展**：
  - 新增 `hotComment?: WeiboComment | null;` 字段；
- **接口解析与映射**：
  - `WeiboService.toPost` 从微博服务端返回的 `comments`、`hot_comments` 或 `comment_summary` 中提取首条评论，转为 `WeiboComment` 挂载至 `post.hotComment`；
  - 在 `withWeiboLike`、`WeiboHomeTab.copyPostWithLike`、`WeiboFeed` 及 `WeiboPostDetail` 的状态副本构造中完整传递 `hotComment`，保证点赞、关注与全文展开不丢失神评。

### 2. 信息流与详情页排版层 (`pages/WeiboHomeTab.ets`, `pages/WeiboPostDetail.ets`)
- **信息流宽卡容器**：
  - `PostCard` 采用 `constraintSize({ maxWidth: 840 })`，配合左右 `Blank()`，大屏横屏居中呈现舒适阅读宽度；
- **内嵌精选神评微卡片 (`HotCommentBox`)**：
  - 位于转发卡片下方、底部操作条上方；
  - 呈现 Sage 绿点赞胶囊标签、评论者昵称与两行文本截断；
- **3 图 3:4 比例与长图标识**：
  - `pictureGridHeight`：当 `count === 3` 时高度设为 180vp；
  - 网格单元高度设为 180vp，网格容器宽度提升至 540vp；
  - 单元右下角渲染半透明灰底「长图」轻量微标；
- **详情页大屏对齐**：
  - `WeiboPostDetail` 同样支持 3 图 180vp 黄金画幅与「长图」标识；
  - 详情页正文与评论列采用 `maxWidth: 840vp` 居中包装，保障折叠屏大屏阅读体验。

### 3. 发现页搜索历史持久化与精简 (`common/Constants.ets`, `pages/WeiboHotSearch.ets`)
- **首选项键名**：
  - 在 `CACHE_KEY` 中新增 `WEIBO_SEARCH_HISTORY: 'weibo_search_history'`；
- **加载与落盘机制**：
  - `aboutToAppear` 中调用 `loadSearchHistory()` 从 `CacheManager.getInstance().get` 同步恢复历史数组并注入 `AppStorage`；
  - `executeSearch` 执行搜索时去重、截取最新 10 条，并异步写入 `CacheManager.getInstance().put`；
  - `SearchHistorySection` 清空按钮触发时清空内存并向磁盘写入空数组 `[]`；
- **去除「精确匹配用户」**：
  - 删除了直达用户卡片上方的 `Text('精确匹配用户')` 及外层间距，保留纯粹的原生用户直达卡片。

---

## 三、自动化回归测试与编译构建

### 1. 自动化回归测试
- 新增专用回归测试套件 `tests/weibo-foldable-feed-and-history.test.cjs`；
- 更新 `tests/weibo-search-suggestions.test.cjs` 验证历史落盘与文案精简；
- 全工程 **12 组测试套件、111 项断言全部通过（0 失败，0 告警）**：
  - `weibo-foldable-feed-and-history.test.cjs`：神评解析、840vp 宽卡、3:4 长图画幅、搜索历史落盘与文案精简断言通过；
  - `weibo-search-suggestions.test.cjs`：发现页搜索建议与历史交互断言通过；
  - `weibo-editorial-typography.test.cjs`：方案 A 现代人文字体排印断言通过；
  - `weibo-detail-tabs.test.cjs`：详情页转评赞二级标签断言通过；
  - `weibo-regression.test.cjs`：69 项全功能主回归断言通过。

### 2. Hvigor 编译与官方验签
- **编译器**：DevEco Studio OpenHarmony SDK 6.1.0(23)；
- **命令**：`hvigorw.bat assembleHap --mode module -p product=default -p module=entry@default --no-daemon`（基于 JBR 环境）；
- **构建结果**：`BUILD SUCCESSFUL`；
- **签名产物信息**：
  - 路径：`entry/build/default/outputs/default/entry-default-signed.hap`；
  - 大小：7,793,680 字节；
  - SHA-256：`8A1920D0266B3FFEA2C894442F6638A3595320BD1619F18C0F2D24D30ED73B88`；
- **官方验签（`hap-sign-tool.jar verify-app`）**：
  - `verify codesign success`
  - `verify permission sign success`
  - `verify: Verify success`
  - `verify-app success`
