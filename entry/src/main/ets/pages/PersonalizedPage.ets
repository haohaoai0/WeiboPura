/*
 * TiebaPura - HarmonyOS 原生 ArkTS 实现的第三方百度贴吧客户端
 * Copyright (C) 2026 a307608689-afk
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { display } from '@kit.ArkUI';
import { Theme, Spacing, Radius, isDarkMode, setDarkMode as applyAppDarkMode, syncDarkFromConfig, resetConfigurationToFollowSystem, ImmBlur, ImmMaterial, MaterialManager, fs, tabletTopFadeStop, columnModeLabel } from '../common/Theme';
import { UsageHabitsManager } from '../service/UsageHabitsManager';
import { BRAND_BLUE } from '../common/Constants';

/**
 * 「列数调整」档位选项（个性化 → 列数调整）：
 * 0 = 默认（按机型自动适配横竖屏）/ 1 = 竖二横三 / 2 = 竖三横四。
 * 仅在大屏形态（平板 / 阔直屏 / 大折叠展开）生效，手机档与窄窗不覆盖（Theme.isLargeScreenForm）。
 */
const COLUMN_MODE_OPTIONS: number[] = [0, 1, 2];

/**
 * 「列数调整」三选一弹窗（系统 CustomDialog + API 26 沉浸光感）。
 * 玻璃层交给 options.systemMaterial（ImmMaterial.dialog()），卡内不再自绘
 * backgroundColor / border / backgroundBlurStyle / shadow（与工程既有弹窗约定一致）。
 */
@CustomDialog
struct ColumnModeDialog {
  /** 系统弹窗必须声明 CustomDialogController 类型属性（ArkTS 编译期强校验） */
  controller?: CustomDialogController;
  @Link isDark: boolean;
  @Link fontScale: number;
  /** 当前档位（0/1/2）：选中项高亮用 */
  @Link mode: number;
  /** 选定档位回调（写 AppStorage + 落盘 + 广播 columnModeTick） */
  onPick: (mode: number) => void = () => {};
  onDismiss: () => void = () => {};

  /** 档位说明（选项副文案） */
  private optionNote(m: number): string {
    if (m === 1) {
      return '竖屏 2 列 · 横屏 3 列';
    }
    if (m === 2) {
      return '竖屏 3 列 · 横屏 4 列';
    }
    return '按设备与横竖屏自动适配';
  }

  build() {
    Column({ space: Spacing.md }) {
      Text('列数调整')
        .fontSize(fs(17, this.fontScale))
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.textPrimary(this.isDark))
        .textAlign(TextAlign.Center)
        .width('100%')

      Text('仅在大屏设备（平板 / 阔直屏 / 折叠屏展开）生效，手机不受影响')
        .fontSize(fs(12, this.fontScale))
        .fontColor(Theme.textTertiary(this.isDark))
        .textAlign(TextAlign.Center)
        .width('100%')

      ForEach(COLUMN_MODE_OPTIONS, (m: number) => {
        Row({ space: Spacing.sm }) {
          Column({ space: 2 }) {
            Text(columnModeLabel(m))
              .fontSize(fs(15, this.fontScale))
              .fontWeight(this.mode === m ? FontWeight.Bold : FontWeight.Medium)
              .fontColor(Theme.textPrimary(this.isDark))
            Text(this.optionNote(m))
              .fontSize(fs(11, this.fontScale))
              .fontColor(Theme.textTertiary(this.isDark))
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          if (this.mode === m) {
            SymbolGlyph($r('sys.symbol.checkmark_circle'))
              .fontColor([Theme.brand()])
              .fontSize(fs(20, this.fontScale))
          }
        }
        .width('100%')
        .padding({ left: Spacing.md, right: Spacing.md, top: Spacing.md, bottom: Spacing.md })
        .backgroundColor(this.mode === m ? (this.isDark ? '#333173FF' : '#1A3173FF') : Color.Transparent)
        .borderRadius(Radius.md)
        .onClick(() => { this.onPick(m); })
      }, (m: number) => `column_mode_${m}`)

      Button() {
        Text('取消')
          .fontSize(fs(15, this.fontScale))
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textPrimary(this.isDark))
      }
      .width('100%')
      .height(44)
      .systemMaterial(ImmMaterial.cardAction())
      .backgroundColor(this.isDark ? '#B31B1E24' : '#B3FFFFFF')
      .borderRadius(Radius.full)
      .shadow({ radius: 10, color: this.isDark ? '#4D000000' : '#1F101824', offsetY: 3 })
      .onClick(() => { this.onDismiss(); })
    }
    .width('100%')
    .padding(Spacing.lg)
  }
}

