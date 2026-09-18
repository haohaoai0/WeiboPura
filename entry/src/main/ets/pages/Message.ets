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

import { deviceInfo } from '@kit.BasicServicesKit';
import { display } from '@kit.ArkUI';
import { TiebaService } from '../service/TiebaService';
import { AuthManager } from '../service/AuthManager';
import { Conversation } from '../model/DataModel';
import { Theme, Spacing, Radius, isDarkMode, ImmBlur, ImmMaterial, MaterialManager, fs, isWideFormDevice as detectWideFormDevice } from '../common/Theme';
import { LoadingView, EmptyView, ErrorView } from '../components/CommonComponents';

enum LoadState {
  Loading, Success, Empty, Error,
}

@Entry
@Component
struct Message {
  /**
   * 顶部渐显带收窄（2026-09-13 用户反馈）：平板竖屏下原 15% 渐显覆盖到第一个卡片中部，
   * 要求「只覆盖顶部按钮与标题」→ 平板档覆盖高度 = 顶栏 98vp，手机维持原比例。
   */
  private readonly isWideFormDevice: boolean = detectWideFormDevice();
  /** 屏幕长边（vp）：竖屏视口高的稳定来源（旋转取长边，渐显比例不漂移） */
  @State fadeCoverVp: number = 0;
  @State conversations: Conversation[] = [];
  @State loadState: LoadState = LoadState.Loading;
  @State errorMsg: string = '';
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
    // 顶部渐显带覆盖基准（平板收窄用）：取屏幕长边（竖屏视口高），窗口未 attach 时忽略
    try {
      const d: display.Display = display.getDefaultDisplaySync();
      this.fadeCoverVp = Math.max(d.width, d.height) / d.densityPixels;
    } catch (e) {
      // 忽略：窗口未 attach，fadeCoverVp 保持 0 → topFadeStop() 回退手机比例
    }
    if (!AuthManager.getInstance().isLogin()) {
      this.loadState = LoadState.Empty;
      return;
    }
    this.loadConversations();
  }

  async loadConversations(): Promise<void> {
    this.loadState = LoadState.Loading;
    try {
      const list = await TiebaService.getInstance().fetchConversations();
      this.conversations = list;
      this.loadState = list.length > 0 ? LoadState.Success : LoadState.Empty;
    } catch (e) {
      this.loadState = LoadState.Error;
      this.errorMsg = (e as Error).message ?? '加载失败';
    }
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (!AuthManager.getInstance().isLogin()) {
        EmptyView({
          message: '登录后查看私信',
          icon: '💬',
          actionText: '去登录',
          action: () => { this.getUIContext().getRouter().pushUrl({ url: 'pages/Login' }); },
        }).layoutWeight(1)
      } else if (this.loadState === LoadState.Loading) {
        LoadingView({ message: '加载私信...' }).layoutWeight(1)
      } else if (this.loadState === LoadState.Error) {
        ErrorView({ message: this.errorMsg, onRetry: () => { this.loadConversations(); } }).layoutWeight(1)
      } else if (this.loadState === LoadState.Empty) {
        EmptyView({ message: '暂无私信会话', icon: '💬' }).layoutWeight(1)
      } else {
        List({ space: Spacing.md }) {
          // 预留顶栏高度作为初始间距
          ListItem() {
            Column().width('100%').height(90)
          }
          ForEach(this.conversations, (c: Conversation) => {
            ListItem() {
              Row({ space: Spacing.md }) {
                // 头像占位
                Text(c.name.charAt(0))
                  .fontSize(fs(16, this.fontScale))
                  .fontColor(Color.White)
                  .width(44)
                  .height(44)
                  .textAlign(TextAlign.Center)
                  .borderRadius(22)
                  .backgroundColor(Theme.brand())

                Column({ space: 4 }) {
                  Text(c.name)
                    .fontSize(fs(15, this.fontScale))
                    .fontWeight(FontWeight.Medium)
                    .fontColor(Theme.textPrimary(this.isDark))
                  Text(c.lastMessage || '（新会话）')
                    .fontSize(fs(13, this.fontScale))
                    .fontColor(Theme.textSecondary(this.isDark))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                if (c.unreadCount > 0) {
                  Text(c.unreadCount.toString())
                    .fontSize(fs(11, this.fontScale))
                    .fontColor(Color.White)
                    .backgroundColor(Theme.danger())
                    .borderRadius(10)
                    .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                }
              }
              .width('100%')
              .padding(Spacing.lg)
              .backgroundColor(Theme.bgCard(this.isDark))
              .borderRadius(Radius.lg)
              .onClick(() => {
                this.getUIContext().getPromptAction().showToast({ message: '私信会话需接入聊天接口' });
              })
            }
          }, (c: Conversation) => c.userId)
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: Spacing.lg, right: Spacing.lg, top: 0 })
        .scrollBar(BarState.Off)
        .clip(false)
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        .overlay(this.BottomFadeOverlay())
        .blendMode(BlendMode.SRC_OVER, BlendApplyType.OFFSCREEN)
      }

      // 悬浮顶栏（内容可穿过）
      Row({ space: Spacing.sm }) {
        Button() {
          SymbolGlyph($r('sys.symbol.chevron_left')).fontColor([$r('sys.color.icon_primary')]).fontSize(fs(28, this.fontScale))
        }
        .width(44)
        .height(44)
        .backgroundColor(Color.Transparent)
        .shadow(Theme.glassShadowStyle()).backgroundEffect(ImmBlur.control())
        .systemMaterial(ImmMaterial.control())
        .borderRadius(Radius.full)
        .onClick(() => { this.getUIContext().getRouter().back(); })
        Text('私信')
          .fontSize(fs(18, this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.textPrimary(this.isDark))
      }
      .width('100%')
      .padding({ left: Spacing.lg, right: Spacing.lg, top: 44, bottom: 10 })
      .backgroundColor(Color.Transparent)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg(this.isDark))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  /** 顶部渐显覆盖比例（2026-09-13）：平板只覆盖顶部按钮与标题（98vp 折算），手机维持 15% */
  private topFadeStop(): number {
    if (!this.isWideFormDevice || this.fadeCoverVp <= 0) {
      return 0.15;
    }
    return Math.min(0.15, 98 / this.fadeCoverVp);
  }

  @Builder
  BottomFadeOverlay() {
    Stack()
      .height('100%')
      .width('100%')
      .linearGradient({
        direction: GradientDirection.Bottom,
        colors: [['#00FFFFFF', 0.0], ['#FFFFFFFF', this.topFadeStop()], ['#FFFFFFFF', 1.0]]
      })
      .blendMode(BlendMode.DST_IN, BlendApplyType.OFFSCREEN)
      .hitTestBehavior(HitTestMode.None)
  }
}
