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
import { TiebaService } from '../service/TiebaService';
import { AuthManager } from '../service/AuthManager';
import { CacheManager } from '../cache/CacheManager';
import { CACHE_KEY } from '../common/Constants';
import { FollowUserItem, FollowListResult } from '../model/DataModel';
import { compareByName } from '../common/Pinyin';
import { EmptyView, ErrorView } from '../components/CommonComponents';
import { ListRowSkeleton } from '../components/Skeleton';

/** 关注列表视图模式：全部关注 / 互相关注（粉丝接口 has_concerned=1 过滤的独立列表） */
enum FollowListMode {
  All = 0,
  Mutual = 1,
}

/** 关注列表排序模式（同收藏页 v1.11 范式，去「自定义排序」；默认 TimeDesc = 最新关注） */
enum FollowSortMode {
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

/** 关注列表预加载阈值：距底部剩余距离小于该值时提前静默加载下一页（List 内容高按行数估算，无内容总高接口） */
const FOLLOW_PREFETCH_DISTANCE: number = 1000;
/** 关注列表行高估算（40vp 头像 + 上下内边距，用于预加载剩余距离估算） */
const FOLLOW_ROW_H: number = 76;

/** 官方标题栏开关（§6.10 模板）：true 且设备支持材质时，顶栏整行（返回 / 排序 / 编辑 / 我的关注）搬进
 *  Navigation title 槽位吃官方材质；false 或低版本自动回退到页面主体悬浮自绘玻璃 TopBar（原样保留）。 */
const FOLLOW_OFFICIAL_TITLE_BAR: boolean = true;
/** 槽位高度 = 44(状态栏让位) + 44(按钮行高) + 10(底部呼吸)，与原悬浮 TopBar 的 padding 逐项一致；
 *  内容让位（List 首项占位 90 / 空态 padding-top 104）一行未改。 */
const FOLLOW_TITLE_BAR_HEIGHT: number = 98;

/**
 * 关注列表页：展示我关注的用户。
 * - 顶栏：渐变沉浸（DST_IN 渐变遮罩，同 ThreadDetail/ThreadList 范式）；右上角排序钮 + 一键切换钮（我的关注/互相关注）+ 编辑钮
 * - 排序菜单：4 项（名称正/倒序、时间正/倒序），无「自定义排序」（同收藏页范式）
 * - 切换：无弹窗，互相关注 = 粉丝接口（c/u/fans/page）has_concerned=1 过滤列表；进入默认全部关注
 * - 编辑态：多选圈选 + 底部批量取关栏（复用收藏页 EditBar 范式）+ 确认居中卡片（复用 PinConfirmDialog 范式）
 * - 关注/取关接口 v1.13 已修复为 portrait + tbs 传参
 */
@Entry
@Component
struct FollowList {
  @State isDark: boolean = isDarkMode();
  @State list: FollowUserItem[] = [];
  @State mutualList: FollowUserItem[] = []; // 互相关注列表（粉丝接口 has_concerned=1 过滤，切「互相关注」展示）
  @State total: number = 0;              // 关注总数（接口 total）
  @State loadState: LoadState = LoadState.Loading;
  @State errorMsg: string = '';
  @State refreshing: boolean = false;
  @State loadingMore: boolean = false;
  @State hasMore: boolean = true;
  @State page: number = 0;
  @State mode: FollowListMode = FollowListMode.All;
  @State editMode: boolean = false;
  @State selectedKeys: string[] = [];    // 按 portrait 唯一标识（userId 可能为空）
  @State showSortMenu: boolean = false;
  @State sortMode: FollowSortMode = FollowSortMode.TimeDesc;
  @State showDeleteConfirm: boolean = false;
  @State deleteBusy: boolean = false;
  @State unfollowTarget: FollowUserItem | null = null;  // 单行取关目标（弹确认）
  @StorageLink('fontScale') fontScale: number = 1.0;
  /** 页面可见时自增，强制组件重建使字号实时生效 */
  @State fontSizeTick: number = 0;
  /** API26+ 沉浸光感能力：true 时顶栏走官方 title 槽位，否则回退自绘玻璃 TopBar（与 ThreadDetail 同判据） */
  @State materialSupported: boolean = false;

