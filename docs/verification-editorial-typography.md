# Fluo 微博详情页现代人文精排（方案 A）验证记录

## 一、问题背景与方案确认
在真机上浏览长微博详情（如钟文泽关于 iPhone Air / 小米 18 Fold 微博）时：
1. **纯黑文字块密集**：整段文字无段落呼吸感，长文本视觉压迫重；
2. **中西文粘连**：英文单词（`iPhone Duo`、`eSIM`）与中文紧密贴合，缺少留白；
3. **行距与字号不匹配**：默认行高在长文本时较拥挤；
4. **服务器 `<br>` 标签被抹除**：原 `normalizeWeiboText` 过滤 HTML 时直接删除了 `<br>` 和 `<p>` 标签，导致有换行的正文被合并成单行。

在交互原型（`docs/prototypes/typography-prototype.html`）中提供了三种排版方案，用户明确选定 **方案 A（现代人文精排）**。

## 二、代码落地

### 1. `common/WeiboRichTokens.ets`
- **`applyPanguSpacing`**：自动在中文字符与西文字母、阿拉伯数字之间插入呼吸微空格，避开重复空格。
- **`splitEditorialParagraphs`**：
  - 若文本自带换行符（`\n`），按真实换行保留段落；
  - 若文本为单段超长连续文本（> 100 字符），智能按句末标点（`。！？`）归集为每段约 40~80 字符的节奏微段落。
- **`parseWeiboText`**：支持 `{ pangu: boolean }` 选项。仅在 `text` 普通文本 token 内插入呼吸空格，**绝对保护** `#话题#`、`@用户`、`https://...` 网页链接与 `[表情]`。

### 2. `common/WeiboText.ets`
- `normalizeWeiboText` 将 `<br\s*\/?>`、`<p\b[^>]*>` 与 `</p>` 转换为换行符 `\n`，保证服务器返回的自然段落不会被无差别抹除。

### 3. `components/WeiboRichTextView.ets`
- 新增属性：
  - `paragraphSpacing: number = 0`：段落间距（默认 0 保持向后兼容）；
  - `enablePanguSpacing: boolean = false`：中英混排呼吸空格；
  - `enableAutoRhythm: boolean = false`：自适应句群分段。
- 当 `paragraphSpacing > 0` 且存在多个段落时，外层由 `Column({ space: this.paragraphSpacing })` 提供真正的垂直段落空间，每个段落渲染为独立的 `Text()`。

### 4. `pages/WeiboPostDetail.ets`
- 微博详情页正文采用方案 A 黄金比例：
  - 字号：`fs(16.5, this.fontScale)`
  - 行高：`fs(29, this.fontScale)`（约 1.76x 舒适阅读黄金比）
  - 段落间距：`paragraphSpacing: 13`
  - 中英混排呼吸：`enablePanguSpacing: true`
  - 自动节奏分段：`enableAutoRhythm: true`
- 转发卡片正文同步开启 `enablePanguSpacing: true`，行高调整为 22vp。

## 三、测试与验证

### 1. 自动化回归测试
- 针对方案 A 新增 `tests/weibo-editorial-typography.test.cjs`，涵盖 6 项严密断言：
  - `applyPanguSpacing` 中西文微间距与防重；
  - `parseWeiboText` 保护话题、提及、链接、表情；
  - `splitEditorialParagraphs` 显式换行与自适应分段；
  - `normalizeWeiboText` 保护 `<br>`/`<p>`；
  - `WeiboRichTextView` 组件多段落 `Column` 结构；
  - `WeiboPostDetail` 页面属性绑定。
- 全仓测试执行：**105 项检查全部通过（0 失败，0 告警）**。

### 2. 编译与签名
- Hvigor 构建：`hvigorw.bat assembleHap --mode module -p product=default -p module=entry@default`
  - 产物：`entry/build/default/outputs/default/entry-default-signed.hap`（7,715,301 字节）
- 官方工具验签：`hap-sign-tool.jar verify-app`
  - `verify codesign success`
  - `verify permission sign success`
  - `verify-app success`
  - SHA-256：`AC24E7CB990E84991CB6F02351DA7C75EFFC58A43E619F1AD4A7A66068FB8D99`

### 3. 真机覆盖部署（保留数据）
- 目标设备：`6HQ0226407035966`，包名 `sh.fluo.client`
- 传输：通过 UU / GameViewer 私有端口 `127.0.0.1:8712` 分 8 块推送并拼接校验；
- 手机端重组后 SHA-256 完全一致；
- `bm install -r` 显式成功（`install bundle successfully.`）；
- 应用 `updateTime` 从 `1791618032515` 推进至 `1791621537885`；
- 启动时设备处于锁屏（`10106102`），等待用户解锁手机进入微博详情页进行最终真机视觉验收。
