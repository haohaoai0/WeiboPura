# 沉浸式顶栏 / 底栏「透明悬浮」修复与验证记录

> **工程**：WeiboPura（`D:/Users/User/project/weibopura-ohos`）
> **日期**：2026-10-01
> **触发**：真机反馈「上下都有大块儿的白色遮挡」，用户定调「顶部和底部原本都是透明悬浮的」

---

## 1. 现象与用户定性

真机（9/30 13:32 安装最新评论交互包后）首页上下各出现一条大块浅色带，用户描述为「白色遮挡」，
并明确顶部与底部**原本都是透明悬浮**——即应为浮在内容之上的透明材质层，而非实色块。

## 2. 客观取证（截图像素分析）

以下为当时的截图采样记录。旧版 `docs/images/` 截图现已从当前版本删除，不再用于产品展示；表中路径仅标识历史证据，可在 Git 提交 `81c3f17` 中查阅。本地调试截图不随仓库分发。

| 截图 | 采样 | 像素 | 判定 |
|---|---|---|---|
| `docs/images/01-home-feed.jpg`（9/25 验收参照） | 顶部 1% | 17,18,22 | `#101114` = `Theme.bg(dark)` |
| `docs/images/04-post-detail.jpg` | 顶部 1% | 16,17,21 | 深色 |
| `docs/images/02-hot-search.jpg` | 顶部 1% | 16,17,21 | 深色 |
| `.device-installed.jpeg`（9/30 真机首页） | 顶部 0% / 底部 88–100% | 243,244,248 | `#F2F4F7` = `Theme.bg(light)` |
| `.current.jpeg`（详情页 + 回复面板） | 蒙层区 | 恒为 153,153,153 | 255×0.6=153 ⇒ 纯白被 40% 黑 `maskColor:#66000000` 覆盖 |

`.device-installed.jpeg` 逐行墨迹扫描（背景基准 `#F3F4F8`，任意通道偏差和 > 40 记为墨迹）：

```
70.0%  inkCount= 10  INK     ← 内容 / 红色 FAB
86.7%  inkCount=  0  blank   ← 起完全空白
98.6%  inkCount= 77  INK     ← 只剩系统手势条
```

底部悬浮 Dock 的理论占位 = `HDS_TAB_BAR_HEIGHT(56)` + `barFloatingStyle.barBottomMargin(30)`
⇒ 屏高 ≈616vp 时为 **86.0%–95.1%**，与实测空白区间吻合 ⇒ **Dock 槽位是空的**。

## 3. 10/1 修改依据（不是已确认的全部根因）

1. **顶部**：Index.ets 的 originalStyle 用透明背景，但 scrollEffectStyle 原来填实色 Theme.bg(isDark)。这与用户要求的透明悬浮不一致；已统一为透明。原记录将其直接断言为约108vp白色遮挡的根因，证据不足，需滚动真机验证。
2. **底部**：曾怀疑 Dock 隐藏后仍保留 bottomInset 空间，因此增加回到顶部时的显示请求。**10/8 装包后的截图仍未见底部 Dock**，说明这个修改没有证明解决问题，不能再称底部根因已确定。
3. 后续须区分 HDS 原生滚动绑定与自定义隐藏状态、内容视口 padding、安全区及实际 TabBar 渲染；不得仅凭源码字符串测试宣称 UI 正常。

## 4. 修改

- `entry/src/main/ets/pages/Index.ets` — `titleBarStyle().scrollEffectStyle.backgroundStyle`
  改为透明系统色，与 `originalStyle` 一致；观感交给 `systemMaterialEffect` 的 `IMMERSIVE` 材质
  与 `IMMERSIVE_GRADIENT_BLUR`。
- `entry/src/main/ets/pages/WeiboHomeTab.ets` — `WaterFlow.onDidScroll`：列表在顶部
  （`pageScroller.currentOffset().yOffset <= 0`）时请求显示悬浮 Dock；10/8 真机截图显示底栏仍缺失，修复未通过验收。
- `entry/src/main/ets/pages/WeiboPostDetail.ets` — `CommentItem` 删除独立红色「回复」按钮，
  改为点击评论本身进入回复（保留 `accessibilityText`）。

## 5. 验证状态（分层如实记录）

| 层级 | 结论 |
|---|---|
| 源码修改 | 已完成（见 §4） |
| 逻辑回归 | **62/62通过（10/8新构建）**；新增断言禁止WaterFlow上下视口padding并要求contentStartOffset/contentEndOffset；这是源码结构回归，不是渲染/手感验收 |
| 编译 | `CompileArkTS` 通过 |
| 打包 / 签名 | `BUILD SUCCESSFUL`，产出 `entry/default/outputs/default/entry-default-signed.hap` |
| 真机安装 | **已完成（2026-10-08 15:41）**：最新content-offset签名包，UU 7分片，手机大小/hash一致，bm明确成功且包更新时间已变更 |
| 真机 UI 验证 | **上下悬浮层已由用户真机确认正常**；首页图片区域起手滑动无效另行修复，见verification-image-hit-scroll.md；新命中测试包已安装，修复后拖动/点击仍待真机验证 |
| 登录态写操作 | 未执行（未授权） |

