# 推荐 / 关注滚动修复验证（2026-09-30）

## 用户报告

推荐与关注页滑动不跟手。本轮针对纵向列表滚动；没有把编译成功当作手感验收。

## 定位与修复

1. `WeiboHomeTab.TimelineScroller` 原结构为 `Refresh → Scroll(pageScroller) → Column → WaterFlow`。WaterFlow 自身启用滚动，而外层 Scroll 又接管滚动与底栏 Scroller。现在成功态为 `Refresh → WaterFlow(pageScroller)`：单个、有界的原生滚动容器直接绑定底栏；一列与多列都使用 LazyForEach，分页和手动加载放在原生 footer。骨架/错误/空态使用独立 Scroll 分支，不再嵌套瀑布流。
2. `Refresh` 双向绑定会在 `onRefreshing` 前把 `refreshing` 设为 true；原 `refreshFeed()` 因 `if (refreshing) return` 跳过实际请求。改为独立 `refreshInFlight` 请求锁，保留刷新时的现有卡片，并在 finally 清除锁与刷新状态。
3. WaterFlow 的 `onDidScroll` 是 `(scrollOffset, scrollState)`，与 Scroll 的三参数签名不同；已按 SDK 声明适配。

## 已执行

- 增加结构回归：修复前失败，修复后通过。保护瀑布流绑定原生 scroller 且不嵌套在纵向 Scroll 中。
- 增加两项真实刷新方法回归（提取普通逻辑，不解释 UI DSL）：双向绑定已设 true 时仍发起请求；重复刷新只有一个请求，失败后正确释放。
- 当前全部逻辑测试：35 / 35 通过（含先前 32 项功能回归）。日志 `.test-regression.log`。
- 最新 assembleHap：BUILD SUCCESSFUL。日志 `.build-scroll.log`。
- `git diff --check`：通过。

## 尚未验证

- 本次滚动修复后的真机拖动、惯性、下拉刷新回弹及长列表帧率。远程 HDC 当前返回 `[Empty]`，不能安装/复测。
- 之前成功安装的是滚动修复之前的全功能构建；不能把那次安装算作本次修复的真机验证。

待设备恢复：安装 `entry/build/default/outputs/default/entry-default-signed.hap`，分别在推荐/关注做短拖、长拖、反向拖动、快速甩动、下拉刷新、分页后再拖动；检查底栏收起/展开是否仍正确。设备绑定 `6HQ0226407035966`，远程 HDC 必须使用 `OHOS_HDC_SERVER_PORT=8711` 与 `hdc -p`。
