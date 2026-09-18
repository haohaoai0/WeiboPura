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

import { LengthMetrics } from '@kit.ArkUI';
import { Theme, Spacing, Radius, isDarkMode, ImmBlur, ImmMaterial, MaterialManager, fs, tabletTopFadeStop, overlayCardWidth } from '../common/Theme';
import { ToastUtil, ToastType } from '../common/ToastUtil';
import { Haptic } from '../common/Haptic';
import { TiebaService, BlacklistPermOptions } from '../service/TiebaService';
import { AuthManager } from '../service/AuthManager';
import { CacheManager } from '../cache/CacheManager';
import { CACHE_KEY, formatTime, BRAND_BLUE } from '../common/Constants';
import { BlacklistItem } from '../model/DataModel';
import { compareByName } from '../common/Pinyin';
import { EmptyView, ErrorView } from '../components/CommonComponents';
import { ListRowSkeleton } from '../components/Skeleton';

/** 黑名单排序模式（同收藏页 v1.11 范式，去「自定义排序」；默认 TimeDesc = 最新拉黑） */
enum BlackSortMode {
  NameAsc = 0,
  NameDesc = 1,
  TimeAsc = 2,
  TimeDesc = 3,
}

enum LoadState {
  Loading = 0,
  Ready = 1,
  Empty = 2,
  Error = 3,
}

/**
 * 黑名单管理页：UI 与 Settings.ets 设置页统一（卡片式设置项行 + 沉浸光感）。
 * - 右上角排序按钮（同收藏页 TopBar：44vp Text('⇅') 文本符号钮）+ 4 项排序菜单（无「自定义排序」）
 * - 编辑态多选圈选 + 底部删除栏（复用收藏页 EditBar 范式）
 * - 删除确认居中卡片浮层（复用收藏页 PinConfirmDialog 范式，危险操作红色）
 * - 分页 + 下拉刷新 + 空态/错误态 + 骨架屏
 */
@Entry
@Component
struct BlacklistManager {
  @State isDark: boolean = isDarkMode();
  @State list: BlacklistItem[] = [];
  @State loadState: LoadState = LoadState.Loading;
  @State errorMsg: string = '';
  @State refreshing: boolean = false;
  @State loadingMore: boolean = false;
  @State hasMore: boolean = true;
  @State page: number = 0;
  @State editMode: boolean = false;
  @State selectedIds: string[] = [];
  @State showSortMenu: boolean = false;
  @State sortMode: BlackSortMode = BlackSortMode.TimeDesc;
  @State showDeleteConfirm: boolean = false;
  @State deleteBusy: boolean = false;
  // 行点击编辑弹窗（对齐官方 App 黑名单管理：三开关 + 取消/移除黑名单/编辑完成）
  @State editTarget: BlacklistItem | null = null;
  @State editChat: boolean = true;
  @State editFollow: boolean = true;
  @State editInteract: boolean = true;
  @State permBusy: boolean = false;
  @StorageLink('fontScale') fontScale: number = 1.0;
  /** 页面可见时自增，强制组件重建使字号实时生效 */
  @State fontSizeTick: number = 0;

  onPageShow(): void {
    this.fontSizeTick++;
  }

