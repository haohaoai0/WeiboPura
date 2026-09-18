# 微博数据与交互适配层

本工程的主界面已经是微博客户端；首页即为资料与动态流，实现由以下文件组成：

- `service/WeiboAuthManager.ets`：仅保存用户主动粘贴的 Cookie 与目标用户 ID。
- `service/WeiboVisitorSession.ets` / `components/WeiboVisitorBootstrap.ets`：以无痕 ArkWeb 页面建立匿名访客会话，Cookie 只在进程内存中存在。
- `network/WeiboHttpClient.ets`：独立 RCP 会话，固定微博请求头与 800ms 最小请求间隔，绝不继承贴吧 Cookie。
- `service/WeiboService.ets`：将微博的移动端与桌面端响应映射为工程内部模型；目前覆盖推荐流、登录账号的关注动态、用户资料、用户动态、评论、热搜、搜索联想，以及用户手动触发的点赞和评论。
- `pages/WeiboHomeTab.ets`：复用 TiebaPura 首页的帖子卡片、骨架与长列表结构，展示微博动态。
- `pages/WeiboFeed.ets`：帖子详情、评论展开和评论发送界面。
- `pages/WeiboHotSearch.ets` / `pages/WeiboSearch.ets`：公开热榜和关键词联想；不需要 Cookie。

## 接口边界

适配层借鉴成熟微博客户端的分层方式：公开读取可使用用户 Cookie 或匿名访客会话；写操作只在用户主动点击后使用其自行输入的 Cookie。实现为 ArkTS 重写，没有复制其他项目的源码。

容器路径包括：

- `GET /api/container/getIndex?containerid=100505{uid}`：用户资料。
- `GET /api/container/getIndex?containerid=230413{uid}&page={page}&count=20`：用户动态。
- `GET https://weibo.com/ajax/feed/friendstimeline?count={count}&max_id={cursor}`：登录账号关注用户的动态流；返回 `statuses` 及下一页 `max_id` 游标。
- `GET /api/comments/show?id={mid}&page={page}`：评论。
- `GET https://weibo.com/ajax/side/hotSearch`：公开热搜。
- `GET https://weibo.com/ajax/side/search?q={query}`：公开关键词联想。
- `POST https://weibo.com/ajax/statuses/setLike` / `cancelLike`：用户手动点赞或取消点赞。
- `POST https://m.weibo.cn/api/comments/create`：用户手动发送评论。

这些并非稳定、公开承诺的第三方 API；微博可随时改变其返回结构、限流或要求验证码。应用将响应先转换为自有的 `WeiboUser`、`WeiboPost` 与 `WeiboComment`，不让页面依赖原始 JSON 结构。

## 凭据与安全

- 不内置 `SUB`、`XSRF-TOKEN`、App Key 或任何其他账号凭据。
- 未填写账号 Cookie 时，应用以一个无痕 ArkWeb 页面进行正常的微博访客访问；取得的访客 Cookie 仅保存在 `WeiboVisitorSession` 内存对象中，退出进程即丢失，也不会写入 Preferences。
- Cookie 仅由用户在首页手动输入时才会持久化；微博与旧贴吧数据的 Cookie 名称空间、HTTP 会话完全分离。
- 遇到验证码、登录墙或限流时，适配层会停止并显示微博返回的失败信息；不自动解题、不模拟点击验证，也不重试轰炸接口。
- 点赞、取消点赞和评论都必须由用户在页面上单独触发；不提供自动化、批量操作、发微博、转发、关注或私信。

后续若增加更多写入能力，应优先采用微博正式开放平台的 OAuth 授权方式，并在隐私政策、权限说明和凭据存储策略通过审查后再实现。
