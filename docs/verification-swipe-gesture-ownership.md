# 横滑误触：原生手势所有权修复（2026-10-12）

> 本文保留当时修复与安装边界。后续用户确认误触已消除，但反馈响应迟钝；最新实现、重新安装及真机证据见 [横滑响应性与拖动反馈](verification-swipe-responsiveness.md)。不要把本文的旧阈值或“尚未安装”当作当前状态。

## 用户问题与实际复现

用户连续反馈首页、搜索、详情横滑误触。前几次修复仅改变位移/方向阈值，随后以父容器 onTouch 轨迹监听直接切分类，均未解决。

本次在目标手机 `6HQ0226407035966` 上实际复现（不是仅凭单测推断）：

| 页面 | 操作 | 旧包实际结果 |
| --- | --- | --- |
| 首页 | 在正文横滑 | 打开微博详情 |
| 搜索 | 在结果正文横滑 | 打开微博详情 |
| 详情 | 在评论文字横滑 | 切至赞列表，同时打开对该评论的回复编辑器 |

证据：`C:/Users/User/.frp/fluo-swipe-probes/` 下 `search-before.json`、`search-horizontal-before.json`、`detail-scroll.json`、`detail-horizontal-before.json`、`back-editor.json`；首次首页复现为 `C:/Users/User/.frp/fluo-swipe-after.json`。

## 根因

- 父容器 onTouch 是触摸观察者，不参与原生手势互斥。它在 Up 直接切分类，并不取消子元素的点击。
- ArkUI `onClick(callback)` 默认移动阈值为 `2^31-1 vp`；未被滑动识别器排斥且松手仍在热区内时，拖动也可以触发点击。
- `PanDirection.Horizontal` 本身不是严格的横向角度约束，仍需方向判断，但只改善轨迹判断不能解决点击与切页双触发。

依据本地华为官方文档：`arkts-gesture-events-multi-level-gesture.md`、`ts-universal-events-click.md`（onClick12+）、`ts-gesture-customize-judge.md`、`ts-gesture-common.md`。GPT 与 DeepSeek 两位独立审查者均已返回。第二位审查期间主线程已修改源码，其报告分析的是演进中的新实现，不能把报告中的风险自动当成旧包用户问题的已证实根因。

## 源码修复

- `common/WeiboTabSwipe.ets`：onTouch 只记录轨迹，不执行任何分类切换。由标记为 `weibo-tab-swipe` 的普通原生 PanGesture 获得手势所有权，只有其 onActionEnd 可以提交一次切换。
- 原生 Pan 在 12vp 开始识别，切页提交仍需明确横向位移。短横拖可以消费手势但不切分类，避免退化为点击。
- judge 使用当前原生事件 FingerInfo.globalX/globalY 和记录的首触点/轨迹判定，避免依赖 onTouch Move 与 judge 的回调顺序；核验手指身份。纵向/斜向历史、取消、多指、失去原生竞争均不得提交。
- `Index.ets`、`WeiboSearchResult.ets`、`WeiboPostDetail.ets` 的现有内容区域使用非 parallel 的原生手势。首页保持底部 HdsTabs 在 Home 时不可横滑。详情不新增顶部 Tab，仍联动评论区转发/评论/赞。
- 微博卡片、搜索 ThreadCard、评论/图片等内容点击增加官方 onClick 第二参数 `WEIBO_TAP_MAX_MOVEMENT = 12`，使原生 Pan 被拒绝或作用域之外的拖动也不变成点击。
- 详情评论区按实际滚动视口保留最小高度，避免切分类加载/空状态时瞬间缩短，滚动位置被夹回正文图片区域。

## 构建与测试

最终源码检查：144 项 Node 测试通过，0 failures。

- `.test-swipe-native-final.log`
- `.build-swipe-native-final.log`：assembleHap 成功，22.205s。既有警告仍在，不能称零警告。
- `.verify-swipe-native-final.log`：codesign、permission sign、verify-app success。

最终待安装 HAP：`entry/build/default/outputs/default/entry-default-signed.hap`