@Entry
@Component
struct PersonalizedPage {
  @StorageLink('fontScale') fontScale: number = 1.0;
  /** 页面可见时自增，强制组件重建使字号实时生效 */
  @State fontSizeTick: number = 0;
  /** 「深色模式」手动开关（仅当 followSystem=false 时生效；持久化） */
  @StorageLink('appDarkMode') darkMode: boolean = false;
  /** 「跟随系统深色模式」开关（默认 true；持久化） */
  @StorageLink('appFollowSystemDark') followSystem: boolean = true;
  /** darkTick 自增：本页或其它入口（含系统 onConfigurationUpdate）触发后翻 this.isDark，与首页/MineTab 同链路 */
  @StorageLink('darkTick') @Watch('onDarkTick') darkTick: number = 0;

  onPageShow(): void {
    this.fontSizeTick++;
  }
  @State isDark: boolean = isDarkMode();
  /**
   * 「列数调整」档位（0 = 默认 / 1 = 竖二横三 / 2 = 竖三横四）。
   * 与 UsageHabitsManager 共用同一 AppStorage 真源：此处只读显示；
   * 写入统一走 setColumnMode（AppStorage + 落盘 + 广播 columnModeTick，各列表页 @Watch 回写并强制回顶）。
   */
  @StorageLink('columnMode') columnMode: number = 0;
  /** 「列数调整」三选一弹窗控制器（几何与工程既有 CustomDialog 同源：宽 dialogCardWidth()、圆角 32、底部锚点 dy -110） */
  private columnModeController: CustomDialogController = new CustomDialogController({
    builder: ColumnModeDialog({
      isDark: $isDark,
      fontScale: $fontScale,
      mode: $columnMode,
      onPick: (m: number) => { this.pickColumnMode(m); },
      onDismiss: () => { this.closeColumnMode(); }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Bottom,
    offset: { dx: 0, dy: -110 },
    maskColor: '#06000000',
    cornerRadius: 32,
    // 弹窗宽度：Dimension 不接受 'calc(100% - 48vp)' 字符串，故按窗口宽换算成数值 vp（见 dialogCardWidth）
    width: this.dialogCardWidth(),
    customStyle: false,
    systemMaterial: ImmMaterial.dialog(),
    openAnimation: { duration: 220, curve: Curve.EaseOut },
    closeAnimation: { duration: 200, curve: Curve.EaseInOut },
    onWillDismiss: () => { }
  });

  aboutToAppear(): void {
    MaterialManager.init();
    this.isDark = isDarkMode();
    // 兜底：若冷启动 Index.aboutToAppear 异常未初始化，这里也能补上（正常路径下已初始化）
    UsageHabitsManager.getInstance().init(this.getUIContext().getHostContext() as common.UIAbilityContext);
  }

  /** darkTick 递增（任意入口切换深色，包括系统 onConfigurationUpdate）→ 重读 isDarkMode() 翻本组件渲染色 */
  private onDarkTick(): void {
    this.isDark = isDarkMode();
  }

  /** 「列数调整」选定档位：走 manager 写 AppStorage + 落盘 + 广播，随后关闭弹窗（页面显示值经 @StorageLink 自动同步） */
  private pickColumnMode(mode: number): void {
    UsageHabitsManager.getInstance().setColumnMode(mode).catch(() => {
    });
    this.closeColumnMode();
  }

  /** 关闭「列数调整」弹窗 */
  private closeColumnMode(): void {
    this.columnModeController.close();
  }

  /**
   * 「列数调整」弹窗宽度（vp 数值）—— 与收藏页 / 进吧页 / 吧主页同款：`max(200, min(400, 屏宽 − 48))`。
   * 必须给数值：`CustomDialogControllerOptions.width` 类型是 `Dimension`，**不接受** `overlayCardWidth()`
   * 的 `'calc(100% - 48vp)'` 字符串（2026-09-18 构建实证）。手机档 312 逐像素与既有弹窗一致，
   * 平板 / 大折叠 / Pura X Max 同封顶 400。
   */
  private dialogCardWidth(): number {
    try {
      const info: display.Display = display.getDefaultDisplaySync();
      const widthVp: number = info.width / info.densityPixels;
      return Math.max(200, Math.min(400, widthVp - 48));
    } catch (e) {
      return 312;
    }
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 内容层：全屏沉浸滚动（参数同 Settings.ets /「我的」页范式）
      Scroll() {
        Column({ space: Spacing.sm }) {
          // 预留顶栏高度的初始间距
          Column()
            .width('100%')
            .height(90)
          // 字体大小条目
          Row({ space: Spacing.md }) {
            Stack() {
              Text('A')
                .fontSize(fs(15, this.fontScale))
                .fontWeight(FontWeight.Bold)
                .fontColor(Theme.textPrimary(this.isDark))
            }
            .width(24)
            .height(24)
            .border({ width: 2, color: Theme.textPrimary(this.isDark), radius: 4 })
            .alignContent(Alignment.Center)

            Column({ space: 2 }) {
              Text('字体大小')
                .fontSize(fs(18, this.fontScale))
                .fontWeight(FontWeight.Medium)
                .fontColor(Theme.textPrimary(this.isDark))
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            .margin({ left: Spacing.xs })

            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontColor([$r('sys.color.icon_secondary')])
              .fontSize(fs(18, this.fontScale))
          }
          .width('100%')
          .padding({ left: Spacing.lg, right: Spacing.lg, top: Spacing.xl, bottom: Spacing.xl })
          .backgroundColor(Theme.bgCard(this.isDark))
          .borderRadius(Radius.lg)
          .margin({ top: Spacing.sm })
          .onClick(() => {
            this.getUIContext().getRouter().pushUrl({ url: 'pages/FontSizePage' }).catch(() => {});
          })

          // 深色模式（手动开关）：触动本开关即自动关闭「跟随系统」，使生效行为 = 本开关值
          Row({ space: Spacing.md }) {
            SymbolGlyph($r('sys.symbol.moon_fill'))
              .fontColor([Theme.textPrimary(this.isDark)])
              .fontSize(fs(22, this.fontScale))

            Column({ space: 2 }) {
              Text('深色模式')
                .fontSize(fs(18, this.fontScale))
                .fontWeight(FontWeight.Medium)
                .fontColor(Theme.textPrimary(this.isDark))
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            .margin({ left: Spacing.xs })

            // 只作显示：hitTestBehavior(None) 让触摸穿透到外层 Row 统一处理。这样系统切色时
            // EntryAbility 同步 appDarkMode 引发的编程性 isOn 变化不会触发 onChange 副作用，
            // 根治「跟随系统深色模式」被系统切色连带自动关闭的问题。
            Toggle({ type: ToggleType.Switch, isOn: this.darkMode })
              .selectedColor(BRAND_BLUE)
              .hitTestBehavior(HitTestMode.None)
          }
          .width('100%')
          .padding({ left: Spacing.lg, right: Spacing.lg, top: Spacing.xl, bottom: Spacing.xl })
          .backgroundColor(Theme.bgCard(this.isDark))
          .borderRadius(Radius.lg)
          .margin({ top: Spacing.sm })
          .onClick(() => {
            // 用户意图只从点击进入，与原 onChange 逻辑完全等价：触动本开关即自动关闭「跟随系统」。
            // 1. 立即翻本组件 this.isDark（不依赖 setColorMode 重建，避免视觉卡顿）
            // 2. 写 manual + 关跟随系统
            // 3. Theme.setDarkMode 同步 _globalIsDark + 系统 Configuration + 状态栏
            // 4. darkTick++ 触发其它监听 darkTick 的页面（FavoriteTab/MineTab 等）翻 @State isDark
            const target: boolean = !UsageHabitsManager.getInstance().isDarkModeManual();
            this.isDark = target;
            UsageHabitsManager.getInstance().setFollowSystemDark(false);
            UsageHabitsManager.getInstance().setDarkModeManual(target);
            applyAppDarkMode(target);
            AppStorage.setOrCreate<number>('darkTick', (AppStorage.get<number>('darkTick') ?? 0) + 1);
          })

          // 跟随系统深色模式：开启时立即按系统当前态落地；关闭时不切色，由「深色模式」toggle 接管
          Row({ space: Spacing.md }) {
            SymbolGlyph($r('sys.symbol.brightness'))
              .fontColor([Theme.textPrimary(this.isDark)])
              .fontSize(fs(22, this.fontScale))

            Column({ space: 2 }) {
              Text('跟随系统深色模式')
                .fontSize(fs(18, this.fontScale))
                .fontWeight(FontWeight.Medium)
                .fontColor(Theme.textPrimary(this.isDark))
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            .margin({ left: Spacing.xs })

            // 只作显示：hitTestBehavior(None) + 外层 Row.onClick 统一承接用户意图，与上方「深色模式」
            // 开关同模式，防编程性 isOn 变化误触 onChange。
            Toggle({ type: ToggleType.Switch, isOn: this.followSystem })
              .selectedColor(BRAND_BLUE)
              .hitTestBehavior(HitTestMode.None)
          }
          .width('100%')
          .padding({ left: Spacing.lg, right: Spacing.lg, top: Spacing.xl, bottom: Spacing.xl })
          .backgroundColor(Theme.bgCard(this.isDark))
          .borderRadius(Radius.lg)
          .margin({ top: Spacing.sm })
          .onClick(() => {
            const isOn: boolean = !UsageHabitsManager.getInstance().isFollowSystemDark();
            UsageHabitsManager.getInstance().setFollowSystemDark(isOn);
            if (isOn) {
              // 开启跟随系统：写 manual = 当前系统档 + 调 resetConfigurationToFollowSystem 把
              // Configuration 重置为 NOT_SET（系统档驱动） + 调 syncDarkFromConfig 同步 _globalIsDark。
              //
              // 关键：这里**不调 setColorMode(DARK/LIGHT)**，让 Application Configuration 保持
              // COLOR_MODE_NOT_SET（跟系统档），永不锁死。这样后续系统切深色/切浅色时，
              // Configuration 自动跟档，ForumsTitleBar / HomeTitleBar 的 systemMaterial 与
              // $r('sys.color.font_primary') 自动翻档。
              // 手动档（用户切色 / PersonalizedPage 深色模式开关）才会调 setColorMode 锁死。
              const ctx: common.UIAbilityContext =
                this.getUIContext().getHostContext() as common.UIAbilityContext;
              const sysDark: boolean =
                ctx.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
              UsageHabitsManager.getInstance().setDarkModeManual(sysDark);
              resetConfigurationToFollowSystem();
              syncDarkFromConfig(sysDark);
              this.isDark = sysDark;
              AppStorage.setOrCreate<number>('darkTick', (AppStorage.get<number>('darkTick') ?? 0) + 1);
            } else {
              // 关闭：不切色——保持当前 dark 值，「深色模式」开关后续接管
              // 仍递增 darkTick 让其它页面同步（即便本组件未切色，也保证链路上各页 @State isDark 与开关一致）
              AppStorage.setOrCreate<number>('darkTick', (AppStorage.get<number>('darkTick') ?? 0) + 1);
            }
          })

          // 列数调整：三选一（默认 / 竖二横三 / 竖三横四），仅大屏形态（平板 / 阔直屏 / 大折叠展开）生效，
          // 手机档与窄窗闸门不覆盖；阔直屏竖屏全屏走 isWideBarFullscreen 白名单放行
          Row({ space: Spacing.md }) {
            SymbolGlyph($r('sys.symbol.grid'))
              .fontColor([Theme.textPrimary(this.isDark)])
              .fontSize(fs(22, this.fontScale))

            Column({ space: 2 }) {
              Text('列数调整')
                .fontSize(fs(18, this.fontScale))
                .fontWeight(FontWeight.Medium)
                .fontColor(Theme.textPrimary(this.isDark))
              Text('平板 / 阔直屏 / 折叠屏展开的列表列数')
                .fontSize(fs(12, this.fontScale))
                .fontColor(Theme.textSecondary(this.isDark))
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            .margin({ left: Spacing.xs })

            Text(columnModeLabel(this.columnMode))
              .fontSize(fs(14, this.fontScale))
              .fontColor(Theme.textTertiary(this.isDark))

            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontColor([Theme.textTertiary(this.isDark)])
              .fontSize(fs(18, this.fontScale))
          }
          .width('100%')
          .padding({ left: Spacing.lg, right: Spacing.lg, top: Spacing.xl, bottom: Spacing.xl })
          .backgroundColor(Theme.bgCard(this.isDark))
          .borderRadius(Radius.lg)
          .margin({ top: Spacing.sm })
          .onClick(() => { this.columnModeController.open(); })
        }
        .width('100%')
        .padding({ left: Spacing.lg, right: Spacing.lg, bottom: Spacing.xl })
      }
      .scrollBar(BarState.Off)
      .scrollable(ScrollDirection.Vertical)
      .edgeEffect(EdgeEffect.Spring)
      .width('100%')
      .layoutWeight(1)
      .clip(false)
      .align(Alignment.TopStart)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .overlay(this.BottomFadeOverlay())
      .blendMode(BlendMode.SRC_OVER, BlendApplyType.OFFSCREEN)

      // 悬浮沉浸顶栏（透明底，内容可穿过；参数同 Settings.ets）
      this.TopBar()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg(this.isDark))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  /** 悬浮沉浸顶栏（透明底，内容可穿过；参数同 Settings.ets） */
  @Builder
  TopBar() {
    Row({ space: Spacing.sm }) {
      Button() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontColor([$r('sys.color.icon_primary')])
          .fontSize(fs(28, this.fontScale))
      }
      .width(44)
      .height(44)
      .backgroundColor(Theme.manualGlass(this.isDark))
      .border({ width: 0.5, color: Theme.manualGlassBorder() })
      .shadow(Theme.glassShadowStyle()).backgroundEffect(ImmBlur.control())
      .systemMaterial(ImmMaterial.control())
      .borderRadius(Radius.full)
      .accessibilityText('返回')
      .onClick(() => { this.getUIContext().getRouter().back(); })

      Text('个性化')
        .fontSize(fs(18, this.fontScale))
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.textPrimary(this.isDark))
    }
    .width('100%')
    .padding({ left: Spacing.lg, right: Spacing.lg, top: 44, bottom: 10 })
    .backgroundColor(Color.Transparent)
    .zIndex(14)
  }

  /** 渐变沉浸遮罩：顶部渐显（同 Settings.ets / Index「我的」范式） */
  @Builder
  BottomFadeOverlay() {
    Stack()
      .height('100%')
      .width('100%')
      .linearGradient({
        direction: GradientDirection.Bottom,
        colors: [['#00FFFFFF', 0.0], ['#FFFFFFFF', tabletTopFadeStop(98)], ['#FFFFFFFF', 1.0]]
      })
      .blendMode(BlendMode.DST_IN, BlendApplyType.OFFSCREEN)
      .hitTestBehavior(HitTestMode.None)
  }
}
