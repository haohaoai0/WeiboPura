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

import { TiebaService } from '../service/TiebaService';
import { AuthManager } from '../service/AuthManager';
import { CacheManager } from '../cache/CacheManager';
import { CACHE_KEY, CACHE_TTL } from '../common/Constants';
import { FollowItem } from '../model/DataModel';
import { Theme, Spacing, Radius, isDarkMode, ImmBlur, ImmMaterial, MaterialManager, fs, tabletTopFadeStop } from '../common/Theme';
import { LoadingView, EmptyView, ErrorView } from '../components/CommonComponents';

enum LoadState {
  Loading, Success, Empty, Error,
}

@Entry
@Component
struct Follow {
  @State follows: FollowItem[] = [];
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
    if (!AuthManager.getInstance().isLogin()) {
      this.loadState = LoadState.Empty;
      return;
    }
    this.loadFollows();
  }

  private openForum(forum: FollowItem): void {
    if (forum.forumName.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: '贴吧信息暂不可用' });
      return;
    }
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/ThreadList',
      params: { kw: forum.forumName, fid: forum.forumId ?? '' }
    }).catch(() => {
      this.getUIContext().getPromptAction().showToast({ message: '贴吧打开失败，请稍后重试' });
    });
  }

  async loadFollows(): Promise<void> {
    this.loadState = LoadState.Loading;
    try {
      const cached = await CacheManager.getInstance().getWithTtl<FollowItem[]>(CACHE_KEY.FOLLOW_LIST);
      if (cached && cached.length > 0) {
        this.follows = cached;
        this.loadState = LoadState.Success;
      }
      const result = await TiebaService.getInstance().fetchFollowList(1);
      if (result.list.length > 0) {
        this.follows = result.list;
        this.loadState = LoadState.Success;
        await CacheManager.getInstance().putWithTtl(CACHE_KEY.FOLLOW_LIST, result.list, CACHE_TTL.FOLLOW_LIST);
      } else if (this.follows.length === 0) {
        this.loadState = LoadState.Empty;
      }
    } catch (e) {
      if (this.follows.length === 0) {
        this.loadState = LoadState.Error;
        this.errorMsg = (e as Error).message ?? '加载失败';
      }
    }
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (!AuthManager.getInstance().isLogin()) {
        EmptyView({
          message: '登录后查看关注的贴吧',
          icon: '⭐',
          actionText: '去登录',
          action: () => { this.getUIContext().getRouter().pushUrl({ url: 'pages/Login' }); },
        }).layoutWeight(1)
      } else if (this.loadState === LoadState.Loading) {
        LoadingView({ message: '加载关注列表...' }).layoutWeight(1)
      } else if (this.loadState === LoadState.Error) {
        ErrorView({ message: this.errorMsg, onRetry: () => { this.loadFollows(); } }).layoutWeight(1)
      } else if (this.loadState === LoadState.Empty) {
        EmptyView({ message: '还没有关注的贴吧', icon: '⭐' }).layoutWeight(1)
      } else {
        List({ space: Spacing.md }) {
          // 预留顶栏高度作为初始间距
          ListItem() {
            Column().width('100%').height(90)
          }
          ForEach(this.follows, (f: FollowItem) => {
            ListItem() {
              Row() {
                Column({ space: 4 }) {
                  Text(f.forumName + '吧')
                    .fontSize(fs(16, this.fontScale))
                    .fontWeight(FontWeight.Medium)
                    .fontColor(Theme.textPrimary(this.isDark))
                  if (f.level > 0) {
                    Text(`Lv.${f.level}`)
                      .fontSize(fs(11, this.fontScale))
                      .fontColor(Theme.textTertiary(this.isDark))
                  }
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                Button(f.isSign ? '已签到' : '签到')
                  .fontSize(fs(13, this.fontScale))
                  .fontColor(Color.White)
                  .backgroundColor(f.isSign ? Theme.textTertiary(this.isDark) : Theme.brand())
                  .borderRadius(Radius.full)
                  .height(32)
                  .onClick(() => {
                    this.getUIContext().getPromptAction().showToast({ message: '签到功能需接入签名接口' });
                  })
              }
              .width('100%')
              .padding(Spacing.lg)
              .backgroundColor(Theme.bgCard(this.isDark))
              .borderRadius(Radius.lg)
              .onClick(() => this.openForum(f))
            }
          }, (f: FollowItem) => f.forumName)
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
        Text('我的关注')
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