### 2026-10-08 安装凭据

- 使用2026-10-01 12:49:54构建的签名HAP，未重新构建。
- 实际产物：`entry/build/default/outputs/default/entry-default-signed.hap`。
- 大小6,509,748字节；SHA-256：`9D288756E465FD1E5D9055B1EEA2F575431DEA57C653F53CB4C9630427EE07EB`。
- verify-app验签通过；内嵌Profile包名与module.json一致。
- USB手机6HQ0226407035966；com.weibopura.harmony版本1.0.0 / 1000000。
- 7个分片传输1.25秒，手机合并大小/hash与原件相同。
- 安装回执：`install bundle successfully.` / `BM_EXIT:0`。
- updateTime：1790746201248 → 1791441917047。
- 覆盖安装，未卸载/清数据；手机端本次暂存文件已清理。
- 启动被手机锁屏阻止（10106102），未关闭开发者模式或绕过锁屏。
- 安装结果：`C:/Users/User/.frp/weibopura-uu.result.json`；回执目录：`C:/Users/User/.frp/weibopura-uu-20261008-144512/`。

### 2026-10-08 解锁后的首次真机复验

- 用户解锁后，aa start明确返回 `start ability successfully.`。
- 已取得1264×1848首页截图：`.device-tests/20261008/home-after-install.jpeg`。
- 顶部推荐/关注/搜索胶囊可见；尚不能从一张静止截图证明滚动态透明悬浮正确。
- **底部 Dock 未出现，下方大块浅色空白仍在，底栏修复未通过。**
- 后续命令返回设备未连接；UU list targets显示同一设备USB Offline，Windows监听仍属于GameViewer。
- 独立只读FRP诊断连接也失败；已关闭仅本次创建的8713隧道，未改动UU/共享HDC服务。
- 未执行滑动/点击评论/发送等后续动作；未重装、未清数据。

### 2026-10-08 重连取证与 content-offset 修正

- 本次重连后旧包截图 `home-before-gestures.jpeg` **可见正常Dock**。对应界面树中TabBar的bounds为 `[220,1611][1044,1765]`、visible=true、opacity=1，五个标签均在屏内。这否定了“Dock永久未渲染/始终在屏外”的判断；此前缺失截图只代表当时状态。
- 顶部内容从约y=298起，底部截断于约y=1496；屏幕1848px、比例约2.75px/vp，分别吻合topInset≈108vp、bottomInset=128vp。源码在WaterFlow上使用这两个**视口padding**，与用户要求内容从透明悬浮层下穿过不符。
- `WeiboHomeTab.WaterfallTimeline`只保留横向padding，把上下空间改为 `contentStartOffset(this.topInset)` / `contentEndOffset(this.bottomInset)`。SDK `ScrollableCommonMethod`自API22支持这两个接口；当前包最低API23，编译通过。保留单一WaterFlow，不恢复双重纵向Scroll。
- 62/62回归、BUILD SUCCESSFUL、verify-app验签通过；本次新包构建时间15:40:07，6,509,660字节，SHA256 `5B80D1DC95DA1A88898669CCCF0D740D37DB6C4BE9E68BCCE478B0B1A4C770E4`。
- 7个分片1.27秒传完，手机合并大小/hash一致；明确 `install bundle successfully.` / `BM_EXIT:0`。
- com.weibopura.harmony 1.0.0/1000000的updateTime从1791441917047变为1791445291766；aa start明确成功。未卸载/清数据，暂存已清。
- 最新安装回执：`C:/Users/User/.frp/weibopura-uu-20261008-154126/`；最新结果仍为`weibopura-uu.result.json`。
- 新包后续 `offsets-at-top.json` / `offsets-scroll-forward.json` 均为空数组，截图显示锁屏，**不算首页滚动测试证据**。等待用户保持解锁后复验；评论回复也尚未测。

### 构建注意（环境坑，已复现）

本机 `JAVA_HOME` 默认是 `C:\Program Files\Java\jdk1.8.0_251`，用它跑 `SignHap` 会失败：
`Init keystore failed / parseAlgParameters failed: ObjectIdentifier() -- data isn't an object ID (tag = 48)`
（JDK 8 解析不了 DevEco 新工具生成的 PKCS#12）。此时编译与打包其实都已通过。
构建前须设：

```powershell
$env:JAVA_HOME = 'D:\DevEco Studio\jbr'
$env:Path = "D:\DevEco Studio\jbr\bin;D:\DevEco Studio\tools\node;D:\DevEco Studio\tools\ohpm\bin;D:\DevEco Studio\tools\hvigor\bin;$env:Path"
```

## 6. 待真机验证项

1. 深色档下首页向上滚动：顶栏是否仍为透明悬浮（不再出现实色块）。
2. 底部悬浮 Dock 是否常显；内容是否能从 Dock 下方穿过。
3. 深色档下 `$r('sys.color.icon_primary') / font_primary` 是否正常（顶部/底部图标可见）。
4. 详情页回复面板：暗背景遮罩、多行输入、键盘避让、草稿保留。
5. 拖动跟手、惯性滚动、下拉刷新回弹。
