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

import { FontSizeManager } from '../service/FontSizeManager';
import { Theme, Spacing, Radius, isDarkMode, ImmBlur, ImmMaterial, MaterialManager, tabletTopFadeStop } from '../common/Theme';

@Entry
@Component
struct FontSizePage {
  @StorageLink('fontScale') @Watch('onFontScaleChange') fontScale: number = 1.0;
  @StorageLink('fontLevel') fontLevel: number = 2;
  @State isDark: boolean = isDarkMode();
  /** 档位/页面可见时自增，强制组件重建使字号实时生效（规避 @StorageLink 同步/离屏缓存不刷新的问题） */
  @State fontSizeTick: number = 0;
  /** 左右滑动手势：实时跟随手指的水平位移，松手时回弹并切换档位 */
  @State panOffsetX: number = 0;

  aboutToAppear(): void {
    MaterialManager.init();
    this.isDark = isDarkMode();
  }

  onPageShow(): void {
    this.fontSizeTick++;
  }

  /** 字号档位变化回调：用于确认状态链路是否触发（运行时看 HiLog: FontSizePage） */
  onFontScaleChange(propName: string): void {
    console.info(`[FontSizePage] ${propName} -> ${this.fontScale}, level=${this.fontLevel}`);
  }

  /** 按当前缩放倍率计算实际字号（直接依赖 @StorageLink 属性，保证声明式刷新） */
  private scaled(base: number): number {
    return Math.round(base * this.fontScale);
  }

