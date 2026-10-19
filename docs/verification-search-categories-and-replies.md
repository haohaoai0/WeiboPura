# Fluo 搜索分类切换与楼中楼翻页修复验证记录

## 背景与问题

1. **楼中楼回复翻页失效 / 上限假象**：
   - 之前在评论详情点击“查看更多回复”，第 2 页及后续翻页无反应，回复看起来被限制在 10 条。
   - 抓包分析发现，移动端接口 `m.weibo.cn/comments/hotFlowChild` 在翻第 2 页（`max_id > 0`）时，对未携带 Referer 或会话不全的请求直接返回 `ok: -100` 并要求 SSO 重定向；此前仅检查了 `response.ok === 0`，未对 `ok: -100` 做降级重试，导致游标被直接置 `'0'`，按钮失活。
2. **搜索缺少分类切换**：
   - 原搜索仅有单一关键词综合搜索，无法切换分类。
   - 需求要求支持微博标准搜索分类：综合（type=1）、实时（type=61）、用户（type=3）、视频（type=64）、图片（type=63）。

## 架构与源码修改

### 1. 楼中楼回复翻页健壮性（`WeiboService.ets`）
- `fetchCommentReplies` 补齐了移动端接口所需的 `Referer: https://m.weibo.cn/detail/${cid}`。
- 当移动端接口返回 `ok !== 1`（包括 `ok: -100` 单点登录拦截或网页跳转）时，自动无缝降级到桌面端 `https://weibo.com/ajax/statuses/buildComments?id=${cid}&fetch_level=1&is_mix=${isFirstPage ? 0 : 1}&max_id=${maxId}&count=20`。
- 无论第一页还是后续页，均能正确解析返回的子回复列表、`nextMaxId` 游标及 `hasMore` 状态，突破了 10 条限制。

### 2. 搜索分类能力扩展（`WeiboModel.ets` & `WeiboService.ets`）
- `WeiboModel.ets` 新增 `WeiboSearchType` 枚举：
  - `All = 1`（综合）
  - `Realtime = 61`（实时）
  - `User = 3`（用户）
  - `Video = 64`（视频）
  - `Image = 63`（图片）
- `WeiboModel.ets` 新增 `WeiboSearchCompositeResult` 数据结构。
- `WeiboService.ets` 新增：
  - `fetchSearchPosts(query, page, type)`：支持指定分类及 Referer。
  - `fetchSearchUsers(query, page)`：请求 `type=3` 容器，递归解析 `cards` 与 `card_group` 中的用户对象，完成字段标准化与基于 UID 的去重。
  - `fetchSearchComposite(query, page, type)`：在综合搜索第 1 页自动提取顶部权威/认证博主卡片作为 `highlightUser`，其他分类返回对应博文流。

### 3. 搜索结果页 UI 落地（`WeiboSearchResult.ets`）
- 依据已确认的原型设计，在顶部搜索栏下方集成水平滚动 Pill 胶囊分类栏：`['综合', '实时', '用户', '视频', '图片']`。
- 激活态使用品牌绿色背景高亮，非激活态保持通透灰度；切换时带有轻量触觉反馈（Haptic）。
- **实时分类**：顶部呈现“按发布时间倒序排列”辅助说明。
- **用户分类**：以列表形式展示匹配博主，包含大头像、黄V/蓝V认证标、昵称与认证说明、粉丝数与微博数、以及带状态的“+ 关注 / 已关注”按钮；点击卡片进入用户主页，点击关注按钮可就地关注/取关。
- **综合分类**：当存在权威大V时，在博文流顶部展示专属置顶博主卡片；下方衔接热门讨论博文流。
- **视频与图片分类**：直接复用流式博文展示体系，聚焦多媒体内容。
- 分类切换时自动重置分页游标并重载对应数据；滚动到底部支持平滑分页加载。

## 验证结论

- **自动化单测与回归套件**：全量 **84/84 项全部通过**（0 失败，0 告警，含针对分类容器、用户提取、楼中楼降级和 UI 状态切换的 6 项新增单测）。
- **ArkTS 编译与签名 HAP 打包**：DevEco JBR / hvigor 构建通过（`BUILD SUCCESSFUL`）。
- **官方验签**：`hap-sign-tool.jar verify-app` 校验通过，Profile 类型为 debug，包名 `sh.fluo.client`。
- **产物信息**：
  - 文件：`entry/build/default/outputs/default/entry-default-signed.hap`
  - 大小：7,592,276 字节
  - SHA-256：`6E082D10A43BFCAA9585404466B943C2EB9E2A18A6CCCC1ABF064FE26C7D6760`
- **真机状态**：
  - USB 物理设备 `6HQ0226407035966` 当前处于锁屏 `Offline` 状态，安装脚本 `install-fluo-uu.py` 已更新该产物的校验哈希与分块配置，待用户解锁后可直接一键部署。
