# 首页图片区域起手滑动无效：命中测试修复

## 现象与范围

2026-10-08用户确认content-offset包的上下悬浮层已经正常，但首页滑动仍有问题，进一步明确为手放在图片上时滑动无效。该反馈把问题定位到媒体子节点，而非整页滚动性能。

## 实现依据

WeiboHomeTab.SocialMedia的图片容器原来设置HitTestMode.Block。安装SDK enums.d.ts中HitTestMode的定义：Block阻止子节点、兄弟节点和祖先节点命中；Default阻止兄弟节点但不阻止祖先。Block让图片区域的触摸无法进入WaterFlow祖先，符合用户现象。首页头像、作者名、点赞区、转发块也使用相同错误模式。

将这5处改为HitTestMode.Default，保留各自onClick与媒体/实况预览参数。未改上下内容偏移、主题、材质、Refresh和Dock联动；未添加PanGesture或onTouch阻断。点击事件仍由正常手势识别处理，不把触摸流整体截断。注意ClickEvent没有stopPropagation方法（TouchEvent/HoverEvent有），不要为阻止父卡片点击误加不可用方法。

## 分层验证

- 源码结构回归：63/63通过；新增断言禁止首页媒体/作者/卡片操作使用Block，要求5处Default，保留预览、作者、点赞、原微博与整卡片入口。不能将源码断言视为真实滑动/点击验证。
- 构建：2026-10-08 15:57:28，BUILD SUCCESSFUL。
- verify-app：签名验证成功，Profile包名与module.json均为com.weibopura.harmony，版本1.0.0/1000000。
- 最新HAP：6,509,659字节；SHA256 629C2A032A02F4062AF4A059FEC1AAF71170EF444AF6602485ACF9935675351C。
- 真机安装：15:58按UU7个分片传完（1.26秒），手机端原始大小/hash一致，bm install -r明确install bundle successfully. / BM_EXIT:0。
- updateTime：1791445291766 → 1791446300605；未卸载/清数据，手机暂存已清。
- 安装时自动启动被锁屏10106102阻止；随后用户解锁试用并明确反馈“好了”，首页图片区域起手滑动记为用户真机验收通过。未声称已自动验证全部子操作、双开页面或写入API。
- 安装证据：C:/Users/User/.frp/weibopura-uu-20261008-155816/；结果weibopura-uu.result.json。

## 待真机检查（不执行账号写操作）

1. 推荐与关注：从大图中央向上/向下拖动，应正常滚动、释放后有惯性；文字区域相同行为。
2. 短按图片：只打开图片预览，不同时进入整条微博详情；返回后保持位置。
3. 从头像、作者和转发区域起手也应能拖动；短按仍对应用户主页/原微博。
4. 上下悬浮层继续保持用户已确认的正常效果。
5. 点赞区仅验证拖动，不擅自触发真实点赞；评论发送/关注等均未授权。
