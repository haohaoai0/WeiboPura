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

import { common } from '@kit.AbilityKit';
import { AutoSignManager } from '../service/AutoSignManager';
import { Theme, Spacing, Radius, isDarkMode, ImmBlur, ImmMaterial, MaterialManager, fs, tabletTopFadeStop } from '../common/Theme';
import { BRAND_BLUE } from '../common/Constants';
import { Haptic } from '../common/Haptic';

/**
 * 一键签到设置页（软件设置 → 一键签到）。
 * 一级界面，仅提供一键签到相关的功能开关，视觉/间距/交互与其它设置页（Settings / UsageHabitsPage）完全一致：
 *   悬浮沉浸顶栏 + 全屏沉浸滚动 + 卡片行（图标 + 标题 + 灰字说明 + 开关）+ 顶部渐隐遮罩。
 * 两个开关均持久化（AutoSignManager），点按开关带轻振动反馈。
 */
@Entry
@Component
struct AutoSignSettings {
  /** 慢速模式：签到每个吧的时间间隔更长 */
  @StorageLink('autoSignSlowMode') slowMode: boolean = true;
  /** 使用官方一键签到：先批量签一批，减少逐吧签到数量 */
  @StorageLink('autoSignUseOfficial') useOfficial: boolean = true;
  @State isDark: boolean = isDarkMode();
  @StorageLink('fontScale') fontScale: number = 1.0;
  /** 页面可见时自增，强制组件重建使字号实时生效 */
  @State fontSizeTick: number = 0;

  onPageShow(): void {
    this.fontSizeTick++;
  }

  aboutToAppear(): void {
    MaterialManager.init();
    this.isDark = isDarkMode();
    AutoSignManager.getInstance().init(this.getUIContext().getHostContext() as common.UIAbilityContext);
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 内容层：全屏沉浸滚动（参数同 Settings.ets / UsageHabitsPage 范式）
      Scroll() {
        Column({ space: Spacing.sm }) {
          // 预留顶栏高度的初始间距
          Column()
            .width('100%')
            .height(90)

          Column() {
            this.SwitchRow(
              $r('sys.symbol.arrow_clockwise'),
              '慢速模式',
              '一键签到时签到每个吧的时间间隔将会更长。',
              this.slowMode,
              (isOn: boolean) => {
                Haptic.light();
                AutoSignManager.getInstance().setSlowMode(isOn);
              }
            )
          }
          .width('100%')
          .margin({ top: Spacing.sm })

          this.SwitchRow(
            $r('sys.symbol.bell'),
            '使用官方一键签到',
            '先使用官方一键签到减少需签到吧数量，以加快签到速度',
            this.useOfficial,
            (isOn: boolean) => {
              Haptic.light();
              AutoSignManager.getInstance().setUseOfficial(isOn);
            }
          )
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

      Text('一键签到')
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

  /** 开关行（图标 + 标题 + 灰字说明 + 开关；卡片与内距同 UsageHabitsPage） */
  @Builder
  SwitchRow(icon: Resource, title: string, subtitle: string, isOn: boolean, onChange: (isOn: boolean) => void) {
    Row({ space: Spacing.md }) {
      SymbolGlyph(icon)
        .fontColor([Theme.brand()])
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

      Toggle({ type: ToggleType.Switch, isOn: isOn })
        .selectedColor(BRAND_BLUE)
        .onChange((value: boolean) => {
          onChange(value);
        })
    }
    .width('100%')
    .padding({ left: Spacing.lg, right: Spacing.lg, top: Spacing.md, bottom: Spacing.md })
    .backgroundColor(Theme.bgCard(this.isDark))
    .borderRadius(Radius.lg)
  }
}
