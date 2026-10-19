# Fluo 发现 Tab 更名与实时搜索建议（用户/词条/历史）真机部署与验证记录

## 一、需求背景
1. **底部 Tab 栏改名**：信息流底部导航栏第二项「热搜」Tab 更名为「发现」；
2. **搜索输入建议落地**：搜索框输入时实时呈现搜索建议与精确匹配用户：
   - 精确匹配的用户微卡片（头像、认证标、描述/粉丝、主页跳转）；
   - 区分话题（`#话题#` 与绿底话题标）与热度词（`[热]` 标）；
   - 右侧 `↖` 快捷填入按钮（只将关键词上屏，不触发立即跳转与收起软键盘）；
   - 搜索词为空时呈现「最近搜索」历史标签与清空操作，下方紧随「实时热搜榜」；
   - 严格遵循 200~250ms 防抖请求规范（配置项 #698），降低服务器请求压力。

## 二、代码与功能落地

### 1. 模型与数据层（`model/WeiboModel.ets`）
- `WeiboSuggestion` 补充 `isTopic?: boolean` 区分话题与普通词条；
- 新增 `WeiboSearchSuggestionBundle` 复合结构：包含 `users: WeiboUser[]` 与 `suggestions: WeiboSuggestion[]`。

### 2. 服务接口层（`service/WeiboService.ets`）
- `fetchSearchSuggestions(query, limit = 10)`：
  - 针对桌面端边栏接口 `https://weibo.com/ajax/side/search?q={query}` 抓取；
  - 提取 `data.users` 解析为 `WeiboUser` 列表（包含认证状态、高清头像、粉丝数与简介）；
  - 提取 `data.hotquery` 解析词条，映射 `topic_flag === 1` 为话题标，`top_flag === 2` 为热度标；
  - 空输入自动短路返回 `{ users: [], suggestions: [] }`，无网络开销；
  - 保留原有 `fetchSuggestions` 兼容适配。

### 3. 页面与交互层（`pages/WeiboHotSearch.ets` 与 `pages/Index.ets`）
- **Tab 栏与顶栏更名**：
  - `Index.ets` 中 `currentHdsTitle()` 与 `hdsTabBar()` 全面切至 `$r('app.string.weibo_tab_discover')`（显示为「发现」）；
  - Tab 对应图标对齐为系统符号 `$r('sys.symbol.compass')`（指南针，代表发现/探索）；
  - `Index.ets` 向 `WeiboHotSearch` 注入 `onOpenUserProfile`，支持精确匹配用户直接跳转主页。
- **发现页搜索交互**：
  - `onKeywordChanged` 实行 220ms 防抖，输入清空时自动取消未完成定时器并清空候选；
  - 搜索建议面板展示：
    - `UserDirectCard`：展示精确匹配用户，支持点击卡片或「主页 ↗」按钮直达个人主页；
    - `SuggestionRow`：根据 `isTopic` 动态展示绿色 `#` 或放大镜图标、`[话题]` / `[热]` 胶囊标签；
    - `HighlightText`：纯 ArkUI `Span` 构造，关键词匹配部分高亮为 Sage 品牌色且加粗；
    - `↖` 快捷上屏按钮：点击只替换输入框内容并刷新候选词，不触发路由跳转；
    - 建议项点击：将纯词条加入历史并立即发起搜索。
  - `SearchHistorySection`：
    - 记录最近 10 条搜索词（去重、最新排前）；
    - 支持点击历史标签直接搜索与垃圾桶一键清空。

## 三、工程构建与自动化回归

1. **自动化回归测试**：
   - 新增 `tests/weibo-search-suggestions.test.cjs`（覆盖接口提取、空词短路、向下兼容、UI 组件机制与更名核查）；
   - 全工程 **11 组测试套件、107 项断言全部通过（0 失败，0 告警）**。
2. **构建与官方验签**：
   - Hvigor 构建：`hvigorw.bat assembleHap --mode module -p product=default -p module=entry@default` **BUILD SUCCESSFUL**；
   - 签名产物：`entry-default-signed.hap`（7,782,766 字节，SHA-256：`EE8D719199DC72A702E827D78622846A5D2CA2793B63E32D708582E4B8EBC3F1`）；
   - 官方验签：`hap-sign-tool.jar verify-app` 通过（`verify codesign success`、`verify permission sign success`、`verify-app success`）。

## 四、真机部署与实际运行验证

1. **部署凭据与安装流水号**：
   - 证据目录：`C:\Users\User\.frp\fluo-uu-20261010-184418`；
   - 目标设备：`6HQ0226407035966`；
   - 分块传输：8 个 1 MiB 分块，远端重组校验 7,782,766 字节，SHA-256 `EE8D719199DC72A702E827D78622846A5D2CA2793B63E32D708582E4B8EBC3F1` 完全一致；
   - `bm install -r` 明确回执：`install bundle successfully. BM_EXIT:0`；
   - 包更新时间戳推进：`1791621537885` -> `1791629059876`；
   - 应用拉起：`start ability successfully.`。

2. **真机界面截屏核验（`screen-discover2.jpeg`）**：
   - **底部导航栏**：第二项已正确显示为「**发现**」，图标为原生的**指南针符号（`compass`）**，且选中态带有 Sage 绿渐变光晕；
   - **精确匹配用户**：输入「苹果」后，成功展现「苹果汇」和「苹果君」两个精确匹配用户卡片，带有头像、绿色认证勾、简介，以及右侧「主页 ↗」胶囊按钮；
   - **候选建议词条**：包含「苹果壁纸高清」、「苹果18」、「苹果壁纸」、「苹果折叠屏」等，带有橙色 `[热]` 标与右侧 `↖` 快捷填入符号；
   - **关键词高亮**：候选词与用户名称中的「苹果」字样精准高亮为 Sage 品牌绿。