  onPageShow(): void {
    this.fontSizeTick++;
  }

  private readonly PAGE_SIZE: number = 20;
  private scroller: Scroller = new Scroller();
  private lastY: number = 0;                    // 下拉刷新：触摸上一帧 Y
  private pullDistance: number = 0;             // 下拉刷新：累计下拉距离（vp）
  private readonly PULL_THRESHOLD: number = 80; // 触发刷新的下拉阈值
  // 关注列表预加载：视口高测量 + 节流/竞态（普通字段，避免高频回调触发 UI 重建）
  private viewportH: number = 0;
  private lastPrefetchY: number = -10000;
  private loadToken: number = 0;

  aboutToAppear(): void {
    MaterialManager.init();
    this.materialSupported = MaterialManager.isSupported() && MaterialManager.getApiLevel() >= 26;
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

  // ===== 排序偏好持久化（follow_list_sort_{accountId}，重启保持）=====

  private async initSortPref(): Promise<void> {
    const accountId: string = this.accountId();
    if (accountId.length === 0) {
      return;
    }
    try {
      const raw = await CacheManager.getInstance().get(`${CACHE_KEY.FOLLOW_LIST_SORT}_${accountId}`);
      if (raw) {
        const n: number = parseInt(raw, 10);
        if (n >= 0 && n <= 3) {
          this.sortMode = n as FollowSortMode;
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
    CacheManager.getInstance().put(`${CACHE_KEY.FOLLOW_LIST_SORT}_${accountId}`, String(this.sortMode)).catch(() => {
    });
  }

  // ===== 数据加载（分页 + 下拉刷新，同步贴吧云端）=====

  /** 拉取全部互相关注用户（粉丝接口分页循环，has_concerned=1 即互关；失败返回空数组不阻断主流程） */
  private async fetchMutualUsers(): Promise<FollowUserItem[]> {
    try {
      const all: FollowUserItem[] = [];
      let page = 0;
      let hasMore = true;
      while (hasMore && page < 10) {
        const result = await TiebaService.getInstance().fetchFollowUserFansList(page, 100);
        all.push(...result.list);
        hasMore = result.hasMore;
        page++;
      }
      return all;
    } catch (e) {
      return [];
    }
  }

  private async loadFirst(): Promise<void> {
    if (this.refreshing) {
      return;
    }
    // 请求代际递增：使 in-flight 的加载更多结果作废，避免 concat 到刷新后的新列表
    this.loadToken++;
    this.loadState = LoadState.Loading;
    this.page = 0;
    this.hasMore = true;
    try {
      // 并行发起关注列表 + 互关列表请求（ArkTS 不支持解构，先建 Promise 再分别 await）
      const followTask: Promise<FollowListResult> = TiebaService.getInstance().fetchFollowUserList(0, this.PAGE_SIZE);
      const mutualTask: Promise<FollowUserItem[]> = this.fetchMutualUsers();
      const result: FollowListResult = await followTask;
      const mutualItems: FollowUserItem[] = await mutualTask;
      this.list = result.list;
      this.mutualList = mutualItems;
      this.hasMore = result.hasMore;
      this.total = result.total > 0 ? result.total : result.list.length;
      this.page = 0;
      this.loadState = this.list.length > 0 ? LoadState.Ready : LoadState.Empty;
    } catch (e) {
      this.errorMsg = (e as Error).message ?? '加载失败，请稍后重试';
      this.loadState = LoadState.Error;
    }
  }

  private async onRefresh(): Promise<void> {
    // 请求代际递增：刷新后丢弃 in-flight 的加载更多结果
    this.loadToken++;
    try {
      const result = await TiebaService.getInstance().fetchFollowUserList(0, this.PAGE_SIZE);
      this.list = result.list;
      this.hasMore = result.hasMore;
      this.total = result.total > 0 ? result.total : result.list.length;
      this.page = 0;
      this.loadState = this.list.length > 0 ? LoadState.Ready : LoadState.Empty;
      this.mutualList = await this.fetchMutualUsers();
      this.toast('刷新成功', ToastType.Success);
    } catch (e) {
      this.toast('刷新失败，请稍后重试', ToastType.Error);
    } finally {
      this.refreshing = false;
    }
  }

  private async loadMore(silent: boolean = false): Promise<void> {
    if (this.loadingMore || !this.hasMore || this.loadState !== LoadState.Ready) {
      return;
    }
    this.loadingMore = true;
    // 记录当前代际：返回时若已刷新则丢弃结果
    const myToken: number = this.loadToken;
    try {
      const next: number = this.page + 1;
      const result = await TiebaService.getInstance().fetchFollowUserList(next, this.PAGE_SIZE);
      if (myToken !== this.loadToken) {
        return;
      }
      this.list = [...this.list, ...result.list];
      this.hasMore = result.hasMore;
      if (result.total > 0) {
        this.total = result.total;
      }
      this.page = next;
    } catch (e) {
      // 预加载失败静默忽略，靠 onReachEnd 兜底重试；仅用户主动触底时提示
      if (!silent) {
        this.toast('更多关注加载失败，请稍后重试', ToastType.Error);
      }
    } finally {
      this.loadingMore = false;
    }
  }

  /**
   * 关注列表预加载：按行数估算内容高，滚动剩余距离 < 阈值时提前静默加载下一页。
   * 编辑态不预加载；loadingMore 锁 + 偏移节流防重；onReachEnd 保留作兜底。
   */
  private onFollowListScroll(_x: number, y: number): void {
    if (this.editMode || this.loadState !== LoadState.Ready || this.loadingMore || !this.hasMore) {
      return;
    }
    // 内容高估算：顶栏占位(90) + 行数×行高 + 底部 padding(Spacing.xl≈24)
    const contentH: number = 90 + this.displayedList().length * FOLLOW_ROW_H + 24;
    const remaining: number = contentH - this.viewportH - y;
    if (remaining > FOLLOW_PREFETCH_DISTANCE) {
      return;
    }
    // 节流：偏移变化超过 120vp 才允许再次触发，避免同一轮滚动连续请求
    if (Math.abs(y - this.lastPrefetchY) < 120) {
      return;
    }
    this.lastPrefetchY = y;
    this.loadMore(true);
  }

  /** 视口尺寸变化：记录视口高 */
  private onViewportAreaChange(_old: Area, n: Area): void {
    this.viewportH = n.height as number;
  }

  // ===== 视图过滤 + 排序（本地，不触发网络）=====

  private displayedList(): FollowUserItem[] {
    let base: FollowUserItem[] = this.list;
    if (this.mode === FollowListMode.Mutual) {
      base = this.mutualList;
    }
    const list: FollowUserItem[] = base.slice();
    list.sort((a: FollowUserItem, b: FollowUserItem): number => {
      if (this.sortMode === FollowSortMode.NameAsc || this.sortMode === FollowSortMode.NameDesc) {
        const desc: boolean = this.sortMode === FollowSortMode.NameDesc;
        return compareByName(a.name || a.userId, b.name || b.userId, desc);
      }
      const ta: number = a.followTime;
      const tb: number = b.followTime;
      if (ta === tb) {
        return 0;
      }
      if (ta === 0) {
        return 1;
      }
      if (tb === 0) {
        return -1;
      }
      return this.sortMode === FollowSortMode.TimeAsc ? ta - tb : tb - ta;
    });
    return list;
  }

  // ===== 一键切换（无弹窗，本地过滤）=====

  private switchMode(): void {
    this.mode = this.mode === FollowListMode.All ? FollowListMode.Mutual : FollowListMode.All;
    Haptic.light();
  }

  // ===== 排序（同收藏页 v1.11：本地已加载数据重排）=====

  private openSortMenu(): void {
    this.showSortMenu = true;
  }

  private sortModeLabel(mode: FollowSortMode): string {
    switch (mode) {
      case FollowSortMode.NameAsc:
        return '名称正序';
      case FollowSortMode.NameDesc:
        return '名称倒序';
      case FollowSortMode.TimeAsc:
        return '最早关注';
      default:
        return '最新关注';
    }
  }

  private applySortMode(mode: FollowSortMode): void {
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

  // ===== 编辑态（圈选 + 批量取关）=====

  private enterEditMode(): void {
    this.editMode = true;
    this.selectedKeys = [];
  }

  private exitEditMode(): void {
    this.editMode = false;
    this.selectedKeys = [];
  }

  private keyOf(item: FollowUserItem): string {
    return item.portrait.length > 0 ? item.portrait : `u_${item.userId}`;
  }

  private isSelected(item: FollowUserItem): boolean {
    return this.selectedKeys.indexOf(this.keyOf(item)) >= 0;
  }

  private toggleSelect(item: FollowUserItem): void {
    const key: string = this.keyOf(item);
    const idx: number = this.selectedKeys.indexOf(key);
    if (idx >= 0) {
      this.selectedKeys = this.selectedKeys.filter((k: string): boolean => k !== key);
    } else {
      this.selectedKeys = [...this.selectedKeys, key];
    }
    Haptic.light();
  }

  private allSelected(): boolean {
    const shown: FollowUserItem[] = this.displayedList();
    return shown.length > 0 && shown.every((it: FollowUserItem): boolean => this.isSelected(it));
  }

  private toggleSelectAll(): void {
    const shown: FollowUserItem[] = this.displayedList();
    const keys: string[] = shown.map((it: FollowUserItem): string => this.keyOf(it));
    this.selectedKeys = this.allSelected() ? [] : keys;
    Haptic.light();
  }

  private selectedItems(): FollowUserItem[] {
    return this.displayedList().filter((it: FollowUserItem): boolean => this.isSelected(it));
  }

  private requestDeleteSelected(): void {
    if (this.selectedKeys.length === 0) {
      this.toast('请先选择要取消关注的用户');
      return;
    }
    this.showDeleteConfirm = true;
  }

  private closeDeleteConfirm(): void {
    this.showDeleteConfirm = false;
    this.unfollowTarget = null;
  }

  /** 批量取关：逐个调云端接口（portrait + tbs），成功项本地移除（失败项保留） */
  private async confirmDeleteSelected(): Promise<void> {
    if (this.deleteBusy) {
      return;
    }
    const targets: FollowUserItem[] = this.selectedItems();
    if (targets.length === 0) {
      this.closeDeleteConfirm();
      return;
    }
    this.deleteBusy = true;
    let okCount: number = 0;
    let failCount: number = 0;
    const okSet: Set<string> = new Set<string>();
    for (const item of targets) {
      try {
        await TiebaService.getInstance().unfollowUser(item.portrait);
        okSet.add(this.keyOf(item));
        okCount++;
      } catch (e) {
        failCount++;
      }
    }
    this.list = this.list.filter((it: FollowUserItem): boolean => !okSet.has(this.keyOf(it)));
    this.mutualList = this.mutualList.filter((it: FollowUserItem): boolean => !okSet.has(this.keyOf(it)));
    this.selectedKeys = this.selectedKeys.filter((k: string): boolean => !okSet.has(k));
    this.showDeleteConfirm = false;
    this.deleteBusy = false;
    Haptic.strong();
    if (this.total > 0 && okCount > 0) {
      this.total = this.total - okCount > 0 ? this.total - okCount : 0;
    }
    if (this.list.length === 0) {
      this.loadState = LoadState.Empty;
    }
    if (failCount === 0) {
      this.toast(`已取消关注 ${okCount} 位用户`, ToastType.Success);
      this.exitEditMode();
    } else if (okCount > 0) {
      this.toast(`${okCount} 位取消成功，${failCount} 位失败`, ToastType.Error);
    } else {
      this.toast('取关失败，请稍后重试', ToastType.Error);
    }
  }

  /** 单行取关：右侧「已关注」点击 → 弹确认 → 云端取关 + 本地移除 */
  private requestUnfollowOne(item: FollowUserItem): void {
    this.unfollowTarget = item;
    this.showDeleteConfirm = true;
  }

  private async confirmUnfollowOne(): Promise<void> {
    if (this.deleteBusy || !this.unfollowTarget) {
      return;
    }
    const target: FollowUserItem = this.unfollowTarget;
    this.deleteBusy = true;
    try {
      await TiebaService.getInstance().unfollowUser(target.portrait);
      this.list = this.list.filter((it: FollowUserItem): boolean => this.keyOf(it) !== this.keyOf(target));
      this.mutualList = this.mutualList.filter((it: FollowUserItem): boolean => this.keyOf(it) !== this.keyOf(target));
      if (this.total > 0) {
        this.total = this.total - 1 > 0 ? this.total - 1 : 0;
      }
      this.closeDeleteConfirm();
      this.deleteBusy = false;
      Haptic.strong();
      this.toast('已取消关注', ToastType.Success);
      if (this.list.length === 0) {
        this.loadState = LoadState.Empty;
      }
    } catch (e) {
      this.deleteBusy = false;
      this.toast('取关失败，请稍后重试', ToastType.Error);
    }
  }

  private subLineOf(item: FollowUserItem): string {
    const fromPart: string = '来自贴吧关注';
    if (item.intro.length > 0) {
      return `${fromPart} · ${item.intro}`;
    }
    return fromPart;
  }

  private openUser(item: FollowUserItem): void {
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/UserProfile',
      params: { userId: item.userId, userName: item.name }
    }).catch(() => {
    });
  }

  /** 页面内容层（原 build() 根 Stack，槽位 / 兜底两条路径共用） */
  @Builder
  FollowContent() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.loadState === LoadState.Ready) {
        if (this.mode === FollowListMode.Mutual && this.mutualList.length === 0) {
          Column() {
            EmptyView({ message: '暂无互相关注的用户', icon: '👥' }).layoutWeight(1)
          }
          .width('100%')
          .height('100%')
          .padding({ top: 104 })
          .backgroundColor(Theme.bg(this.isDark))
        } else {
        List({ space: Spacing.sm, scroller: this.scroller }) {
          // 预留顶栏高度作为初始间距（同 Index「我的」界面参数：占位 ListItem，而非 padding 留白）
          ListItem() {
            Column()
              .width('100%')
              .height(90)
          }
          .backgroundColor(Color.Transparent)

          if (this.refreshing) {
            ListItem() {
              this.RefreshIndicator()
            }
          }
          ForEach(this.displayedList(), (item: FollowUserItem) => {
            ListItem() {
              this.FollowItemRow(item)
            }
          }, (item: FollowUserItem) => `f_${this.keyOf(item)}`)

          // 预加载/触底加载进行中的占位尾项：触底时也有"正在加载"反馈，避免空等停顿感
          if (this.loadingMore && this.hasMore) {
            ListItem() {
              Row({ space: 8 }) {
                LoadingProgress()
                  .width(20)
                  .height(20)
                  .color(Theme.textSecondary(this.isDark))
                Text('正在加载…')
                  .fontSize(13)
                  .fontColor(Theme.textSecondary(this.isDark))
              }
              .width('100%')
              .height(56)
              .justifyContent(FlexAlign.Center)
            }
          }
        }
        .width('100%')
        .padding({ left: 0, right: 0, bottom: Spacing.xl })
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .clip(false)
        .onAreaChange((oldValue: Area, newValue: Area) => this.onViewportAreaChange(oldValue, newValue))
        .onScroll((xOffset: number, yOffset: number) => this.onFollowListScroll(xOffset, yOffset))
        .onReachEnd(() => { this.loadMore(); })
        .onTouch((event: TouchEvent) => {
          if (event.type === TouchType.Down) {
            this.lastY = event.touches[0].y;
          } else if (event.type === TouchType.Move) {
            if (this.scroller.currentOffset().yOffset <= 0 && !this.refreshing) {
              const delta = event.touches[0].y - this.lastY;
              this.pullDistance = Math.max(0, Math.min(this.pullDistance + delta, this.PULL_THRESHOLD * 1.5));
            }
            this.lastY = event.touches[0].y;
          } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
            if (this.pullDistance >= this.PULL_THRESHOLD && !this.refreshing) {
              this.refreshing = true;
              this.pullDistance = 0;
              this.onRefresh();
            } else {
              this.pullDistance = 0;
            }
            this.lastY = 0;
          }
        })
        .width('100%')
        .clip(false)
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        .overlay(this.BottomFadeOverlay())
        .blendMode(BlendMode.SRC_OVER, BlendApplyType.OFFSCREEN)
        }
      } else {
        Column() {
          if (this.loadState === LoadState.Loading) {
            ListRowSkeleton({ count: 6 })
              .width('100%')
              .layoutWeight(1)
          } else if (this.loadState === LoadState.Error) {
            ErrorView({ message: this.errorMsg, onRetry: () => { this.loadFirst(); } }).layoutWeight(1)
          } else if (this.loadState === LoadState.Empty) {
            EmptyView({
              message: this.mode === FollowListMode.Mutual ? '暂无互相关注的用户' : '还没有关注的用户\n在用户主页点「+ 关注」即可添加',
              icon: '👥'
            }).layoutWeight(1)
          }
        }
        .width('100%')
        .height('100%')
        .padding({ top: 104 })
        .backgroundColor(Theme.bg(this.isDark))
        .clip(false)
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      }

      // 悬浮沉浸顶栏（渐变遮罩之上，同 ThreadDetail 范式）；
      // 官方 title 槽位路径下整行已在槽位里（FollowTitleBar），这里不再叠一层
      if (!(FOLLOW_OFFICIAL_TITLE_BAR && this.materialSupported)) {
        this.TopBar()
      }

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
      if (this.showDeleteConfirm) {
        this.DeleteConfirmDialog()
      }
    }
    .width('100%')
    .height('100%')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  build() {
    if (FOLLOW_OFFICIAL_TITLE_BAR && this.materialSupported) {
      // 官方槽位路径（§6.10）：顶栏整行（返回 / 排序 / 编辑 / 我的关注）搬进 Navigation title 槽位吃真材质
      Navigation() {
        this.FollowContent()
      }
      .title({ builder: this.FollowTitleBar(), height: FOLLOW_TITLE_BAR_HEIGHT },
        { barStyle: BarStyle.STACK, backgroundColor: Color.Transparent })
      .mode(NavigationMode.Stack)
      .hideTitleBar(false)
      .hideBackButton(true)
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Transparent)
      .clip(false)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    } else {
      // 兜底路径：页面主体悬浮自绘玻璃（改造前原样）
      this.FollowContent()
    }
  }

