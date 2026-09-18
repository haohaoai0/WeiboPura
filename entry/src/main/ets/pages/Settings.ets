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

import { common, Want } from '@kit.AbilityKit';
import { AuthManager } from '../service/AuthManager';
import { TiebaService } from '../service/TiebaService';
import { PRIVACY_POLICY_URL } from '../common/Constants';
import { Theme, Spacing, Radius, isDarkMode, ImmBlur, ImmMaterial, MaterialManager, fs, tabletTopFadeStop } from '../common/Theme';

/** 官方标题栏开关（§6.10 模板）：true 且设备支持材质时，「返回 + 软件设置」搬进 Navigation title 槽位吃官方材质；
 *  false 或低版本自动回退到页面主体悬浮自绘玻璃 TopBar（原样保留）。 */
const SETTINGS_OFFICIAL_TITLE_BAR: boolean = true;
/** 槽位高度 = 44(状态栏让位) + 44(按钮行高) + 10(底部呼吸)，与原悬浮 TopBar 的 padding 逐项一致；
 *  内容让位（Scroll 首项占位 90）一行未改。 */
const SETTINGS_TITLE_BAR_HEIGHT: number = 98;

@Entry
@Component
struct Settings {
  @State isDark: boolean = isDarkMode();
  @State userName: string = '';
  @State userAvatar: string = '';
  @State loggedIn: boolean = false;
  @StorageLink('fontScale') fontScale: number = 1.0;
  /** 页面可见时自增，强制组件重建使字号实时生效 */
  @State fontSizeTick: number = 0;
  /** API26+ 沉浸光感能力：true 时顶栏走官方 title 槽位，否则回退自绘玻璃 TopBar（与 ThreadDetail 同判据） */
  @State materialSupported: boolean = false;
  /** darkTick 自增（个性化页 / 其它 Tab 切换深色 / 系统 onConfigurationUpdate）→ 翻 this.isDark，避免从子页返回时仍是旧档 */
  @StorageLink('darkTick') @Watch('onDarkTick') darkTick: number = 0;

  onPageShow(): void {
    this.fontSizeTick++;
    // 页面每次可见都刷新登录态：覆盖「首次进入」与「从登录页返回」两个时点，
    // 否则账号卡片会一直停留在 @State 初始的未登录态
    this.loadUserInfo();
  }

  aboutToAppear(): void {
    MaterialManager.init();
    this.materialSupported = MaterialManager.isSupported() && MaterialManager.getApiLevel() >= 26;
    this.isDark = isDarkMode();
    this.loadUserInfo();
  }

  /** darkTick 递增 → 重读 isDarkMode() 翻 this.isDark，与 MineTab / PersonalizedPage 同链路 */
  private onDarkTick(): void {
    this.isDark = isDarkMode();
    this.loadUserInfo();
  }

  private loadUserInfo(): void {
    const user = AuthManager.getInstance().getUser();
    if (user) {
      this.loggedIn = true;
      this.userName = user.name ?? '未登录';
      this.userAvatar = user.avatar ?? '';
    } else {
      this.loggedIn = false;
      this.userName = '未登录';
      this.userAvatar = '';
    }
  }

  private openItem(item: string): void {
    this.getUIContext().getPromptAction().showToast({ message: `${item} 即将开放` });
  }

  /** 打开完整隐私政策：与首启同意弹窗、应用市场「隐私政策网址」共用同一份在线政策（PRIVACY_POLICY_URL） */
  private openPrivacyPolicy(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    if (!ctx) {
      this.getUIContext().getPromptAction().showToast({ message: '打开失败，请稍后重试' });
      return;
    }
    const want: Want = { uri: PRIVACY_POLICY_URL, action: 'ohos.want.action.viewData', type: 'text/plain' };
    ctx.startAbility(want).catch(() => {
      this.getUIContext().getPromptAction().showToast({ message: '打开失败，请稍后重试' });
    });
  }

  private async handleLogout(): Promise<void> {
    await AuthManager.getInstance().logout();
    TiebaService.getInstance().invalidateStokenCache();
    this.loadUserInfo();
    this.getUIContext().getPromptAction().showToast({ message: '已退出登录' });
  }

