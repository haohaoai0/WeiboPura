# 横滑响应性与拖动反馈（2026-10-12）

## 用户反馈与证据

用户确认误触已消除，但横滑不跟手、有时要滑数次。

设备 `FluoTabSwipe` 日志出现连续多次 `judge=true` / `owned=true direction=0`（`C:/Users/User/.frp/fluo-swipe-probes/responsiveness-before-hilog.log`）：手势已消费，但没有提交切页。旧实现同时要求初始横纵比 3:1、纵向偏移不超过 24vp、总位移 72vp、持续至少 60ms，且页面切换后还屏蔽手势 260ms。页面没有 onActionUpdate 的位移反馈。

## 本轮改动

- 保留普通原生 PanGesture 的独占所有权；onTouch 不执行切页，仍只记录轨迹。保留内容点击 12vp 移动限制。
- 初始方向使用 1.5:1 横向优势；纵向/等角度斜向先行后仍不能在松手时转成横滑。
- 横向锁定后不再因拇指弧线超过固定 24vp 而撤销。
- 慢拖至少 48vp；短轻扫至少 24vp 且原生末端速度至少 500vp/s、速度方向与位移一致。短抖动、反向速度、没有原生所有权、取消及多指不能切页。
- 去除首页/搜索/详情 260ms 固定冷却，由手势生命周期防止单次触摸重复提交。
- onActionUpdate 驱动内容区弹性平移，接近起点时近似随手，较大位移时渐增阻力；首尾分类边界阻力更强。松手/取消 180ms 回位，不改变布局尺寸，不平移顶栏。
- 首页标题和内容分别使用 tracker，避免两个区域共用同一触点状态。

这是当前内容区的弹性拖动反馈，不是预渲染相邻页面、两页同时可见的原生 Swiper 分页；没有宣称实现了完整相邻页跟随。

文件：
- `entry/src/main/ets/common/WeiboTabSwipe.ets`
- `entry/src/main/ets/pages/Index.ets`
- `entry/src/main/ets/pages/WeiboSearchResult.ets`
- `entry/src/main/ets/pages/WeiboPostDetail.ets`
- `tests/weibo-top-bar-swipe-tabs.test.cjs`

## 测试、构建、安装

最终源码 147 项 Node 测试通过，0 failures。覆盖横向弧线、短轻扫、无所有权/取消/多指、纵向先行、连续开始新手势、边界阻力与 onActionUpdate 接线。日志 `.test-swipe-responsive-final.log`。

`assembleHap` 成功（14.477s，有既有警告），日志 `.build-swipe-responsive-final.log`。
`hap-sign-tool.jar verify-app` 成功，日志 `.verify-swipe-responsive-final.log`。

最终包：`entry/build/default/outputs/default/entry-default-signed.hap`
- 8,048,907 bytes
- SHA-256 `52602FCDB286AA340070F23DE1DBD79B94E3407461E38785CF3D72A58551B631`
- `C:/Users/User/.frp/fluo-uu-20261012-121646/`
- 8 分片重组、大小/hash 一致；`install bundle successfully. BM_EXIT:0`
- updateTime `1791777995866` → `1791778606801`
- 使用安装器 `--no-launch`，保留用户正在使用的其他前台应用；最终安装后没有自动启动或继续操作。

## 真机交互证据

实际检查在同一功能代码的先行包上完成：
- SHA-256 `22559865F64D9C24B446B632BCC896FA691D7B03150984162529564796F6CE6E`
- 8,057,181 bytes
- 安装证据 `C:/Users/User/.frp/fluo-uu-20261012-120635/`，updateTime `1791777995866`，启动成功。
- 最终包相比此先行包只修正 hilog 的浮点格式（改为字符串参数），交互实现没有再修改。不可把最终包的重新启动称为已验证。

设备当时为展开状态，1828×2584 px。UI 证据均在 `C:/Users/User/.frp/fluo-swipe-probes/`：

| 路径 | 观察结果 | 文件 |
| --- | --- | --- |
| 首页正文左滑 160px、纵向偏移 70px，2400px/s | 一次从关注到推荐，无打开详情 | `responsive-home-arc-left.json` |
| 首页正文右滑 100px、纵向偏移 35px，2400px/s | 一次从推荐回关注，无打开详情 | `responsive-home-short-right.json` |
| 首页主要纵向滑动 | 正常滚动，仍为关注，没有切分类 | `responsive-home-vertical.json` |
| 正常点击钟文泽正文 | 可以打开详情 | `responsive-detail-open.json` |
| 评论正文左滑 100px、偏移 35px | 评论到赞用户列表，没有回复框 | `responsive-detail-short-left.json` |
| 赞列表右滑 100px、偏移 35px | 回到评论，未打开用户主页 | `responsive-detail-short-right.json` |
| 评论正文右滑 160px、偏移 70px | 到转发列表，未弹回复框 | `responsive-detail-arc-right.json` |
| 搜索结果短滑双向，100px、偏移 35px | 综合到实时，再回综合，无打开详情 | `responsive-search-short-left.json` / `responsive-search-short-right.json` |
| 搜索慢拖中途采样 | WTA 作者从 x=226 移至 x=109；分类标签 x 坐标保持原位。松手到实时 | `responsive-search-during-drag.json` / `responsive-search-after-drag.json` |
| 实时搜索结果的视频 Slider 拖动 | 00:00/00:05 → 00:04/00:05，仍是实时分类 | `responsive-search-slider.json` |

未完成：极短间隔连续反向手势的完整真机观察、其他折叠/旋转状态、系统边缘返回组合。当用户切到其他应用后停止操作；误采的无关应用 UI 文件已删除，不作为 Fluo 验收证据。

以上只是明确列出的操作通过，不等于所有速度、轨迹、设备形态及主观手感已全面验收；仍需用户确认其自然拇指操作体验。