  /**
   * 切换档位：animateTo 包裹状态写入，让圆点缩放/颜色、预览区字号、顶部标签等属性差异平滑过渡（300ms）
   * 持久化异步执行，不阻塞动画
   */
  private selectLevel(level: number): void {
    const target = Math.max(0, Math.min(5, level));
    if (target === this.fontLevel) {
      return;
    }
    this.getUIContext().animateTo(
      { duration: 300, curve: Curve.EaseInOut },
      () => {
        // 同步设置 AppStorage + 本地字段，触发 build 中相关属性表达式变化，animateTo 让变化平滑
        AppStorage.setOrCreate<number>('fontScale', FontSizeManager.scaleOf(target));
        AppStorage.setOrCreate<number>('fontLevel', target);
        // fontTick 广播（2026-09-13）：常驻 Tab 页离屏期间 @StorageLink 同步不重绘，
        // 由各 Tab @Watch 响应后显式回写 fontScale 强制刷新（与 darkTick 同款模式）
        AppStorage.setOrCreate<number>('fontTick', (AppStorage.get<number>('fontTick') ?? 0) + 1);
        this.fontLevel = target;
      }
    );
    // 持久化异步进行（不阻塞动画；内部会再次 setOrCreate 同一值，无副作用）
    FontSizeManager.getInstance().setLevel(target);
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        // 内容区：全屏沉浸滚动（参数同 Settings.ets /「我的」页范式）
        Scroll() {
          Column() {
            // 预留顶栏高度的初始间距
            Column()
              .width('100%')
              .height(90)

            // 蓝色提示气泡
            Column() {
              Text('怎么调节应用内的字体大小呢？')
                .fontSize(this.scaled(17))
                .fontWeight(FontWeight.Medium)
                .fontColor(Color.White)
                .textAlign(TextAlign.Center)
                .width('100%')
            }
            .width('85%')
            .padding({ left: Spacing.lg, right: Spacing.lg, top: Spacing.lg, bottom: Spacing.lg })
            .backgroundColor(Theme.brand())
            .borderRadius(Radius.lg)
            .margin({ top: Spacing.md, bottom: Spacing.xl * 2 })

            // 说明文字
            Text('尝试着调节下方的控制条吧，可以在这里即时预览字体大小。')
              .fontSize(this.scaled(16))
              .fontColor(Theme.textPrimary(this.isDark))
              .width('100%')
              .lineHeight(this.scaled(26))

            // 字体大小预览样本区（随下方控制条实时缩放，便于对比各档位字号）
            Column() {
              // 卡片标题
              Text('字体大小预览')
                .fontSize(this.scaled(13))
                .fontWeight(FontWeight.Medium)
                .fontColor(Theme.textTertiary(this.isDark))
                .width('100%')
                .margin({ bottom: Spacing.md })

              // 标题档示例
              Text('标题 · 这是一行一级标题文字')
                .fontSize(this.scaled(24))
                .fontWeight(FontWeight.Bold)
                .fontColor(Theme.textPrimary(this.isDark))
                .width('100%')
                .margin({ bottom: Spacing.md })

              // 副标题档示例
              Text('副标题 · 这是一行二级标题文字')
                .fontSize(this.scaled(20))
                .fontWeight(FontWeight.Medium)
                .fontColor(Theme.textPrimary(this.isDark))
                .width('100%')
                .margin({ bottom: Spacing.md })

              // 正文档示例
              Text('正文 · 调节下方控制条，这里的示例文字会随档位实时变化，方便对比不同字号下的阅读效果。')
                .fontSize(this.scaled(16))
                .fontColor(Theme.textSecondary(this.isDark))
                .width('100%')
                .lineHeight(this.scaled(26))
                .margin({ bottom: Spacing.md })

              // 辅助小字示例
              Text('辅助文字 · 极小档位下的小字也能清晰阅读')
                .fontSize(this.scaled(13))
                .fontColor(Theme.textTertiary(this.isDark))
                .width('100%')
            }
            .width('100%')
            .padding(Spacing.lg)
            .backgroundColor(Theme.bgCard(this.isDark))
            .border({ width: 0.5, color: Theme.divider(this.isDark) })
            .borderRadius(Radius.lg)
            .margin({ top: Spacing.xl, bottom: Spacing.xl })
          }
          .width('100%')
          .padding({ left: Spacing.lg, right: Spacing.lg, bottom: Spacing.xl * 4 })
        }
        .scrollBar(BarState.Off)
        .scrollable(ScrollDirection.Vertical)
        .edgeEffect(EdgeEffect.Spring)
        .width('100%')
        .layoutWeight(1)
        .clip(false)
        .align(Alignment.TopStart)
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
        .overlay(this.BottomFadeOverlay())
        .blendMode(BlendMode.SRC_OVER, BlendApplyType.OFFSCREEN)
        // 左右滑动手势切换档位：priorityGesture 优先于 Scroll 自带滚动识别，否则 PanGesture 竞争不过 Scroll 的触摸处理
        // 手势必须内联在 build() 中（经方法返回的实例每次 build 重建会导致手势失效）
        // 方向：向右滑减小、向左滑增大；圆点 Row 仍跟随手指平移（translate 绑定 panOffsetX）
        .priorityGesture(
          PanGesture({ direction: PanDirection.Horizontal, distance: 10 })
            .onActionUpdate((event: GestureEvent) => {
              this.panOffsetX = event.offsetX;
            })
            .onActionEnd((event: GestureEvent) => {
              const dx = event.offsetX;
              let target = this.fontLevel;
              if (dx > 40) {
                target = this.fontLevel - 1;
              } else if (dx < -40) {
                target = this.fontLevel + 1;
              }
              const clamped = Math.max(0, Math.min(5, target));
              // 一个 animateTo 里同时复位 panOffsetX + 写入新档位，平移回弹与字号过渡并行
              this.getUIContext().animateTo(
                { duration: 300, curve: Curve.EaseInOut },
                () => {
                  this.panOffsetX = 0;
                  if (clamped !== this.fontLevel) {
                    AppStorage.setOrCreate<number>('fontScale', FontSizeManager.scaleOf(clamped));
                    AppStorage.setOrCreate<number>('fontLevel', clamped);
                    AppStorage.setOrCreate<number>('fontTick', (AppStorage.get<number>('fontTick') ?? 0) + 1);
                    this.fontLevel = clamped;
                  }
                }
              );
              if (clamped !== this.fontLevel) {
                FontSizeManager.getInstance().setLevel(clamped);
              }
            })
            .onActionCancel(() => {
              this.getUIContext().animateTo(
                { duration: 200, curve: Curve.EaseOut },
                () => { this.panOffsetX = 0; }
              );
            })
        )

        // 底部控制条区域
        Column() {
          // 当前级别标签
          Text(FontSizeManager.labelOf(this.fontLevel))
            .fontSize(this.scaled(18))
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.brand())
            .margin({ bottom: Spacing.lg })

          // 6 档圆点控制条（Row 用 layoutWeight 等分，圆点居中于各等分槽，首尾圆点距屏边有 1/12 屏宽空隙，避免贴边）
          Row() {
            ForEach([0, 1, 2, 3, 4, 5], (level: number) => {
              Column() {
                Circle()
                  .width(level === this.fontLevel ? 22 : 14)
                  .height(level === this.fontLevel ? 22 : 14)
                  .fill(level === this.fontLevel ? Theme.brand() : Theme.textTertiary(this.isDark))
                  .onClick(() => { this.selectLevel(level); })
              }
              .layoutWeight(1)
              .justifyContent(FlexAlign.Center)
            }, (level: number) => level.toString())
          }
          .width('100%')
          // 手势过程中跟随手指水平位移，松手后由 onActionEnd 的 animateTo 平滑回弹到 0
          .translate({ x: this.panOffsetX })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        .padding({ left: Spacing.lg, right: Spacing.lg, top: Spacing.xl * 2, bottom: Spacing.xl * 2 })
        // 底部控制条区域同样响应左右滑动（Scroll 之外，普通 gesture 即可；方向与内容区一致：右滑减小、左滑增大）
        .gesture(
          PanGesture({ direction: PanDirection.Horizontal, distance: 10 })
            .onActionUpdate((event: GestureEvent) => {
              this.panOffsetX = event.offsetX;
            })
            .onActionEnd((event: GestureEvent) => {
              const dx = event.offsetX;
              let target = this.fontLevel;
              if (dx > 40) {
                target = this.fontLevel - 1;
              } else if (dx < -40) {
                target = this.fontLevel + 1;
              }
              const clamped = Math.max(0, Math.min(5, target));
              this.getUIContext().animateTo(
                { duration: 300, curve: Curve.EaseInOut },
                () => {
                  this.panOffsetX = 0;
                  if (clamped !== this.fontLevel) {
                    AppStorage.setOrCreate<number>('fontScale', FontSizeManager.scaleOf(clamped));
                    AppStorage.setOrCreate<number>('fontLevel', clamped);
                    AppStorage.setOrCreate<number>('fontTick', (AppStorage.get<number>('fontTick') ?? 0) + 1);
                    this.fontLevel = clamped;
                  }
                }
              );
              if (clamped !== this.fontLevel) {
                FontSizeManager.getInstance().setLevel(clamped);
              }
            })
            .onActionCancel(() => {
              this.getUIContext().animateTo(
                { duration: 200, curve: Curve.EaseOut },
                () => { this.panOffsetX = 0; }
              );
            })
        )
      }
      .width('100%')
      .height('100%')

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
          .fontSize(this.scaled(28))
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

      Text('字体大小')
        .fontSize(this.scaled(18))
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