  /** 页面内容层（原 build() 根 Stack，槽位 / 兜底两条路径共用） */
  @Builder
  SettingsContent() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 内容层：全屏沉浸滚动，clip(false) 让内容可穿过悬浮顶栏；
      // overlay 全屏渐变遮罩使内容滚入顶栏区域时渐进显现（参数同「我的」页 MineContent 范式）
      Scroll() {
        Column() {
          // 预留顶栏高度的初始间距（同「我的」页 ListItem spacer 范式）
          Column()
            .width('100%')
            .height(90)

          // 账号管理卡片
          this.AccountCard()

          // 设置列表
          this.SettingsList()

          // 退出登录按钮
          if (this.loggedIn) {
            Button('退出登录')
              .width('100%')
              .height(50)
              .fontSize(fs(16, this.fontScale))
              .fontColor(Theme.danger())
              .fontWeight(FontWeight.Medium)
              .backgroundColor(Theme.bgCard(this.isDark))
              .borderRadius(Radius.lg)
              .margin({ top: Spacing.lg })
              .onClick(() => this.handleLogout())
          }
        }
        .width('100%')
        .padding({ left: Spacing.lg, right: Spacing.lg, top: Spacing.md, bottom: Spacing.xl })
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

      // 悬浮沉浸顶栏（透明底，内容可穿过；同「我的」页 TopBar 范式）；
      // 官方 title 槽位路径下已在槽位里（SettingsTitleBar），不再叠一层
      if (!(SETTINGS_OFFICIAL_TITLE_BAR && this.materialSupported)) {
        this.TopBar()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg(this.isDark))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  build() {
    if (SETTINGS_OFFICIAL_TITLE_BAR && this.materialSupported) {
      // 官方槽位路径（§6.10）：返回钮 + 标题搬进 Navigation title 槽位吃真材质
      Navigation() {
        this.SettingsContent()
      }
      .title({ builder: this.SettingsTitleBar(), height: SETTINGS_TITLE_BAR_HEIGHT },
        { barStyle: BarStyle.STACK, backgroundColor: Color.Transparent })
      .mode(NavigationMode.Stack)
      .hideTitleBar(false)
      .hideBackButton(true)
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.bg(this.isDark))
      .clip(false)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    } else {
      // 兜底路径：页面主体悬浮自绘玻璃（改造前原样）
      this.SettingsContent()
    }
  }

  /** 兜底路径专用（开关关闭 / 低版本时才挂载）：页面主体悬浮自绘玻璃顶栏（透明底，内容可穿过） */
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