- bytes：8,021,431
- SHA-256：`421CB4FD20D9B7F4140ADD86898B8483D14C9DDBC0C4EB6C32C3D285CC32AAA8`

**最终包尚未安装**：设备链路中途失效，8712 监听仍在，但 `hdc list targets` 返回 Empty，指定 serial shell 命令返回 E001005。这里只能确定当前 HDC 无法访问目标，不能推断物理断线原因。

## 已安装的中间包与实际验收边界

为验证原生手势所有权，先安装了不含后续点击移动限制/稳定高度的中间包：

- SHA-256：`91D1505606E91FBE7596BC019518221760A15394A3218A18EE7AF61EF058FE3C`
- bytes：8,023,480
- evidence：`C:/Users/User/.frp/fluo-uu-20261012-113109/`
- 8 个分片大小/hash 核对通过；`install bundle successfully. BM_EXIT:0`
- bundle updateTime：1791775868173；启动成功。

中间包真机已确认：

1. 首页正文左滑到推荐、右滑回关注，均未打开详情。证据 `native-home-left.json`、`native-home-right.json`。
2. 首页短横拖没有切分类/打开详情；纵向滑动正常滚动。证据 `native-home-short.json`、`native-home-vertical.json`。
3. 真正点击首页正文仍能打开详情。证据 `native-detail-tap.json`。
4. 在详情评论文字上左滑成功到赞用户列表，未弹回复输入框。证据 `native-detail-left.json`。

尚未完成：

- 搜索页修复后双向切换及纵向/斜向滚动。
- 详情赞→评论→转发及反向切换、短拖、斜向、点击回复回归。
- 最终包点击移动阈值与稳定高度的真机验收。
- 视频拖进度等子组件手势、内外屏和横竖屏验证。

重要：中间包详情左滑后评论区瞬间缩短，原 850px 位置变成正文图片。在该位置执行下一次横拖打开了图片预览（`native-detail-right.json`）。这不是“赞列表反向滑动通过”的证据；它暴露了需补上的点击移动限制及内容高度问题，最终源码已修，但未在最终包真机复测。

## 恢复设备后的验收路径

先核对最终 HAP hash 再覆盖安装，保留数据。只执行浏览/返回/展开编辑器，不发布评论、点赞、关注或分享。

1. 三页面正文/评论上的明确双向横滑：分类切换且无跳详情/用户页/图片/回复框。
2. 短横拖、斜向、纵向、弧形、边界方向：不双触发；正常滚动不切分类。
3. 实际点击正文/图片/评论仍有效，编辑器打开时禁用分类横滑。
4. 详情空/加载/错误分类不塌缩；连续横滑作用区域不突然变成正文图片。
5. 搜索结果内视频控件不被页面横滑抢占；内外屏及方向变化后的同一路径。
6. 补充第二位审查者提出的风险测试：视频 Slider 拖动不得切分类；搜索/详情从屏幕边缘返回不得同时切分类；横向起手再转纵向不得出现滚动被吃掉却不切页。用 FluoTabSwipe judge/owned/direction 日志区分切页、点击与手势被消费三类结果。

## 第二位审查的采纳边界

- 认可：原生 FingerInfo.globalX/Y 与 TouchObject.windowX/Y 同为窗口 vp，排除此前可能的坐标空间误判。
- 待真机证实：视频 Slider、系统边缘返回、先横后纵的交互竞争；首页标题与内容共用 tracker 的跨区域多指风险。上述是验收项，不是已复现故障。
- 暂不采纳未经验证的 priorityGesture 替换建议：首页普通 gesture 已实际完成双向切换，不能据泛化的父子优先级推断当前必然失效。贸然提高优先级可能反过来抢占 Slider/纵向滚动。
- 保留轨迹记录：原生手势拥有者是 onActionStart/End，原始触摸仅用于方向历史；不是旧版 onTouch Up 直接提交。第二位报告将这两版问题串联，不能据此撤回已经真机确认的点击互斥修复。

自动化逻辑测试只验证状态机和接线，不代表 ArkUI 原生手势竞技或真机完整验收。