  private readonly PAGE_SIZE: number = 20;
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    MaterialManager.init();
    this.isDark = isDarkMode();
    this.initSortPref();
    this.loadFirst();
  }

  private accountId(): string {
    return AuthManager.getInstance().getUser()?.userId ?? '';
  }

  private toast(message: string, type: ToastType = ToastType.Info): void {
    ToastUtil.show(this.getUIContext(), message, type);
  }

  // ===== 排序偏好持久化（blacklist_sort_{accountId}，重启保持）=====

  private async initSortPref(): Promise<void> {
    const accountId: string = this.accountId();
    if (accountId.length === 0) {
      return;
    }
    try {
      const raw = await CacheManager.getInstance().get(`${CACHE_KEY.BLACKLIST_SORT}_${accountId}`);
      if (raw) {
        const n: number = parseInt(raw, 10);
        if (n >= 0 && n <= 3) {
          this.sortMode = n as BlackSortMode;
        }
      }
    } catch (e) {
      // 读取失败用默认
    }
  }

  private saveSortMode(): void {
    const accountId: string = this.accountId();
    if (accountId.length === 0) {
      return;
    }
    CacheManager.getInstance().put(`${CACHE_KEY.BLACKLIST_SORT}_${accountId}`, String(this.sortMode)).catch(() => {
    });
  }

  // ===== 数据加载（分页 + 下拉刷新，同步贴吧云端）=====

  private async loadFirst(): Promise<void> {
    if (this.refreshing) {
      return;
    }
    this.loadState = LoadState.Loading;
    this.page = 0;
    this.hasMore = true;
    try {
      const result = await TiebaService.getInstance().fetchBlacklist(0, this.PAGE_SIZE);
      this.list = result.list;
      this.hasMore = result.hasMore;
      this.page = 0;
      this.loadState = this.list.length > 0 ? LoadState.Ready : LoadState.Empty;
    } catch (e) {
      this.errorMsg = (e as Error).message ?? '加载失败，请稍后重试';
      this.loadState = LoadState.Error;
    }
  }

  private async onRefresh(): Promise<void> {
    try {
      const result = await TiebaService.getInstance().fetchBlacklist(0, this.PAGE_SIZE);
      this.list = result.list;
      this.hasMore = result.hasMore;
      this.page = 0;
      this.loadState = this.list.length > 0 ? LoadState.Ready : LoadState.Empty;
      this.toast('刷新成功', ToastType.Success);
    } catch (e) {
      this.toast('刷新失败，请稍后重试', ToastType.Error);
    } finally {
      this.refreshing = false;
    }
  }

  private async loadMore(): Promise<void> {
    if (this.loadingMore || !this.hasMore || this.loadState !== LoadState.Ready) {
      return;
    }
    this.loadingMore = true;
    try {
      const next: number = this.page + 1;
      const result = await TiebaService.getInstance().fetchBlacklist(next, this.PAGE_SIZE);
      this.list = [...this.list, ...result.list];
      this.hasMore = result.hasMore;
      this.page = next;
    } catch (e) {
      this.toast('更多黑名单加载失败，请稍后重试', ToastType.Error);
    } finally {
      this.loadingMore = false;
    }
  }

  // ===== 排序（同收藏页 v1.11：本地已加载数据重排，不触发网络）=====

  private sortedList(): BlacklistItem[] {
    const list: BlacklistItem[] = this.list.slice();
    list.sort((a: BlacklistItem, b: BlacklistItem): number => {
      if (this.sortMode === BlackSortMode.NameAsc || this.sortMode === BlackSortMode.NameDesc) {
        const desc: boolean = this.sortMode === BlackSortMode.NameDesc;
        return compareByName(a.name || a.userId, b.name || b.userId, desc);
      }
      const ta: number = a.blackTime;
      const tb: number = b.blackTime;
      if (ta === tb) {
        return 0;
      }
      if (ta === 0) {
        return 1;
      }
      if (tb === 0) {
        return -1;
      }
      return this.sortMode === BlackSortMode.TimeAsc ? ta - tb : tb - ta;
    });
    return list;
  }

  private openSortMenu(): void {
    this.showSortMenu = true;
  }

  private sortModeLabel(mode: BlackSortMode): string {
    switch (mode) {
      case BlackSortMode.NameAsc:
        return '名称正序';
      case BlackSortMode.NameDesc:
        return '名称倒序';
      case BlackSortMode.TimeAsc:
        return '最早拉黑';
      default:
        return '最新拉黑';
    }
  }

  private applySortMode(mode: BlackSortMode): void {
    if (this.sortMode === mode) {
      this.showSortMenu = false;
      return;
    }
    this.sortMode = mode;
    this.saveSortMode();
    this.showSortMenu = false;
    Haptic.light();
    this.toast(`已切换为${this.sortModeLabel(mode)}`, ToastType.Success);
  }

  // ===== 编辑态（圈选 + 批量解除拉黑）=====

  private enterEditMode(): void {
    this.editMode = true;
    this.selectedIds = [];
  }

  private exitEditMode(): void {
    this.editMode = false;
    this.selectedIds = [];
  }

  private isSelected(userId: string): boolean {
    return this.selectedIds.indexOf(userId) >= 0;
  }

  private toggleSelect(userId: string): void {
    const idx: number = this.selectedIds.indexOf(userId);
    if (idx >= 0) {
      this.selectedIds = this.selectedIds.filter((id: string): boolean => id !== userId);
    } else {
      this.selectedIds = [...this.selectedIds, userId];
    }
    Haptic.light();
  }

  private allSelected(): boolean {
    return this.list.length > 0 && this.list.every((it: BlacklistItem): boolean => this.isSelected(it.userId));
  }

  private toggleSelectAll(): void {
    const ids: string[] = this.list.map((it: BlacklistItem): string => it.userId);
    this.selectedIds = this.allSelected() ? [] : ids;
    Haptic.light();
  }

  private requestDeleteSelected(): void {
    if (this.selectedIds.length === 0) {
      this.toast('请先选择要解除拉黑的用户');
      return;
    }
    this.showDeleteConfirm = true;
  }

  private closeDeleteConfirm(): void {
    this.showDeleteConfirm = false;
  }

  /** 逐个调云端取消拉黑，成功项本地移除（失败项保留）；同收藏页删除的乐观更新 + 失败回滚策略 */
  private async confirmDeleteSelected(): Promise<void> {
    if (this.deleteBusy) {
      return;
    }
    const ids: string[] = [...this.selectedIds];
    this.deleteBusy = true;
    let okCount: number = 0;
    let failCount: number = 0;
    const okSet: Set<string> = new Set<string>();
    for (const id of ids) {
      try {
        await TiebaService.getInstance().unblockUser(id);
        okSet.add(id);
        okCount++;
      } catch (e) {
        failCount++;
      }
    }
    this.list = this.list.filter((it: BlacklistItem): boolean => !okSet.has(it.userId));
    this.selectedIds = this.selectedIds.filter((id: string): boolean => !okSet.has(id));
    this.showDeleteConfirm = false;
    this.deleteBusy = false;
    Haptic.strong();
    if (this.list.length === 0) {
      this.loadState = LoadState.Empty;
    }
    if (failCount === 0) {
      this.toast(`已解除拉黑 ${okCount} 位用户`, ToastType.Success);
      this.exitEditMode();
    } else if (okCount > 0) {
      this.toast(`${okCount} 位解除成功，${failCount} 位失败`, ToastType.Error);
    } else {
      this.toast('解除拉黑失败，请稍后重试', ToastType.Error);
    }
  }

  // ===== 行点击编辑弹窗（对齐官方：三开关 + 取消/移除黑名单/编辑完成）=====

  private permCacheKey(userId: string): string {
    return `${CACHE_KEY.BLACKLIST_PERM}_${userId}`;
  }

  private savePermToCache(userId: string, follow: boolean, interact: boolean, chat: boolean): void {
    CacheManager.getInstance().put(this.permCacheKey(userId), JSON.stringify({ follow, interact, chat })).catch(() => {
    });
  }

  private clearPermCache(userId: string): void {
    CacheManager.getInstance().delete(this.permCacheKey(userId)).catch(() => {
    });
  }

  /** 打开编辑弹窗：优先列表接口回显 perm；查询接口无 perm 时读本地记忆，无记录默认全开 */
  private async openPermDialog(item: BlacklistItem): Promise<void> {
    let follow: boolean = item.blockFollow ?? true;
    let interact: boolean = item.blockInteract ?? true;
    let chat: boolean = item.blockChat ?? true;
    if (item.blockFollow === undefined || item.blockInteract === undefined || item.blockChat === undefined) {
      try {
        const raw = await CacheManager.getInstance().get(this.permCacheKey(item.userId));
        if (raw) {
          const saved: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
          if (saved.follow !== undefined) {
            follow = `${saved.follow}` === 'true';
          }
          if (saved.interact !== undefined) {
            interact = `${saved.interact}` === 'true';
          }
          if (saved.chat !== undefined) {
            chat = `${saved.chat}` === 'true';
          }
        }
      } catch (e) {
        // 缓存解析失败走默认全开
      }
    }
    this.editFollow = follow;
    this.editInteract = interact;
    this.editChat = chat;
    this.editTarget = item;
    Haptic.light();
  }

  /** 右侧按钮条件：任一开关开着 → 编辑完成；全关 → 移除黑名单 */
  private anyPermOn(): boolean {
    return this.editChat || this.editFollow || this.editInteract;
  }

  private async confirmPermDialog(): Promise<void> {
    if (this.permBusy || this.editTarget === null) {
      return;
    }
    const target: BlacklistItem = this.editTarget;
    this.permBusy = true;
    try {
      if (this.anyPermOn()) {
        // 编辑完成：按当前开关组合更新屏蔽设置（服务端已实测支持任意组合）
        const perm: BlacklistPermOptions = {
          follow: this.editFollow,
          interact: this.editInteract,
          chat: this.editChat,
        };
        await TiebaService.getInstance().blockUser(target.userId, target.name, perm);
        this.savePermToCache(target.userId, this.editFollow, this.editInteract, this.editChat);
        this.list = this.list.map((it: BlacklistItem): BlacklistItem => {
          if (it.userId === target.userId) {
            return {
              userId: it.userId,
              name: it.name,
              avatar: it.avatar,
              blackTime: it.blackTime,
              blockFollow: this.editFollow,
              blockInteract: this.editInteract,
              blockChat: this.editChat,
            };
          }
          return it;
        });
        Haptic.light();
        this.toast('已更新黑名单设置', ToastType.Success);
      } else {
        // 全关 = 移除黑名单（unblockUser = perm 三开关全关）
        await TiebaService.getInstance().unblockUser(target.userId);
        this.list = this.list.filter((it: BlacklistItem): boolean => it.userId !== target.userId);
        this.clearPermCache(target.userId);
        if (this.list.length === 0) {
          this.loadState = LoadState.Empty;
        }
        Haptic.strong();
        this.toast('已移除黑名单', ToastType.Success);
      }
      this.editTarget = null;
    } catch (e) {
      this.toast((e as Error).message ?? '操作失败，请稍后重试', ToastType.Error);
    } finally {
      this.permBusy = false;
    }
  }

  private subLineOf(item: BlacklistItem): string {
    const idPart: string = item.userId.length > 0 ? `ID ${item.userId}` : '';
    // 黑名单接口返回的 blackTime 实际是「解禁时间戳（秒）」：>0 显示「解禁于 XXX」，=0 显示「永久屏蔽」。
    const timePart: string = item.blackTime > 0
      ? `解禁于 ${formatTime(item.blackTime)}`
      : '永久屏蔽';
    if (idPart.length > 0 && timePart.length > 0) {
      return `${idPart} · ${timePart}`;
    }
    return idPart.length > 0 ? idPart : timePart;
  }

  build() {
    Stack() {
      Column() {
        // 内容层（TopBar 已悬浮于 Stack 层）
        if (this.loadState === LoadState.Loading) {
          Column() {
            ListRowSkeleton({ count: 6 })
              .width('100%')
              .layoutWeight(1)
          }
          .width('100%')
          .layoutWeight(1)
        } else if (this.loadState === LoadState.Error) {
          ErrorView({ message: this.errorMsg, onRetry: () => { this.loadFirst(); } }).layoutWeight(1)
        } else if (this.loadState === LoadState.Empty) {
          EmptyView({ message: '黑名单还是空的\n在用户主页点击拉黑即可添加', icon: '🛡️' }).layoutWeight(1)
        } else {
          Refresh({ refreshing: this.refreshing, offset: 48, friction: 62 }) {
            List({ space: Spacing.sm, scroller: this.scroller }) {
              // 预留顶栏高度的初始间距（同「我的」页 ListItem spacer 范式）
              ListItem() {
                Column()
                  .width('100%')
                  .height(90)
              }
              .backgroundColor(Color.Transparent)

              ForEach(this.sortedList(), (item: BlacklistItem) => {
                ListItem() {
                  this.BlackItemRow(item)
                }
              }, (item: BlacklistItem) => item.userId)
            }
            .width('100%')
            .padding({ left: Spacing.lg, right: Spacing.lg, bottom: Spacing.xl })
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.Spring)
            .onReachEnd(() => { this.loadMore(); })
            .overlay(this.BottomFadeOverlay())
            .blendMode(BlendMode.SRC_OVER, BlendApplyType.OFFSCREEN)
          }
          .width('100%')
          .layoutWeight(1)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.bg(this.isDark))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      // 悬浮沉浸顶栏（透明底，内容可穿过；参数同 Settings.ets）
      this.TopBar()

      if (this.editMode) {
        this.EditBar()
      }
      /**
       * 排序菜单锚点（§6.9：自绘下拉浮层 → 系统 bindMenu）。
       * 原自绘面板是 `position({ top: 100, right: 16 })`；这里用 1×1 隐形锚点 + `Placement.BottomRight`
       * 把菜单右下角精确落回同一坐标（排序钮右侧还有别的钮，直接挂按钮会让菜单整体左移）。
       * 锚点不参与视觉与交互：1×1 + 全透明 + hitTestBehavior(None)，弹出仍由 TopBar 排序钮发起。
       */
      Row()
        .width(1)
        .height(1)
        .position({ top: 99, right: 16 })
        .hitTestBehavior(HitTestMode.None)
        .bindMenu(this.showSortMenu, this.SortMenuContent(), {
          placement: Placement.BottomRight,
          targetSpace: LengthMetrics.vp(0),
          systemMaterial: ImmMaterial.menu(),
          onDisappear: () => { this.showSortMenu = false; }
        })
      if (this.editTarget !== null) {
        this.PermDialog()
      }
      if (this.showDeleteConfirm) {
        this.DeleteConfirmDialog()
      }
    }
    .width('100%')
    .height('100%')
  }

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
      .backgroundColor(Color.Transparent)
      .shadow(Theme.glassShadowStyle()).backgroundEffect(ImmBlur.control())
      .systemMaterial(ImmMaterial.control())
      .borderRadius(Radius.full)
      .accessibilityText(this.editMode ? '退出编辑' : '返回')
      .onClick(() => {
        if (this.editMode) {
          this.exitEditMode();
        } else {
          this.getUIContext().getRouter().back();
        }
      })

      Text(this.editMode ? `已选 ${this.selectedIds.length} 项` : '黑名单')
        .fontSize(fs(18, this.fontScale))
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.textPrimary(this.isDark))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      if (this.editMode) {
        Button() {
          Text(this.allSelected() ? '取消全选' : '全选')
            .fontSize(fs(14, this.fontScale))
            .fontColor($r('sys.color.font_primary'))
        }
        .height(40)
        .padding({ left: 14, right: 14 })
        .backgroundColor(Theme.manualGlass(this.isDark))
        .border({ width: 0.5, color: Theme.manualGlassBorder() })
        .shadow(Theme.glassShadowStyle()).backgroundEffect(ImmBlur.control())
        .systemMaterial(ImmMaterial.control())
        .borderRadius(Radius.full)
        .accessibilityText('全选切换')
        .onClick(() => { this.toggleSelectAll(); })
      } else {
        // 排序按钮（同收藏页 TopBar：44vp Text('⇅') 文本符号钮 + manualGlass + ImmMaterial.control()）
        Row() {
          Text('⇅')
            .fontSize(fs(20, this.fontScale))
            .fontColor(Theme.textPrimary(this.isDark))
        }
        .width(44)
        .height(44)
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .backgroundColor(Theme.manualGlass(this.isDark))
        .border({ width: 0.5, color: Theme.manualGlassBorder() })
        .shadow(Theme.glassShadowStyle()).backgroundEffect(ImmBlur.control())
        .systemMaterial(ImmMaterial.control())
        .borderRadius(Radius.full)
        .margin({ left: Spacing.sm })
        .accessibilityText('排序')
        .accessibilityDescription(this.sortModeLabel(this.sortMode))
        .onClick(() => { this.openSortMenu(); })

        if (this.list.length > 0) {
          Button() {
            Text('编辑')
              .fontSize(fs(14, this.fontScale))
              .fontColor($r('sys.color.font_primary'))
          }
          .height(40)
          .padding({ left: 14, right: 14 })
          .backgroundColor(Theme.manualGlass(this.isDark))
          .border({ width: 0.5, color: Theme.manualGlassBorder() })
          .shadow(Theme.glassShadowStyle()).backgroundEffect(ImmBlur.control())
          .systemMaterial(ImmMaterial.control())
          .borderRadius(Radius.full)
          .margin({ left: Spacing.sm })
          .accessibilityText('编辑')
          .onClick(() => { this.enterEditMode(); })
        }
      }
    }
    .width('100%')
    .padding({ left: Spacing.lg, right: Spacing.lg, top: 44, bottom: 10 })
    .align(Alignment.TopStart)
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

  /** 列表行：设置页 SettingItem 同款卡片（头像 40vp 圆角 / 昵称 + ID·拉黑时间 / 右箭头），编辑态圈选 */
  @Builder
  BlackItemRow(item: BlacklistItem) {
    Row({ space: Spacing.md }) {
      if (this.editMode) {
        Stack() {
          if (this.isSelected(item.userId)) {
            Text('✓')
              .fontSize(fs(12, this.fontScale))
              .fontColor(Color.White)
              .textAlign(TextAlign.Center)
          }
        }
        .width(22)
        .height(22)
        .borderRadius(11)
        .backgroundColor(this.isSelected(item.userId) ? Theme.brand() : Color.Transparent)
        .border({ width: 2, color: this.isSelected(item.userId) ? Color.Transparent : Theme.textTertiary(this.isDark) })
      }

      // 头像
      if (item.avatar.length > 0) {
        Image(item.avatar)
          .width(40)
          .height(40)
          .borderRadius(20)
          .objectFit(ImageFit.Cover)
          .clip(true)
      } else {
        Stack() {
          Text(item.name.length > 0 ? item.name.charAt(0) : '?')
            .fontSize(fs(17, this.fontScale))
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.brand())
        }
        .width(40)
        .height(40)
        .borderRadius(20)
        .backgroundColor(Theme.brandBg(this.isDark))
        .alignContent(Alignment.Center)
      }

      Column({ space: 2 }) {
        Text(item.name || item.userId || '未知用户')
          .fontSize(fs(16, this.fontScale))
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textPrimary(this.isDark))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.subLineOf(item))
          .fontSize(fs(13, this.fontScale))
          .fontColor(Theme.textSecondary(this.isDark))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
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
    .accessibilityText(item.name || item.userId || '未知用户')
    .accessibilityDescription(this.editMode ? '点击切换勾选' : '点击编辑屏蔽设置')
    .onClick(() => {
      if (this.editMode) {
        this.toggleSelect(item.userId);
      } else {
        this.openPermDialog(item);
      }
    })
  }

  /** 编辑态底部操作栏（复用收藏页 EditBar 范式：全选 + 危险红删除） */
  @Builder
  EditBar() {
    Column() {
      Row() {
        Button() {
          Text(this.allSelected() ? '取消全选' : '全选')
            .fontSize(fs(15, this.fontScale))
            .fontColor($r('sys.color.font_primary'))
        }
        .height(44)
        .padding({ left: 16, right: 16 })
        .backgroundColor(Theme.manualGlass(this.isDark))
        .border({ width: 0.5, color: Theme.manualGlassBorder() })
        .shadow(Theme.glassShadowStyle()).backgroundEffect(ImmBlur.control())
        .systemMaterial(ImmMaterial.control())
        .borderRadius(Radius.full)
        .accessibilityText('全选切换')
        .onClick(() => { this.toggleSelectAll(); })

        Blank()

        Button() {
          Text(`解除拉黑 (${this.selectedIds.length})`)
            .fontSize(fs(15, this.fontScale))
            .fontColor(Color.White)
        }
        .height(44)
        .padding({ left: 20, right: 20 })
        .backgroundColor(Theme.danger())
        .borderRadius(Radius.full)
        .accessibilityText('批量解除拉黑')
        .onClick(() => { this.requestDeleteSelected(); })
      }
      .width('100%')
      .padding({ left: Spacing.lg, right: Spacing.lg, top: 10, bottom: 20 })
      .backgroundColor(Theme.bottomGlass(this.isDark))
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.End)
    .hitTestBehavior(HitTestMode.Transparent)
    .zIndex(15)
    .transition(
      TransitionEffect.OPACITY
        .combine(TransitionEffect.move(TransitionEdge.BOTTOM))
        .animation({ duration: 220, curve: Curve.EaseOut })
    )
  }

  /**
   * 排序菜单内容（系统 `bindMenu` 的 CustomBuilder，4 项、无「自定义排序」）。
   * 原自绘浮层的外壳（全屏遮罩 / `position` / 不透明底 / 弹出动画）已全部交给 `bindMenu`：
   * 定位 → 隐形锚点 + `Placement.BottomRight`；背景 / 圆角 / 阴影 → `options.systemMaterial`。
   * 此处只保留菜单项本体（宽度 210、内边距、选中高亮 + ✓ 零改动）。
   */
  @Builder
  SortMenuContent() {
    Column({ space: 2 }) {
      this.SortMenuItem(BlackSortMode.NameAsc, '名称正序')
      this.SortMenuItem(BlackSortMode.NameDesc, '名称倒序')
      this.SortMenuItem(BlackSortMode.TimeAsc, '最早拉黑')
      this.SortMenuItem(BlackSortMode.TimeDesc, '最新拉黑')
    }
    .padding({ top: 6, bottom: 6 })
  }

  @Builder
  SortMenuItem(mode: BlackSortMode, label: string) {
    Row({ space: 10 }) {
      Text(label)
        .fontSize(fs(14, this.fontScale))
        .fontWeight(FontWeight.Medium)
        .fontColor(this.sortMode === mode ? Theme.brand() : Theme.textPrimary(this.isDark))
        .layoutWeight(1)
      if (this.sortMode === mode) {
        Text('✓')
          .fontSize(fs(13, this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.brand())
      }
    }
    .width(210)
    .padding({ left: 16, right: 16, top: 13, bottom: 13 })
    .borderRadius(Radius.md)
    .onClick(() => { this.applySortMode(mode); })
  }

  /** 行点击编辑弹窗：三开关 + 取消 / 移除黑名单(全关) / 编辑完成(有开)，对齐官方 App 黑名单管理 */
  @Builder
  PermDialog() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#06000000')
        .onClick(() => { if (!this.permBusy) { this.editTarget = null; } })
        .transition(TransitionEffect.opacity(0).animation({ duration: 180, curve: Curve.EaseOut }))

      Column() {
        Column({ space: 6 }) {
          Text(this.editTarget?.name ?? '')
            .fontSize(fs(17, this.fontScale))
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.textPrimary(this.isDark))
            .textAlign(TextAlign.Center)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text('黑名单屏蔽设置')
            .fontSize(fs(13, this.fontScale))
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.textSecondary(this.isDark))
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        .padding({ left: Spacing.lg, right: Spacing.lg, top: Spacing.lg, bottom: Spacing.md })

        Column({ space: 4 }) {
          this.PermSwitchRow('禁止私信', '开启后对方无法给你发私信', this.editChat, (on: boolean) => { this.editChat = on; })
          this.PermSwitchRow('禁止关注', '开启后对方无法关注你', this.editFollow, (on: boolean) => { this.editFollow = on; })
          this.PermSwitchRow('禁止互动', '开启后对方无法评论、点赞、转发、@你', this.editInteract, (on: boolean) => { this.editInteract = on; })
        }
        .width('100%')
        .padding({ left: Spacing.lg, right: Spacing.lg, top: Spacing.xs, bottom: Spacing.md })

        Row({ space: Spacing.md }) {
          Button() {
            Text('取消')
              .fontSize(fs(15, this.fontScale))
              .fontWeight(FontWeight.Medium)
              .fontColor(Theme.textPrimary(this.isDark))
          }
          .layoutWeight(1)
          .height(44)
          .backgroundColor(Theme.bgCard(this.isDark))
          .borderRadius(Radius.full)
          .accessibilityText('取消')
          .onClick(() => { this.editTarget = null; })

          Button() {
            Text(this.permBusy ? '处理中...' : (this.anyPermOn() ? '编辑完成' : '移除黑名单'))
              .fontSize(fs(15, this.fontScale))
              .fontColor(Color.White)
              .fontWeight(FontWeight.Medium)
          }
          .layoutWeight(1)
          .height(44)
          .backgroundColor(this.anyPermOn() ? Theme.brand() : Theme.danger())
          .borderRadius(Radius.full)
          .accessibilityText(this.anyPermOn() ? '保存屏蔽设置' : '解除拉黑')
          .onClick(() => { this.confirmPermDialog(); })
        }
        .width('100%')
        .padding({ left: Spacing.lg, right: Spacing.lg, bottom: Spacing.lg })
      }
      .width(overlayCardWidth())
      .margin({ bottom: 110 })
      .padding({ top: Spacing.md })
      .backgroundColor(Theme.sheetBg(this.isDark))
      .shadow(Theme.glassShadowStyle()).backgroundEffect(ImmBlur.control())
      .systemMaterial(ImmMaterial.control())
      .borderRadius(32)
      .border({ width: { top: 1.5 }, color: Theme.sheetTopGlow(this.isDark) })
      .shadow({ radius: 48, color: '#3D000000', offsetY: 18 })
      .transition(TransitionEffect.scale({ x: 0.92, y: 0.92 }).combine(TransitionEffect.translate({ y: 24 })).combine(TransitionEffect.opacity(0)).animation({ duration: 220, curve: Curve.EaseOut }))
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.Bottom)
    .zIndex(100)
    .transition(TransitionEffect.asymmetric(
      TransitionEffect.IDENTITY,
      TransitionEffect.opacity(0).animation({ duration: 200, curve: Curve.EaseInOut })
    ))
  }

  /** 屏蔽开关单行（同 UserProfile 拉黑弹窗样式） */
  @Builder
  PermSwitchRow(title: string, subtitle: string, isOn: boolean, onChange: (on: boolean) => void) {
    Row() {
      Column({ space: 2 }) {
        Text(title)
          .fontSize(fs(15, this.fontScale))
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textPrimary(this.isDark))
        Text(subtitle)
          .fontSize(fs(11, this.fontScale))
          .fontColor(Theme.textSecondary(this.isDark))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: isOn })
        .selectedColor(BRAND_BLUE)
        .onChange((on: boolean) => { onChange(on); })
    }
    .width('100%')
    .height(48)
    .padding({ left: Spacing.sm, right: Spacing.sm })
  }

  /** 解除拉黑确认：居中卡片浮层（复用收藏页 PinConfirmDialog 范式，危险操作红色分组） */
  @Builder
  DeleteConfirmDialog() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#06000000')
        .onClick(() => { this.closeDeleteConfirm(); })
        .transition(TransitionEffect.opacity(0).animation({ duration: 180, curve: Curve.EaseOut }))

      Column() {
        Column({ space: 6 }) {
          Text('解除拉黑')
            .fontSize(fs(17, this.fontScale))
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.textPrimary(this.isDark))
            .textAlign(TextAlign.Center)
          Text(`确定解除拉黑选中的 ${this.selectedIds.length} 位用户吗？`)
            .fontSize(fs(13, this.fontScale))
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.textSecondary(this.isDark))
            .lineHeight(fs(18, this.fontScale))
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        .padding({ left: Spacing.lg, right: Spacing.lg, top: Spacing.lg, bottom: Spacing.md })

        Row({ space: Spacing.md }) {
          Button() {
            Text('取消')
              .fontSize(fs(15, this.fontScale))
              .fontWeight(FontWeight.Medium)
              .fontColor(Theme.textPrimary(this.isDark))
          }
          .layoutWeight(1)
          .height(44)
          .backgroundColor(Theme.bgCard(this.isDark))
          .borderRadius(Radius.full)
          .accessibilityText('取消')
          .onClick(() => { this.closeDeleteConfirm(); })

          Button() {
            Text(this.deleteBusy ? '处理中...' : '解除拉黑')
              .fontSize(fs(15, this.fontScale))
              .fontColor(Color.White)
              .fontWeight(FontWeight.Medium)
          }
          .layoutWeight(1)
          .height(44)
          .backgroundColor(Theme.danger())
          .borderRadius(Radius.full)
          .accessibilityText('确认解除拉黑')
          .onClick(() => { this.confirmDeleteSelected(); })
        }
        .width('100%')
        .padding({ left: Spacing.lg, right: Spacing.lg, bottom: Spacing.lg })
      }
      .width(overlayCardWidth())
      .margin({ bottom: 110 })
      .padding({ top: Spacing.md })
      .backgroundColor(Theme.sheetBg(this.isDark))
      .shadow(Theme.glassShadowStyle()).backgroundEffect(ImmBlur.control())
      .systemMaterial(ImmMaterial.control())
      .borderRadius(32)
      .border({ width: { top: 1.5 }, color: Theme.sheetTopGlow(this.isDark) })
      .shadow({ radius: 48, color: '#3D000000', offsetY: 18 })
      .transition(TransitionEffect.scale({ x: 0.92, y: 0.92 }).combine(TransitionEffect.translate({ y: 24 })).combine(TransitionEffect.opacity(0)).animation({ duration: 220, curve: Curve.EaseOut }))
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.Bottom)
    .zIndex(100)
    .transition(TransitionEffect.asymmetric(
      TransitionEffect.IDENTITY,
      TransitionEffect.opacity(0).animation({ duration: 200, curve: Curve.EaseInOut })
    ))
  }
}