      Text('软件设置')
        .fontSize(fs(18, this.fontScale))
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.textPrimary(this.isDark))
    }
    .width('100%')
    .padding({ left: Spacing.lg, right: Spacing.lg, top: 44, bottom: 10 })
    .backgroundColor(Color.Transparent)
    .zIndex(14)
  }

  /**
   * 官方槽位标题栏（§6.10 同机制）：返回 44 圆钮 + 「软件设置」标题。
   * 玻璃换成 `ImmMaterial.seg(false)`（THIN 中性档），按坑 24 删除 `manualGlass` / `manualGlassBorder` /
   * `glassShadowStyle` + `backgroundEffect(ImmBlur.control())` / `control()` 四项自绘玻璃；
   * `Button` 补 `backgroundColor(Color.Transparent)` 清默认品牌蓝填充（原写法已有，保留）。
   * 几何（top 44 / bottom 10 / 左右 Spacing.lg / 圆钮 44 / space Spacing.sm / 标题 fontSize 18）逐项一致；
   * `zIndex(14)` 槽内无叠层序需求，去掉。
   */
  @Builder
  SettingsTitleBar() {
    Row({ space: Spacing.sm }) {
      Button() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontColor([$r('sys.color.icon_primary')])
          .fontSize(fs(28, this.fontScale))
      }
      .width(44)
      .height(44)
      .backgroundColor(Color.Transparent)
      .systemMaterial(ImmMaterial.seg(false))
      .borderRadius(Radius.full)
      .accessibilityText('返回')
      .onClick(() => { this.getUIContext().getRouter().back(); })

      Text('软件设置')
        .fontSize(fs(18, this.fontScale))
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.textPrimary(this.isDark))
    }
    .width('100%')
    .padding({ left: Spacing.lg, right: Spacing.lg, top: 44, bottom: 10 })
  }

  /** 渐变沉浸遮罩：顶部渐显（同 Index「我的」BottomFadeOverlay 范式，参数一致） */
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

  @Builder
  AccountCard() {
    Row({ space: Spacing.md }) {
      // 头像
      if (this.loggedIn && this.userAvatar.length > 0) {
        Image(this.userAvatar)
          .width(56)
          .height(56)
          .borderRadius(28)
          .objectFit(ImageFit.Cover)
          .clip(true)
      } else {
        Stack() {
          Text(this.loggedIn ? this.userName.charAt(0) : '?')
            .fontSize(fs(24, this.fontScale))
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.brand())
        }
        .width(56)
        .height(56)
        .borderRadius(28)
        .backgroundColor(Theme.brandBg(this.isDark))
        .alignContent(Alignment.Center)
      }

      // 用户信息
      Column({ space: 4 }) {
        Text(this.loggedIn ? this.userName : '未登录')
          .fontSize(fs(18, this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.textPrimary(this.isDark))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.loggedIn ? '已登录账号' : '点击登录')
          .fontSize(fs(13, this.fontScale))
          .fontColor(Theme.textSecondary(this.isDark))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      // 右箭头
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontColor([$r('sys.color.icon_secondary')])
        .fontSize(fs(18, this.fontScale))
    }
    .width('100%')
    .padding({ left: Spacing.lg, right: Spacing.lg, top: Spacing.lg, bottom: Spacing.lg })
    .backgroundColor(Theme.bgCard(this.isDark))
    .borderRadius(Radius.lg)
    .margin({ bottom: Spacing.lg })
    .onClick(() => {
      if (!this.loggedIn) {
        this.getUIContext().getRouter().pushUrl({ url: 'pages/Login' }).catch(() => {});
      } else {
        this.openItem('账号管理');
      }
    })
  }

  @Builder
  SettingsList() {
    Column({ space: Spacing.sm }) {
      this.SettingItem(
        $r('sys.symbol.lock'),
        '屏蔽设置',
        '眼不见心不烦',
        () => { this.getUIContext().getRouter().pushUrl({ url: 'pages/ShieldSettings' }).catch(() => {}); }
      )
      this.SettingItem(
        $r('sys.symbol.circle'),
        '个性化',
        '文字大小、UI 界面',
        () => { this.getUIContext().getRouter().pushUrl({ url: 'pages/PersonalizedPage' }).catch(() => {}); }
      )
      this.SettingItem(
        $r('sys.symbol.hand'),
        '使用习惯',
        '万般功能不如自己顺手',
        () => { this.getUIContext().getRouter().pushUrl({ url: 'pages/UsageHabitsPage' }).catch(() => {}); }
      )
      this.SettingItem(
        $r('sys.symbol.bell'),
        '一键签到',
        '一键签到功能设定',
        () => { this.getUIContext().getRouter().pushUrl({ url: 'pages/AutoSignSettings' }).catch(() => {}); }
      )
      this.SettingItem(
        $r('sys.symbol.lock_shield'),
        '隐私政策',
        '我们如何收集与使用您的信息',
        () => this.openPrivacyPolicy()
      )
      this.SettingItem(
        $r('sys.symbol.ellipsis_circle'),
        '更多',
        '其他杂项',
        () => this.openItem('更多')
      )
    }
    .width('100%')
  }

  @Builder
  SettingItem(icon: Resource, title: string, subtitle: string, action: () => void) {
    Row({ space: Spacing.md }) {
      SymbolGlyph(icon)
        .fontColor([$r('sys.color.icon_primary')])
        .fontSize(fs(22, this.fontScale))

      Column({ space: 2 }) {
        Text(title)
          .fontSize(fs(16, this.fontScale))
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textPrimary(this.isDark))
        Text(subtitle)
          .fontSize(fs(13, this.fontScale))
          .fontColor(Theme.textSecondary(this.isDark))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontColor([$r('sys.color.icon_secondary')])
        .fontSize(fs(18, this.fontScale))
    }
    .width('100%')
    .padding({ left: Spacing.lg, right: Spacing.lg, top: Spacing.md, bottom: Spacing.md })
    .backgroundColor(Theme.bgCard(this.isDark))
    .borderRadius(Radius.lg)
    .onClick(() => action())
  }
}

