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
import { UsageHabitsManager } from '../service/UsageHabitsManager';
import { Theme, Spacing, Radius, isDarkMode, ImmBlur, ImmMaterial, MaterialManager, fs, tabletTopFadeStop, isWideBarFlatDevice } from '../common/Theme';
import { BRAND_BLUE } from '../common/Constants';

@Entry
@Component
struct UsageHabitsPage {
  @StorageLink('homeOnlyFollow') onlyFollow: boolean = false;
  /** 「关闭自动旋转」开关（仅阔直屏直板显示；true = 已关闭自动旋转、固定竖屏） */
  @StorageLink('autoRotateOff') autoRotateOff: boolean = false;
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
    UsageHabitsManager.getInstance().init(this.getUIContext().getHostContext() as common.UIAbilityContext);
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
          // 仅推荐关注的吧
          Row({ space: Spacing.md }) {
            SymbolGlyph($r('sys.symbol.hand'))
              .fontColor([Theme.brand()])
              .fontSize(fs(22, this.fontScale))

            Column({ space: 2 }) {
              Text('仅推荐关注的吧')
                .fontSize(fs(16, this.fontScale))
                .fontWeight(FontWeight.Medium)
                .fontColor(Theme.textPrimary(this.isDark))
              Text('首页推荐仅显示关注吧的帖子')
                .fontSize(fs(13, this.fontScale))
                .fontColor(Theme.textSecondary(this.isDark))
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Toggle({ type: ToggleType.Switch, isOn: this.onlyFollow })
              .selectedColor(BRAND_BLUE)
              .onChange((isOn: boolean) => {
                UsageHabitsManager.getInstance().setOnlyFollow(isOn);
              })
          }
          .width('100%')
          .padding({ left: Spacing.lg, right: Spacing.lg, top: Spacing.md, bottom: Spacing.md })
          .backgroundColor(Theme.bgCard(this.isDark))
          .borderRadius(Radius.lg)
          .margin({ top: Spacing.sm })

          // 关闭自动旋转（仅阔直屏直板显示：只有该形态由本应用主动解锁了自动旋转）
          if (isWideBarFlatDevice()) {
            Row({ space: Spacing.md }) {
              SymbolGlyph($r('sys.symbol.arrow_clockwise'))
                .fontColor([Theme.brand()])
                .fontSize(fs(22, this.fontScale))

              Column({ space: 2 }) {
                Text('关闭自动旋转')
                  .fontSize(fs(16, this.fontScale))
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Theme.textPrimary(this.isDark))
                Text('开启后固定竖屏，不再自动转为横屏')
                  .fontSize(fs(13, this.fontScale))
                  .fontColor(Theme.textSecondary(this.isDark))
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Toggle({ type: ToggleType.Switch, isOn: this.autoRotateOff })
                .selectedColor(BRAND_BLUE)
                .onChange((isOn: boolean) => {
                  UsageHabitsManager.getInstance().setAutoRotateOff(isOn);
                })
            }
            .width('100%')
            .padding({ left: Spacing.lg, right: Spacing.lg, top: Spacing.md, bottom: Spacing.md })
            .backgroundColor(Theme.bgCard(this.isDark))
            .borderRadius(Radius.lg)
          }
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

      Text('使用习惯')
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