  /** 自定义下拉刷新指示器：显隐完全自控（List 条件 item），绕开系统 Refresh 组件的 prop 同步问题 */
  @Builder
  RefreshIndicator() {
    Row({ space: 8 }) {
      LoadingProgress()
        .width(22)
        .height(22)
        .color(Theme.textSecondary(this.isDark))
      Text('刷新中…')
        .fontSize(13)
        .fontColor(Theme.textSecondary(this.isDark))
    }
    .width('100%')
    .height(48)
    .justifyContent(FlexAlign.Center)
  }

  /** 渐变沉浸遮罩：顶部渐显（同 ThreadList/Index/ThreadDetail BottomFadeOverlay 范式） */
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

  // ===== 悬浮沉浸顶栏（渐变遮罩 + 磨砂玻璃按钮，同 ThreadDetail 范式）=====

  @Builder
  TopBar() {
    Stack() {
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
        .accessibilityText(this.editMode ? '退出编辑' : '返回')
        .onClick(() => {
          if (this.editMode) {
            this.exitEditMode();
          } else {
            this.getUIContext().getRouter().back();
          }
        })

        if (this.editMode) {
          Text(`已选 ${this.selectedKeys.length} 项`)
            .fontSize(fs(18, this.fontScale))
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.textPrimary(this.isDark))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }

        if (!this.editMode) {
          Blank()
        }

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
          // 排序按钮（最左；同收藏页 TopBar：44vp Text('⇅') 文本符号钮 + manualGlass）
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
          .accessibilityText('排序')
          .accessibilityDescription(this.sortModeLabel(this.sortMode))
          .onClick(() => { this.openSortMenu(); })

          // 编辑钮（排序钮右侧；同收藏页 TopBar）
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
          .accessibilityText('编辑')
          .onClick(() => { this.enterEditMode(); })

          // 一键切换钮（编辑钮右侧；最右；无弹窗，本地 is_friend 过滤）
          Button() {
            Text(this.mode === FollowListMode.Mutual ? '互相关注' : '我的关注')
              .fontSize(fs(13, this.fontScale))
              .fontColor(this.mode === FollowListMode.Mutual ? Theme.brand() : $r('sys.color.font_primary'))
          }
          .height(40)
          .padding({ left: 14, right: 14 })
          .backgroundColor(Theme.manualGlass(this.isDark))
          .border({ width: 0.5, color: Theme.manualGlassBorder() })
          .shadow(Theme.glassShadowStyle()).backgroundEffect(ImmBlur.control())
          .systemMaterial(ImmMaterial.control())
          .borderRadius(Radius.full)
          .accessibilityText(this.mode === FollowListMode.Mutual ? '当前互相关注，点击切换为全部关注' : '当前全部关注，点击切换为互相关注')
          .onClick(() => { this.switchMode(); })
        }
      }
      .width('100%')
      .height(44)
      .align(Alignment.Start)
    }
    .width('100%')
    .height(98)
    .padding({ left: Spacing.lg, right: Spacing.lg, top: 44, bottom: 10 })
    .backgroundColor(Color.Transparent)
    .align(Alignment.TopStart)
    .zIndex(10)
  }

  /**
   * 官方槽位标题栏（§6.10 同机制）：返回 44 圆钮 / 排序 44 圆钮 / 编辑 · 我的关注 文字胶囊；
   * 编辑态换成「已选 n 项」+ 全选胶囊。
   * 玻璃统一换成 `ImmMaterial.seg(false)`（THIN 中性档），按坑 24 删除 `manualGlass` / `manualGlassBorder` /
   * `glassShadowStyle` + `backgroundEffect(ImmBlur.control())` / `control()` 四项自绘玻璃；
   * `Button` 补 `backgroundColor(Color.Transparent)` 清默认品牌蓝填充（Text / Row 无默认填充）。
   * 几何（top 44 / bottom 10 / 左右 Spacing.lg / space Spacing.sm / 圆钮 44 / 文字胶囊 height 40 padding 14）
   * 逐项一致；`zIndex(10)` 槽内无叠层序需求，去掉。
   */
  @Builder
  FollowTitleBar() {
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
      .accessibilityText(this.editMode ? '退出编辑' : '返回')
      .onClick(() => {
        if (this.editMode) {
          this.exitEditMode();
        } else {
          this.getUIContext().getRouter().back();
        }
      })

      if (this.editMode) {
        Text(`已选 ${this.selectedKeys.length} 项`)
          .fontSize(fs(18, this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.textPrimary(this.isDark))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }

      if (!this.editMode) {
        Blank()
      }

      if (this.editMode) {
        Button() {
          Text(this.allSelected() ? '取消全选' : '全选')
            .fontSize(fs(14, this.fontScale))
            .fontColor($r('sys.color.font_primary'))
        }
        .height(40)
        .padding({ left: 14, right: 14 })
        .backgroundColor(Color.Transparent)
        .systemMaterial(ImmMaterial.seg(false))
        .borderRadius(Radius.full)
        .accessibilityText('全选切换')
        .onClick(() => { this.toggleSelectAll(); })
      } else {
        // 排序按钮（最左；44vp Text('⇅') 文本符号钮）
        Row() {
          Text('⇅')
            .fontSize(fs(20, this.fontScale))
            .fontColor(Theme.textPrimary(this.isDark))
        }
        .width(44)
        .height(44)
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .systemMaterial(ImmMaterial.seg(false))
        .borderRadius(Radius.full)
        .accessibilityText('排序')
        .accessibilityDescription(this.sortModeLabel(this.sortMode))
        .onClick(() => { this.openSortMenu(); })

        // 编辑钮（排序钮右侧）
        Button() {
          Text('编辑')
            .fontSize(fs(14, this.fontScale))
            .fontColor($r('sys.color.font_primary'))
        }
        .height(40)
        .padding({ left: 14, right: 14 })
        .backgroundColor(Color.Transparent)
        .systemMaterial(ImmMaterial.seg(false))
        .borderRadius(Radius.full)
        .accessibilityText('编辑')
        .onClick(() => { this.enterEditMode(); })

        // 一键切换钮（编辑钮右侧；最右；无弹窗，本地 is_friend 过滤）
        Button() {
          Text(this.mode === FollowListMode.Mutual ? '互相关注' : '我的关注')
            .fontSize(fs(13, this.fontScale))
            .fontColor(this.mode === FollowListMode.Mutual ? Theme.brand() : $r('sys.color.font_primary'))
        }
        .height(40)
        .padding({ left: 14, right: 14 })
        .backgroundColor(Color.Transparent)
        .systemMaterial(ImmMaterial.seg(false))
        .borderRadius(Radius.full)
        .accessibilityText(this.mode === FollowListMode.Mutual ? '当前互相关注，点击切换为全部关注' : '当前全部关注，点击切换为互相关注')
        .onClick(() => { this.switchMode(); })
      }
    }
    .width('100%')
    .padding({ left: Spacing.lg, right: Spacing.lg, top: 44, bottom: 10 })
  }

  /** 列表行：头像40vp / 昵称 / 「来自贴吧关注 · 简介」副行 / 右侧已关注态；编辑态圈选 */
  @Builder
  FollowItemRow(item: FollowUserItem) {
    Row({ space: Spacing.md }) {
      if (this.editMode) {
        Stack() {
          if (this.isSelected(item)) {
            Text('✓')
              .fontSize(fs(12, this.fontScale))
              .fontColor(Color.White)
              .textAlign(TextAlign.Center)
          }
        }
        .width(22)
        .height(22)
        .borderRadius(11)
        .backgroundColor(this.isSelected(item) ? Theme.brand() : Color.Transparent)
        .border({ width: 2, color: this.isSelected(item) ? Color.Transparent : Theme.textTertiary(this.isDark) })
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

      // 右侧已关注态（非编辑态可点击取关）
      if (!this.editMode) {
        Text('已关注 ✓')
          .fontSize(fs(12, this.fontScale))
          .fontColor(Theme.brand())
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .backgroundColor(Theme.brandBg(this.isDark))
          .borderRadius(Radius.full)
          .accessibilityText('已关注，点击取消关注')
          .onClick(() => { this.requestUnfollowOne(item); })
      }
    }
    .width('100%')
    .padding({ left: Spacing.lg, right: Spacing.lg, top: Spacing.md, bottom: Spacing.md })
    .backgroundColor(Theme.bgCard(this.isDark))
    .borderRadius(Radius.lg)
    .accessibilityText(item.name || item.userId || '未知用户')
    .accessibilityDescription(this.editMode ? '点击切换勾选' : '点击进入用户主页')
    .onClick(() => {
      if (this.editMode) {
        this.toggleSelect(item);
      } else {
        this.openUser(item);
      }
    })
  }

  /** 编辑态底部操作栏（复用收藏页/黑名单 EditBar 范式：全选 + 危险红取关） */
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
          Text(`取关 (${this.selectedKeys.length})`)
            .fontSize(fs(15, this.fontScale))
            .fontColor(Color.White)
        }
        .height(44)
        .padding({ left: 20, right: 20 })
        .backgroundColor(Theme.danger())
        .borderRadius(Radius.full)
        .accessibilityText('批量取消关注')
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
      this.SortMenuItem(FollowSortMode.NameAsc, '名称正序')
      this.SortMenuItem(FollowSortMode.NameDesc, '名称倒序')
      this.SortMenuItem(FollowSortMode.TimeAsc, '最早关注')
      this.SortMenuItem(FollowSortMode.TimeDesc, '最新关注')
    }
    .padding({ top: 6, bottom: 6 })
  }

  @Builder
  SortMenuItem(mode: FollowSortMode, label: string) {
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

  /** 取关确认：居中卡片浮层（复用收藏页 PinConfirmDialog / 黑名单 DeleteConfirmDialog 范式，危险操作红色） */
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
          Text(this.unfollowTarget ? '取消关注' : '批量取消关注')
            .fontSize(fs(17, this.fontScale))
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.textPrimary(this.isDark))
            .textAlign(TextAlign.Center)
          Text(this.unfollowTarget
            ? `确定不再关注「${this.unfollowTarget.name || this.unfollowTarget.userId || '该用户'}」吗？`
            : `确定取消关注选中的 ${this.selectedKeys.length} 位用户吗？`)
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
            Text(this.deleteBusy ? '处理中...' : '取消关注')
              .fontSize(fs(15, this.fontScale))
              .fontColor(Color.White)
              .fontWeight(FontWeight.Medium)
          }
          .layoutWeight(1)
          .height(44)
          .backgroundColor(Theme.danger())
          .borderRadius(Radius.full)
          .accessibilityText('确认取消关注')
          .onClick(() => {
            if (this.unfollowTarget) {
              this.confirmUnfollowOne();
            } else {
              this.confirmDeleteSelected();
            }
          })
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
