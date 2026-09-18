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
import { Theme, Spacing, Radius, Breakpoint, isDarkMode, ImmBlur, ImmMaterial, MaterialManager, fs, isWideBarDevice, isLargeFoldDevice, isPuraXMaxDevice, isWideFormDevice as detectWideFormDevice, readColumnMode, overrideColumns, isLargeScreenForm, isWideBarFullscreen } from '../common/Theme';
import { ToastUtil, ToastType } from '../common/ToastUtil';
import { Haptic } from '../common/Haptic';
import { TiebaService, BlacklistPermOptions } from '../service/TiebaService';
import { AuthManager } from '../service/AuthManager';
import { CacheManager } from '../cache/CacheManager';
import { CACHE_KEY, formatTime, BRAND_BLUE } from '../common/Constants';
import { UserProfileModel, UserLikeItem, PersonalContentItem } from '../model/DataModel';
import { LoadingView, EmptyView, ErrorView } from '../components/CommonComponents';
import { ThreadListSkeleton } from '../components/Skeleton';
import { common } from '@kit.AbilityKit';
import { window, LengthMetrics, curves } from '@kit.ArkUI';

enum ProfileLoadState {
  Loading = 0,
  Ready = 1,
  Empty = 2,
  Error = 3,
}

/** 帖子 Tab 排序（本地已加载数据重排，不触发网络；偏好持久化 user_posts_sort_{userId}） */
enum PostSortMode {
  TimeDesc = 0,
  TimeAsc = 1,
}

enum UserTab {
  Posts = 0,
  Likes = 1,
}

/** 官方标题栏开关（§6.10 模板）：true 且设备支持材质时，顶栏整行（返回 / 排序 / 黑名单 / 关注）搬进
 *  Navigation title 槽位吃官方材质；false 或低版本自动回退到页面主体悬浮自绘玻璃 TopBar（原样保留）。 */
const USER_PROFILE_OFFICIAL_TITLE_BAR: boolean = true;
/** 槽位高度 = 44(状态栏让位) + 44(按钮行高) + 10(底部呼吸)，与旧悬浮 TopBar 的 padding 逐项一致；
 *  内容让位（头部 / 列表顶部留白）一行未改。 */
const USER_PROFILE_TITLE_BAR_HEIGHT: number = 98;

// 兼容不同 SDK 版本 AvoidArea 字段结构（底部安全区高度）
interface SafeAreaRect {
  height?: number;
}

interface SafeAreaBottom {
  rect?: SafeAreaRect;
}

interface AvoidAreaCompat {
  bottom?: SafeAreaBottom;
  bottomRect?: SafeAreaRect;
}

/**
 * 用户主页（v1.12 · 批 C）：点击任意用户头像进入。
 * - 头部：大头像 76vp / 昵称 / ID·性别·IP / 简介 / 关注按钮（本人隐藏）/ 关注·粉丝·获赞统计行
 * - 双 Tab：发布的帖子（PersonalContentItem 卡片 + 顶部排序菜单）/ 关注的吧（吧卡片）
 * - 顶栏：悬浮沉浸（磨砂玻璃圆形按钮，复用 ThreadDetail 范式）；右上角黑名单按钮（本人隐藏）
 * - 弹窗：关注/取消关注/拉黑确认均复用收藏页居中卡片浮层范式（暗蒙层 + 磨砂玻璃卡）
 * - 接口：profile 扩展解析已可用；关注/取关/关注吧接口为占位（TODO 批A）
 */
@Entry
@Component
struct UserProfile {
  @State isDark: boolean = isDarkMode();
  @State profile: UserProfileModel | null = null;
  @State profileState: ProfileLoadState = ProfileLoadState.Loading;
  @State profileError: string = '';
  @State activeTab: UserTab = UserTab.Posts;

  // ===== Tab 切换动画 / 左右滑动（范式照抄首页 Index.switchTab：双页平移 + springMotion）=====
  @State prevTab: number = -1;            // 动画期间的退场页（-1 = 无；存 UserTab 数值）
  @State inOffset: number = 0;            // 进场页横向位移（页宽百分比）
  @State outOffset: number = 0;           // 退场页横向位移（页宽百分比）
  @State dragging: boolean = false;       // 手势拖拽中（页面位移走 dragPct 分支）
  @State dragPct: number = 0;             // 拖拽实时位移（相对页宽百分比）
  private animLock: boolean = false;      // 点击切换动画锁（动画期间忽略连点/再拖）
  private panActive: boolean = false;     // 本次手势是否有效（动画期间开始的手势直接忽略）
  // 关注的吧页首访后才挂载（隐藏保留滚动位置，未访不拉数据）；必须是 @State——
  // 翻转时依赖它触发 UI 重渲染（if (this.likesMounted) 挂载分支），普通字段不驱动渲染会整页空白
  @State likesMounted: boolean = false;

  // 帖子 Tab
  @State posts: PersonalContentItem[] = [];
  @State postsState: ProfileLoadState = ProfileLoadState.Loading;
  @State postsError: string = '';
  @State postsPage: number = 1;
  @State postsHasMore: boolean = true;
  @State postsLoadingMore: boolean = false;
  @State postSortMode: PostSortMode = PostSortMode.TimeDesc;
  @State showPostSortMenu: boolean = false;

  // 关注吧 Tab（懒加载：切到才拉）
  @State likes: UserLikeItem[] = [];
  @State likesState: ProfileLoadState = ProfileLoadState.Loading;
  @State likesError: string = '';
  @State likesPage: number = 1;
  @State likesHasMore: boolean = true;
  @State likesLoadingMore: boolean = false;

  // 关注 / 拉黑交互
  @State isFollowed: boolean = false;
  @State isBlocked: boolean = false;
  @State followBusy: boolean = false;
  @State blockBusy: boolean = false;
  @State showUnfollowConfirm: boolean = false;
  @State showBlockConfirm: boolean = false;
  // 拉黑精细化开关（对齐官方 App）：禁止私信 / 禁止关注 / 禁止互动
  @State blockChat: boolean = true;
  @State blockFollow: boolean = true;
  @State blockInteract: boolean = true;

  // 底部安全区高度（手势小白条 / 三键导航栏），用于列表底部留空；Tab 本身由 safeAreaPadding 系统级避让
  @State bottomSafeHeight: number = 34;

  // 视口宽度与宽屏标记：API26+ 浮槽胶囊宽度（屏宽-48，宽屏封顶 480）随窗口实时更新
  @State currentWidth: number = 360;
  @State isWideScreen: boolean = false;
  /** 设备是否支持系统沉浸材质（aboutToAppear 中 MaterialManager.init() 后确定） */
  @State materialSupported: boolean = true;

  // ===== 平板适配（docs/TiebaPura平板适配.md §4.11，2026-09-15 用户重定：瀑布流竖 3 / 横 4 + 弹窗不拉伸）=====
  /** 大屏形态设备（平板 / 2in1 / 折叠屏）：静态判定一次。折叠屏 deviceType 为 'phone'，必须单独用 isFoldable 识别（§4.8 T-B 同款） */
  private readonly isWideFormDevice: boolean = detectWideFormDevice();
  /** 窗口宽 / 高（vp）：aboutToAppear 首帧 + onAreaChange 兜底 */
  @State pageWidth: number = 0;
  @State pageHeight: number = 0;
  private isLandscape: boolean = false;

  @StorageLink('fontScale') fontScale: number = 1.0;
  /** 页面可见时自增，强制组件重建使字号实时生效 */
  @State fontSizeTick: number = 0;
  // 「列数调整」档位广播（2026-09-18，个性化 → 列数调整）：@Watch 回写本地档位 → 列数函数按新档返回并强制回到列表顶部
  // （离屏期间 @StorageLink 同步不重绘，故用 tick + 本地 @State 兜底，同 fontTick 范式）
  @StorageLink('columnModeTick') @Watch('onColumnModeTick') columnModeTick: number = 0;
  @State columnMode: number = 0;

  onPageShow(): void {
    this.fontSizeTick++;
  }

  private readonly PAGE_SIZE: number = 20;
  private userId: string = '';
  private userName: string = '';
  private postsScroller: Scroller = new Scroller();
  private likesScroller: Scroller = new Scroller();
  private context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;

  aboutToAppear(): void {
    MaterialManager.init();
    this.materialSupported = MaterialManager.isSupported();
    this.isDark = isDarkMode();
    // 首帧形态初值（§4.6 H-A / §4.8 T-B 同源）：onAreaChange 只在尺寸变化后触发，冷启动平板横屏
    // 若不预置会出现「先 1 列再跳 3/4 列」的首帧跳变。取不到就保持 0，由 onAreaChange 兜底。
    this.refreshFormMetrics();
    // 「列数调整」档位初值（2026-09-18）：冷启动首帧即按已选档渲染
    // （UsageHabitsManager.init 的 columnModeTick 可能早于本页构造，@Watch 不会补触发，故此处直读）
    this.columnMode = readColumnMode();
    const params = this.getUIContext().getRouter().getParams() as Record<string, Object>;
    this.userId = `${params?.userId ?? ''}`.trim();
    this.userName = `${params?.userName ?? ''}`.trim();
    if (this.userId.length === 0) {
      this.profileState = ProfileLoadState.Error;
      this.profileError = '缺少用户 ID，无法打开用户主页';
      return;
    }
    this.initPostSortPref();
    this.loadProfile();
    this.initSafeArea();
  }

  private async initSafeArea(): Promise<void> {
    try {
      const win = await window.getLastWindow(this.context);
      let h: number = 0;
      // 遍历多种避免区类型取最大底部高度，覆盖手势导航 / 三键导航 / 混合形态
      try {
        h = Math.max(h, this.avoidAreaHeight(win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR) as AvoidAreaCompat));
      } catch (e) {
      }
      try {
        h = Math.max(h, this.avoidAreaHeight(win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM_GESTURE) as AvoidAreaCompat));
      } catch (e) {
      }
      try {
        h = Math.max(h, this.avoidAreaHeight(win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM) as AvoidAreaCompat));
      } catch (e) {
      }
      // 防御：个别设备 TYPE_SYSTEM 会返回异常大值，超过 120vp（三键导航 + 手势区叠加上限）按无效处理
      if (h > 0 && h <= 120) {
        this.bottomSafeHeight = h;
      }
    } catch (e) {
      // 取不到时保留默认兜底值
    }
  }

  private avoidAreaHeight(area: AvoidAreaCompat): number {
    return area.bottom?.rect?.height ?? area.bottomRect?.height ?? 0;
  }

  private isSelf(): boolean {
    const mine: string = AuthManager.getInstance().getUser()?.userId ?? '';
    return mine.length > 0 && mine === this.userId;
  }

  private toast(message: string, type: ToastType = ToastType.Info): void {
    ToastUtil.show(this.getUIContext(), message, type);
  }

  // ===== 资料加载（profile 扩展解析，5 分钟 TTL 缓存）=====

  private async loadProfile(): Promise<void> {
    this.profileState = ProfileLoadState.Loading;
    try {
      const p = await TiebaService.getInstance().fetchUserProfile(this.userId);
      this.profile = p;
      this.isFollowed = p.isFollowed;
      this.profileState = ProfileLoadState.Ready;
      this.loadPostsFirst();
    } catch (e) {
      this.profileError = (e as Error).message ?? '用户资料加载失败，请稍后重试';
      this.profileState = ProfileLoadState.Error;
    }
  }

  // ===== 帖子 Tab =====

  private async loadPostsFirst(): Promise<void> {
    this.postsState = ProfileLoadState.Loading;
    this.postsPage = 1;
    this.postsHasMore = true;
    try {
      const list = await TiebaService.getInstance().fetchUserContent(this.userId, 1, true);
      this.posts = list;
      this.postsHasMore = list.length >= this.PAGE_SIZE;
      this.postsState = this.posts.length > 0 ? ProfileLoadState.Ready : ProfileLoadState.Empty;
    } catch (e) {
      this.postsError = (e as Error).message ?? '帖子加载失败，请稍后重试';
      this.postsState = ProfileLoadState.Error;
    }
  }

  private async loadPostsMore(): Promise<void> {
    if (this.postsLoadingMore || !this.postsHasMore || this.postsState !== ProfileLoadState.Ready) {
      return;
    }
    this.postsLoadingMore = true;
    try {
      const next: number = this.postsPage + 1;
      const list = await TiebaService.getInstance().fetchUserContent(this.userId, next, true);
      this.posts = [...this.posts, ...list];
      this.postsPage = next;
      this.postsHasMore = list.length >= this.PAGE_SIZE;
    } catch (e) {
      this.toast('更多帖子加载失败，请稍后重试', ToastType.Error);
    } finally {
      this.postsLoadingMore = false;
    }
  }

  /** createTime 解析为时间戳（兼容 unix 秒 / 毫秒 / 格式化串；格式待批 A 确认） */
  private parseTs(raw: string): number {
    if (raw.length === 0) {
      return 0;
    }
    const n: number = Number(raw);
    if (!isNaN(n)) {
      return n < 100000000000 ? n * 1000 : n;
    }
    return Date.parse(raw) || 0;
  }

  private sortedPosts(): PersonalContentItem[] {
    const list: PersonalContentItem[] = this.posts.slice();
    list.sort((a: PersonalContentItem, b: PersonalContentItem): number => {
      const ta: number = this.parseTs(a.createTime);
      const tb: number = this.parseTs(b.createTime);
      return this.postSortMode === PostSortMode.TimeDesc ? tb - ta : ta - tb;
    });
    return list;
  }

  private async initPostSortPref(): Promise<void> {
    try {
      const raw = await CacheManager.getInstance().get(`${CACHE_KEY.USER_POSTS_SORT}_${this.userId}`);
      if (raw) {
        const n: number = parseInt(raw, 10);
        if (n === 0 || n === 1) {
          this.postSortMode = n as PostSortMode;
        }
      }
    } catch (e) {
      // 读取失败用默认
    }
  }

  private savePostSort(): void {
    CacheManager.getInstance().put(`${CACHE_KEY.USER_POSTS_SORT}_${this.userId}`, String(this.postSortMode)).catch(() => {
    });
  }

  private applyPostSort(mode: PostSortMode): void {
    if (this.postSortMode === mode) {
      this.showPostSortMenu = false;
      return;
    }
    this.postSortMode = mode;
    this.savePostSort();
    this.showPostSortMenu = false;
    Haptic.light();
    this.toast(mode === PostSortMode.TimeDesc ? '已切换为最新时间' : '已切换为最早时间', ToastType.Success);
  }

  // ===== 关注吧 Tab（懒加载；占位接口失败按隐私降级显示空态）=====

  private async loadLikesFirst(): Promise<void> {
    this.likesState = ProfileLoadState.Loading;
    this.likesPage = 1;
    this.likesHasMore = true;
    try {
      const result = await TiebaService.getInstance().fetchUserLikeList(this.userId, 1, this.PAGE_SIZE);
      this.likes = result.list;
      this.likesHasMore = result.hasMore;
      this.likesState = this.likes.length > 0 ? ProfileLoadState.Ready : ProfileLoadState.Empty;
    } catch (e) {
      const msg: string = (e as Error).message ?? '';
      if (msg.indexOf('接口待接入') >= 0) {
        // 批 A 前占位：按「对方隐藏了关注的吧信息」隐私降级空态展示，布局不受影响
        this.likes = [];
        this.likesState = ProfileLoadState.Empty;
      } else {
        this.likesError = msg.length > 0 ? msg : '关注的吧加载失败，请稍后重试';
        this.likesState = ProfileLoadState.Error;
      }
    }
  }

  private async loadLikesMore(): Promise<void> {
    if (this.likesLoadingMore || !this.likesHasMore || this.likesState !== ProfileLoadState.Ready) {
      return;
    }
    this.likesLoadingMore = true;
    try {
      const next: number = this.likesPage + 1;
      const result = await TiebaService.getInstance().fetchUserLikeList(this.userId, next, this.PAGE_SIZE);
      this.likes = [...this.likes, ...result.list];
      this.likesPage = next;
      this.likesHasMore = result.hasMore;
    } catch (e) {
      this.toast('更多关注的吧加载失败，请稍后重试', ToastType.Error);
    } finally {
      this.likesLoadingMore = false;
    }
  }

  // ===== 关注 / 取消关注（乐观更新 + 失败回滚，复用 ThreadDetail 点赞范式）=====

  private requestToggleFollow(): void {
    if (!AuthManager.getInstance().isLogin()) {
      this.toast('请先登录后再关注用户');
      return;
    }
    if (this.isSelf() || this.followBusy) {
      return;
    }
    if (this.isFollowed) {
      // 已关注再点击 → 弹取消确认（防误触）
      this.showUnfollowConfirm = true;
    } else {
      this.doFollow();
    }
  }

  private async doFollow(): Promise<void> {
    if (this.followBusy) {
      return;
    }
    this.followBusy = true;
    const prev: boolean = this.isFollowed;
    this.isFollowed = true;
    try {
      const ok = await TiebaService.getInstance().followUser(this.profile?.portrait ?? '', this.profile?.name ?? this.userName);
      if (!ok) {
        this.isFollowed = prev;
        this.toast('关注失败，请稍后重试', ToastType.Error);
        return;
      }
      Haptic.light();
      this.toast('关注成功', ToastType.Success);
    } catch (e) {
      this.isFollowed = prev;
      this.toast((e as Error).message ?? '关注失败，请稍后重试', ToastType.Error);
    } finally {
      this.followBusy = false;
    }
  }

  private async confirmUnfollow(): Promise<void> {
    if (this.followBusy) {
      return;
    }
    this.showUnfollowConfirm = false;
    this.followBusy = true;
    const prev: boolean = this.isFollowed;
    this.isFollowed = false;
    try {
      const ok = await TiebaService.getInstance().unfollowUser(this.profile?.portrait ?? '');
      if (!ok) {
        this.isFollowed = prev;
        this.toast('取消关注失败，请稍后重试', ToastType.Error);
        return;
      }
      Haptic.strong();
      this.toast('已取消关注', ToastType.Success);
    } catch (e) {
      this.isFollowed = prev;
      this.toast((e as Error).message ?? '取消关注失败，请稍后重试', ToastType.Error);
    } finally {
      this.followBusy = false;
    }
  }

  // ===== 拉黑（右上角按钮 → 确认弹窗 → 云端拉黑 + 连带取关）=====

  private openBlockConfirm(): void {
    if (this.isBlocked) {
      this.toast('已加入黑名单');
      return;
    }
    // 每次打开弹窗重置为全开（对齐官方 App 默认行为）
    this.blockChat = true;
    this.blockFollow = true;
    this.blockInteract = true;
    this.showBlockConfirm = true;
  }

  private closeBlockConfirm(): void {
    this.showBlockConfirm = false;
  }

  private async confirmBlock(): Promise<void> {
    if (this.blockBusy) {
      return;
    }
    this.blockBusy = true;
    try {
      const perm: BlacklistPermOptions = {
        follow: this.blockFollow,
        interact: this.blockInteract,
        chat: this.blockChat,
      };
      const ok = await TiebaService.getInstance().blockUser(this.userId, this.profile?.name ?? this.userName, perm);
      if (!ok) {
        this.toast('拉黑失败，请稍后重试', ToastType.Error);
        return;
      }
      this.isBlocked = true;
      this.showBlockConfirm = false;
      // 本地记忆 perm，供黑名单管理页编辑弹窗回显（新版查询接口失败时的兜底）
      CacheManager.getInstance().put(`${CACHE_KEY.BLACKLIST_PERM}_${this.userId}`,
        JSON.stringify({ follow: this.blockFollow, interact: this.blockInteract, chat: this.blockChat })).catch(() => {
      });
      // 拉黑连带自动取消关注（跟随贴吧云端行为）
      if (this.isFollowed) {
        this.isFollowed = false;
        try {
          await TiebaService.getInstance().unfollowUser(this.profile?.portrait ?? '');
        } catch (e) {
          // 云端拉黑已生效，取关失败仅本地态更新
        }
      }
      Haptic.strong();
      this.toast('已加入黑名单', ToastType.Success);
    } catch (e) {
      this.toast((e as Error).message ?? '拉黑失败，请稍后重试', ToastType.Error);
    } finally {
      this.blockBusy = false;
    }
  }

  // ===== 辅助文案 =====

  private metaLine(): string {
    const parts: string[] = [];
    parts.push(`ID: ${this.profile?.userId ?? this.userId}`);
    const sexText: string = this.sexText();
    if (sexText.length > 0) {
      parts.push(sexText);
    }
    if (this.profile && this.profile.ip.length > 0) {
      parts.push(`IP属地 ${this.profile.ip}`);
    }
    return parts.join(' · ');
  }

  private sexText(): string {
    const sex: number = this.profile?.sex ?? 0;
    if (sex === 1) {
      return '♂';
    }
    if (sex === 2) {
      return '♀';
    }
    return '';
  }

  /**
   * 统一 Tab 切换入口（点分段胶囊）：方向感知滑入动画，范式与首页 Index.switchTab 一致。
   * 目标页在右（index 更大）→ 新页从右滑入、旧页向左滑出；反之镜像。
   * 动画期间锁定（animLock），快速连点直接忽略。
   */
  private switchTab(tab: UserTab): void {
    if (tab === this.activeTab || this.animLock || this.dragging) {
      return;
    }
    const dir: number = tab > this.activeTab ? 1 : -1;
    this.animLock = true;
    this.prevTab = this.activeTab;
    this.activeTab = tab;
    if (tab === UserTab.Likes) {
      this.likesMounted = true;
      if (this.likesState === ProfileLoadState.Loading) {
        this.loadLikesFirst();
      }
    }
    // 初始位置（无动画赋值）：新页从 dir 方向侧外进入，旧页原位准备退场
    this.inOffset = dir * 100;
    this.outOffset = 0;
    this.getUIContext().animateTo(
      { duration: 320, curve: curves.springMotion(0.72, 0.86) },
      () => {
        this.outOffset = -dir * 100;
        this.inOffset = 0;
      }
    );
    // SDK 的 animateTo 无 onFinish：定时器在动画结束后卸载退场页并释放切换锁
    // （时长取动画约 1.3 倍，弹簧曲线可能略有回弹超时）
    setTimeout(() => {
      this.prevTab = -1;
      this.outOffset = 0;
      this.animLock = false;
    }, 420);
  }

  /** 页面横向位移：拖拽中当前页原位跟手、邻页在其行进方向侧外；动画期走 in/outOffset */
  private tabTranslate(tab: UserTab): string {
    if (this.dragging) {
      if (tab === this.activeTab) {
        return `${this.dragPct}%`;
      }
      const dir: number = tab > this.activeTab ? 1 : -1;
      return `${this.dragPct + dir * 100}%`;
    }
    if (tab === this.activeTab) {
      return `${this.inOffset}%`;
    }
    return `${this.outOffset}%`;
  }

  /** 层级：当前页盖在退场页之上 */
  private tabLayer(tab: UserTab): number {
    return tab === this.activeTab ? 1 : 0;
  }

  /** 页面可见性：当前页/退场页常显；拖拽中仅行进方向侧的邻页随动显示 */
  private tabPageVisible(tab: UserTab): Visibility {
    if (tab === this.activeTab || tab === (this.prevTab as UserTab)) {
      return Visibility.Visible;
    }
    if (this.dragging && this.panActive) {
      const dir: number = tab > this.activeTab ? 1 : -1;
      if ((this.dragPct < 0 && dir === 1) || (this.dragPct > 0 && dir === -1)) {
        return Visibility.Visible;
      }
    }
    return Visibility.Hidden;
  }

  /** 页宽（vp）：拖拽位移百分比换算基准；onAreaChange 未回填前用手机基线 360 */
  private panPageWidth(): number {
    return this.currentWidth > 0 ? this.currentWidth : 360;
  }

  /** 形态度量回填：aboutToAppear 首帧（display 兜底猜测）+ onAreaChange（窗口实值）共用。
   *  2026-09-17 小窗 / 分屏适配：传入窗口宽高时以窗口为准（自由多窗下 display ≠ 窗口）。 */
  private refreshFormMetrics(winW?: number, winH?: number): void {
    let w: number = winW ?? 0;
    let h: number = winH ?? 0;
    if (w <= 0 || h <= 0) {
      try {
        const d = display.getDefaultDisplaySync();
        w = this.getUIContext().px2vp(d.width);
        h = this.getUIContext().px2vp(d.height);
      } catch (e) {
        // 忽略：窗口未 attach 时取宽会失败
        return;
      }
    }
    if (w <= 0 || h <= 0) {
      return;
    }
    this.pageWidth = w;
    this.pageHeight = h;
    this.isLandscape = w > h;
  }

  /**
   * 结果列数：大屏竖屏 3 / 横屏 4（2026-09-15 用户拍板，与首页 §4.2 决策 12 同口径）。
   * 形态闸门必须放首行：只按宽度判会让手机横屏误命中多列（§6.1 D4）。
   */
  /**
   * 「列数调整」档位变化（个性化页写入 → `columnModeTick` 广播）：
   * 回写本地档位（列数函数随新档返回）→ 强制回到列表顶部（帖子 / 点赞两个列表）。
   * 默认档（0）与原自动适配逐像素一致，仅「用户显式选择」后才改变列数。
   */
  private onColumnModeTick(): void {
    this.columnMode = readColumnMode();
    try {
      this.postsScroller.scrollTo({ xOffset: 0, yOffset: 0 });
      this.likesScroller.scrollTo({ xOffset: 0, yOffset: 0 });
    } catch (e) {
    }
  }

  private profileColumns(): number {
    // 窗口闸门最前（2026-09-17 小窗 / 分屏适配）：窗口宽 <600（自由多窗小窗 / 分屏窄窗）一律回落
    // 手机单列档——须在设备恒值分支（大折叠恒 3）之前，防小窗误命中
    // 阔直屏全屏白名单（2026-09-18）：Pura X View（VOL-AL00）等阔直屏竖屏全屏窗口宽仅 ~440vp，
    // 会被本闸门误判成小窗；白名单放行（小窗 / 分屏仍拦，见 Theme.isWideBarFullscreen）
    if (this.pageWidth > 0 && this.pageWidth < Breakpoint.sm && !isWideBarFullscreen(this.pageWidth)) {
      return 1;
    }
    // 「列数调整」（2026-09-18，个性化 → 列数调整）：仅大屏形态（平板 / 阔直屏 / 大折叠展开）生效，
    // 窄窗与手机档已由上面的窗口闸门返回不受影响；默认档 ov=0 → 原样走下面自动适配分支（逐像素零回归）
    if (isLargeScreenForm(this.isWideFormDevice)) {
      const ov: number = overrideColumns(this.columnMode, this.isLandscape);
      if (ov > 0) {
        return ov;
      }
    }
    // 大折叠（docs/TiebaPura大折叠适配.md §4.2）：竖 2 / 横 3（2026-09-17 用户改定，与阔直屏同口径）
    if (isLargeFoldDevice()) {
      return this.isLandscape ? 3 : 2;
    }
    // 阔直屏（docs/TiebaPura阔直屏适配.md §4.2，2026-09-17 用户改定）：不依赖宽度阈值（竖屏宽 <600），
    // 竖 1 / 横 3（竖屏回落手机单列档；初版竖 2 作废）
    if (isWideBarDevice()) {
      return this.isLandscape ? 3 : 1;
    }
    if (!this.isWideFormDevice) {
      return 1;
    }
    if (this.pageWidth < Breakpoint.sm) {
      return 1;
    }
    // 2026-09-17 三次拍板：平板**竖屏 2 列**（≥840 竖屏 3 列作废）/ 横屏 3 列
    return this.isLandscape ? 3 : 2;
  }

  /** 列索引数组：外层 ForEach 只遍历索引（key 稳定 → 列容器复用，收藏页五轮教训） */
  private profileColIndexes(): number[] {
    const n: number = this.profileColumns();
    const arr: number[] = [];
    for (let i = 0; i < n; i++) {
      arr.push(i);
    }
    return arr;
  }

  /**
   * 通用分桶（方案 B「带滞回的最短列」，2026-09-15，与 §4.9/§4.10/§4.12 同款）：
   * 默认轮转（保序），估算高差 > 240vp（≈一张短卡）才投最短列补位；确定性估算、无测量循环；
   * 前缀稳定贪心：翻页追加从头重算，旧卡落列不变（不跳位）。gap=8 与 List space / 列间 gap 同源。
   */
  private bucketColumns<T>(items: T[], estimate: (item: T) => number): T[][] {
    const cols: number = this.profileColumns();
    const buckets: T[][] = [];
    const heights: number[] = [];
    for (let c = 0; c < cols; c++) {
      buckets.push([]);
      heights.push(0);
    }
    for (let i = 0; i < items.length; i++) {
      let target: number = i % cols;
      let shortest: number = 0;
      for (let c = 1; c < cols; c++) {
        if (heights[c] < heights[shortest]) {
          shortest = c;
        }
      }
      if (heights[target] - heights[shortest] > 240) {
        target = shortest;
      }
      buckets[target].push(items[i]);
      heights[target] += estimate(items[i]) + 8;
    }
    return buckets;
  }

  /** 帖子卡估算高（padding lg×2=32 + 信息行 ~16；标题/摘要 ≤2 行） */
  private estimateProfilePostCard(item: PersonalContentItem): number {
    let h: number = 62;
    const title: string = item.title ?? '';
    if (title.length > 0) {
      h += Math.min(Math.ceil(title.length / 18), 2) * 22 + 6;
    }
    const abs: string = item.abstract ?? '';
    if (abs.length > 0) {
      h += Math.min(Math.ceil(abs.length / 20), 2) * 18 + 6;
    }
    return h;
  }

  /** 关注吧卡估算高（Row 小卡，等高近似值；滞回 240 下本就恒为纯轮转） */
  private estimateProfileLikeCard(item: UserLikeItem): number {
    return 76;
  }

  /** 弹窗 / 浮层面板宽度（vp）：T-H 同款封顶 `max(200, min(400, 屏宽−48))`——手机档 312 < 400 逐像素不变，平板不拉伸 */
  private panelWidth(): number {
    const w: number = this.currentWidth - 48;
    const capped: number = w > 400 ? 400 : w;
    return capped > 200 ? capped : 200;
  }

  private onTabPanStart(): void {
    if (this.animLock || this.dragging) {
      this.panActive = false;
      return;
    }
    this.panActive = true;
    this.dragging = true;
    this.dragPct = 0;
    // 拖拽可能进入关注的吧：提前挂载邻页（首次同时触发懒加载，拖到位时数据已在路上）
    if (!this.likesMounted) {
      this.likesMounted = true;
      if (this.likesState === ProfileLoadState.Loading) {
        this.loadLikesFirst();
      }
    }
  }

  private onTabPanUpdate(offsetX: number): void {
    if (!this.panActive) {
      return;
    }
    let pct: number = offsetX / this.panPageWidth() * 100;
    // 边缘阻尼：已在最外侧 Tab 仍向同方向拖 → 只跟 35% 行程（橡皮筋观感），松手必然回弹
    if ((this.activeTab === UserTab.Posts && offsetX > 0) || (this.activeTab === UserTab.Likes && offsetX < 0)) {
      pct = pct * 0.35;
    }
    this.dragPct = Math.max(-100, Math.min(100, pct));
  }

  private onTabPanEnd(offsetX: number, velocityX: number): void {
    if (!this.panActive) {
      return;
    }
    this.panActive = false;
    const pct: number = this.dragPct;
    // 提交判定：位移过 1/4 页宽，或快速甩动（速度优先于位移）
    let dir: number = 0;
    if (pct <= -25 || velocityX < -700) {
      dir = 1;
    } else if (pct >= 25 || velocityX > 700) {
      dir = -1;
    }
    // 方向越界（最外侧 Tab 再向外拖）或未达阈值 → 回弹归位
    if (dir === 0 || (this.activeTab === UserTab.Posts && dir === -1) || (this.activeTab === UserTab.Likes && dir === 1)) {
      this.getUIContext().animateTo({ duration: 220, curve: curves.springMotion(0.72, 0.86) }, () => {
        this.dragPct = 0;
      });
      setTimeout(() => {
        this.dragging = false;
        this.dragPct = 0;
      }, 280);
      return;
    }
    // 提交切换：两页从拖拽实时位置接续完成进出场（与点击切换同一 springMotion，无跳变）
    this.animLock = true;
    this.prevTab = this.activeTab;
    this.activeTab = dir === 1 ? UserTab.Likes : UserTab.Posts;
    this.dragging = false;
    this.outOffset = pct;
    this.inOffset = pct + dir * 100;
    this.getUIContext().animateTo({ duration: 320, curve: curves.springMotion(0.72, 0.86) }, () => {
      this.outOffset = -dir * 100;
      this.inOffset = 0;
    });
    setTimeout(() => {
      this.prevTab = -1;
      this.outOffset = 0;
      this.animLock = false;
    }, 420);
  }

  // ===== 页面结构 =====

  /**
   * 是否走 API26+ 官方浮槽沉浸路径：悬浮分段胶囊挂真实 Tabs.tabBar 槽位，
   * 系统才把官方浮槽材质渲染到胶囊形状上（机制与首页底部导航 FloatingTabsShell 一致）。
   */
  private useFloatingBar(): boolean {
    return this.materialSupported && MaterialManager.getApiLevel() >= 26;
  }

  /** 悬浮胶囊宽度：宽屏（含平板 / 大折叠展开）**400**（2026-09-16 用户拍板「底栏 = 黑名单弹窗宽度」，横竖屏同值）；
   *  窄屏 屏宽-48，下限 240 防极端异常（手机档逐像素不变） */
  private pillWidth(): number {
    // 大折叠设备恒值项补窗口宽度条件（2026-09-17 小窗 / 分屏适配）：窄窗不吃 400 档，回落手机档
    if (this.isWideScreen || (isLargeFoldDevice() && this.currentWidth >= Breakpoint.sm)) {
      return 400;
    }
    const w: number = this.currentWidth > 0 ? this.currentWidth - 48 : 312;
    return w > 240 ? w : 240;
  }

  /** 页面外壳（原 build() 根 Stack）：官方浮槽壳 / 兜底壳二选一，槽位与兜底两条路径共用 */
  @Builder
  ProfileShell() {
    Stack() {
      if (this.useFloatingBar()) {
        // API26+ 官方沉浸：真实 Tabs 借位槽位承载悬浮分段胶囊，官方浮槽材质渲染
        this.FloatingTabsShell()
      } else {
        // API<26 / 材质不支持：退手写悬浮胶囊兜底（manualGlass + ImmBlur，与历史版本视觉一致）
        this.LegacyShell()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg(this.isDark))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .onAreaChange((oldValue: Area, newValue: Area) => {
      const width = newValue.width as number;
      this.currentWidth = width;
      // Pura X Max（阔折叠展开 ~860vp）与大折叠同口径并入宽屏：底栏/黑名单弹窗 400 不拉伸（2026-09-17 立项）；
      // 小窗 / 分屏窄窗（2026-09-17）：窗口宽 <600 不吃 Pura X Max 设备档，回落手机档
      this.isWideScreen = width >= 840 || (isPuraXMaxDevice() && width >= Breakpoint.sm);
      // 形态变化兜底（横竖屏 / 分屏拖宽：§4.11，列数模板不可补间）；窗口实值优先（小窗 display ≠ 窗口）
      this.refreshFormMetrics(width, newValue.height as number);
    })
  }

  build() {
    if (USER_PROFILE_OFFICIAL_TITLE_BAR && this.materialSupported) {
      // 官方槽位路径（§6.10）：顶栏整行（返回 / 排序 / 黑名单 / 关注）搬进 Navigation title 槽位吃真材质
      Navigation() {
        this.ProfileShell()
      }
      .title({ builder: this.TopTitleBar(), height: USER_PROFILE_TITLE_BAR_HEIGHT },
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
      this.ProfileShell()
    }
  }

  /** 页面主内容层（帖子/关注条件渲染 + 悬浮顶栏 + 菜单/弹窗），API26+/兜底两路径共用 */
  @Builder
  ProfileStack() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        if (this.profileState === ProfileLoadState.Loading) {
          LoadingView({ message: '正在加载用户资料...' }).layoutWeight(1)
        } else if (this.profileState === ProfileLoadState.Error) {
          ErrorView({ message: this.profileError, onRetry: () => { this.loadProfile(); } }).layoutWeight(1)
        } else {
          // 双页平移栈：不用 Swiper（其手势会抢占 List 的垂直滚动），改用首页同款
          // translate 百分比平移 + 水平 PanGesture 跟手拖拽；方向竞争天然让位给列表垂直滚动
          Stack({ alignContent: Alignment.TopStart }) {
            // 帖子页常驻（隐藏时保留滚动位置）
            Column() {
              this.PostTabContent()
            }
            .width('100%')
            .height('100%')
            .translate({ x: this.tabTranslate(UserTab.Posts) })
            .zIndex(this.tabLayer(UserTab.Posts))
            .visibility(this.tabPageVisible(UserTab.Posts))

            if (this.likesMounted) {
              Column() {
                this.LikeTabContent()
              }
              .width('100%')
              .height('100%')
              .translate({ x: this.tabTranslate(UserTab.Likes) })
              .zIndex(this.tabLayer(UserTab.Likes))
              .visibility(this.tabPageVisible(UserTab.Likes))
            }
          }
          .width('100%')
          .layoutWeight(1)
          .clip(true)
          .gesture(
            PanGesture({ fingers: 1, direction: PanDirection.Horizontal, distance: 12 })
              .onActionStart(() => {
                this.onTabPanStart();
              })
              .onActionUpdate((event: GestureEvent) => {
                this.onTabPanUpdate(event.offsetX);
              })
              .onActionEnd((event: GestureEvent) => {
                this.onTabPanEnd(event.offsetX, event.velocityX);
              })
              .onActionCancel(() => {
                this.onTabPanEnd(0, 0);
              })
          )
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.bg(this.isDark))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      // 顶部满宽渐显带（参考收藏页 Favorite.TopFadeBand 真机终版方案）：
      // Stack 顶层背景色渐变条（bg 不透明→透明线性），内容从顶栏下渐现、上滑时渐隐；
      // 不用 overlay+blendMode（收藏页踩坑：离屏层宽度手机端解析异常）；
      // zIndex 8 盖住列表内容，低于兜底 TopBar(10) / 底部分段胶囊(20) / 弹窗(100)；
      // hitTestBehavior(None) 不挡交互。高度沿用收藏页拍板口径 132（顶栏 98 + 渐现尾段 34）。
      this.TopFadeBand()

      // 悬浮沉浸顶栏（透明底，内容可穿过；复用 ThreadDetail 范式）；
      // 官方 title 槽位路径下整行已在槽位里（TopTitleBar），这里不再叠一层
      if (!(USER_PROFILE_OFFICIAL_TITLE_BAR && this.materialSupported)) {
        this.TopBar()
      }

      /**
       * 帖子排序菜单锚点（§6.9：自绘下拉浮层 → 系统 bindMenu）。
       * 原自绘面板是 `position({ top: 100, right: 16 })`；这里用 1×1 隐形锚点 + `Placement.BottomRight`
       * 把菜单右下角精确落回同一坐标（排序钮右侧还有黑名单钮，直接挂按钮会让菜单整体左移）。
       * 锚点不参与视觉与交互：1×1 + 全透明 + hitTestBehavior(None)，弹出仍由 TopBar 排序钮发起。
       */
      Row()
        .width(1)
        .height(1)
        .position({ top: 99, right: 16 })
        .hitTestBehavior(HitTestMode.None)
        .bindMenu(this.showPostSortMenu, this.PostSortMenuContent(), {
          placement: Placement.BottomRight,
          targetSpace: LengthMetrics.vp(0),
          systemMaterial: ImmMaterial.menu(),
          onDisappear: () => { this.showPostSortMenu = false; }
        })
      if (this.showUnfollowConfirm) {
        this.UnfollowConfirmDialog()
      }
      if (this.showBlockConfirm) {
        this.BlockConfirmDialog()
      }
    }
    .width('100%')
    .height('100%')
  }

  /**
   * API26+ 官方沉浸壳：真实 Tabs 单内容承载 ProfileStack，
   * 分段胶囊移入 .tabBar() 槽位（引擎认可其为 TabBar 生效范围），
   * barFloatingStyle 收窄成胶囊 + floatingBar 官方材质 → 官方光感只在胶囊上渲染。
   */
  @Builder
  FloatingTabsShell() {
    Tabs({ barPosition: BarPosition.End }) {
      TabContent() {
        this.ProfileStack()
      }
      .tabBar(this.FloatingSegSlot())
    }
    .width('100%')
    .height('100%')
    .vertical(false)
    .scrollable(false)
    .barOverlap(true)
    .barHeight(74)
    .barBackgroundColor(Color.Transparent)
    .barFloatingStyle({
      barWidth: {
        smallBarWidth: this.pillWidth(),
        mediumBarWidth: this.pillWidth(),
        largeBarWidth: this.pillWidth()
      },
      barBottomMargin: 30,
      systemMaterial: ImmMaterial.floatingBar()
    })
    .backgroundColor(Color.Transparent)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .clip(false)
  }

  /** 兜底壳（API<26 / 材质不支持）：内容层 + 手写悬浮分段胶囊贴底（与历史版本一致） */
  @Builder
  LegacyShell() {
    Stack({ alignContent: Alignment.Bottom }) {
      this.ProfileStack()

      // 底部悬浮分段 Tab（容器高度自适应内容；外层 Stack(Bottom) 自动贴底，
      // margin 避开小白条；容器自身不拦截触摸）
      Column() {
        this.BottomSegTabs()
      }
      .width('100%')
      .hitTestBehavior(HitTestMode.None)
      .zIndex(20)
    }
    .width('100%')
    .height('100%')
  }

  /** 头部：大头像 / 昵称 / ID·性别·IP / 简介 / 关注按钮 / 统计行 */
  @Builder
  Header() {
    Column({ space: Spacing.sm }) {
      if (this.profile && this.profile.avatar.length > 0) {
        Image(this.profile.avatar)
          .width(76)
          .height(76)
          .borderRadius(38)
          .objectFit(ImageFit.Cover)
          .clip(true)
      } else {
        Stack() {
          Text(this.profile && this.profile.name.length > 0 ? this.profile.name.charAt(0) : '?')
            .fontSize(fs(32, this.fontScale))
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.brand())
        }
        .width(76)
        .height(76)
        .borderRadius(38)
        .backgroundColor(Theme.brandBg(this.isDark))
        .border({ width: 1, color: Theme.manualGlassBorder() })
        .alignContent(Alignment.Center)
      }

      Text(this.profile ? this.profile.name : (this.userName.length > 0 ? this.userName : '贴吧用户'))
        .fontSize(fs(18, this.fontScale))
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.textPrimary(this.isDark))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .textAlign(TextAlign.Center)

      Text(this.metaLine())
        .fontSize(fs(13, this.fontScale))
        .fontColor(Theme.textSecondary(this.isDark))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .textAlign(TextAlign.Center)

      if (this.profile && this.profile.intro.length > 0) {
        Text(this.profile.intro)
          .fontSize(fs(13, this.fontScale))
          .fontColor(Theme.textSecondary(this.isDark))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ left: 36, right: 36 })
      }

      Row({ space: 6 }) {
        Text(`关注 ${this.profile?.concernNum ?? 0}`)
          .fontSize(fs(13, this.fontScale))
          .fontColor(Theme.textPrimary(this.isDark))
        Text('·')
          .fontSize(fs(13, this.fontScale))
          .fontColor(Theme.textTertiary(this.isDark))
        Text(`粉丝 ${this.profile?.fansNum ?? 0}`)
          .fontSize(fs(13, this.fontScale))
          .fontColor(Theme.textPrimary(this.isDark))
        Text('·')
          .fontSize(fs(13, this.fontScale))
          .fontColor(Theme.textTertiary(this.isDark))
        Text(`获赞 ${this.profile?.agreeNum ?? 0}`)
          .fontSize(fs(13, this.fontScale))
          .fontColor(Theme.textPrimary(this.isDark))
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .accessibilityText('统计信息')
      // 统计行纯展示，点击无反应（避免误导）
    }
    .width('100%')
    .padding({ left: Spacing.lg, right: Spacing.lg, top: 98 + Spacing.md, bottom: Spacing.md })
  }

  /** 分段 Tab 按钮（两路径共用；无内框版：图标+文字纵向居中，不绘制自身背景/材质/圆角，外框为唯一胶囊） */
  @Builder
  SegButton(label: string, tab: UserTab, icon: Resource) {
    Button({ type: ButtonType.Normal }) {
      Column({ space: 6 }) {
        SymbolGlyph(icon)
          .fontSize(fs(20, this.fontScale))
          // 与首页底部导航选中态一致：选中 icon_emphasize，未选中 icon_primary
          .fontColor([this.activeTab === tab ? $r('sys.color.icon_emphasize') : $r('sys.color.icon_primary')])
        Text(label)
          .fontSize(fs(13, this.fontScale))
          .fontWeight(this.activeTab === tab ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(this.activeTab === tab ? $r('sys.color.font_emphasize') : $r('sys.color.font_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
    }
    .backgroundColor(Color.Transparent)
    .borderRadius(0)
    .stateEffect(false)
    .padding(0)
    .layoutWeight(1)
    .height(62)
      .accessibilityText(label)
      .onClick(() => { this.switchTab(tab); })
  }

  /** API26+ 官方槽位内容：分段胶囊本体（外框不再自绘，由 barFloatingStyle 的官方浮槽材质承担） */
  @Builder
  FloatingSegSlot() {
    Row({ space: 6 }) {
      this.SegButton('发布的帖子', UserTab.Posts, $r('sys.symbol.line_3_horizontal'))
      this.SegButton('关注的吧', UserTab.Likes, $r('sys.symbol.heart'))
    }
    .width('100%')
    .height('100%')
    .padding({ left: 6, right: 6, top: 6, bottom: 6 })
  }

  /** 底部悬浮分段 Tab（API<26 / 材质不支持兜底：手写磨砂玻璃胶囊，由 LegacyShell 底部对齐容器定位；参考首页底部导航） */
  @Builder
  BottomSegTabs() {
    Row({ space: 6 }) {
      this.SegButton('发布的帖子', UserTab.Posts, $r('sys.symbol.line_3_horizontal'))
      this.SegButton('关注的吧', UserTab.Likes, $r('sys.symbol.heart'))
    }
    .width('calc(100% - 48vp)')
    .height(74)
    .padding({ left: 6, right: 6, top: 6, bottom: 6 })
    .backgroundColor(Theme.manualGlass(this.isDark))
    .border({ width: 0.5, color: Theme.manualGlassBorder() })
    .shadow(Theme.glassShadowStyle()).backgroundEffect(ImmBlur.bar())
    .systemMaterial(ImmMaterial.bar())
    .borderRadius(37)
    .shadow({ radius: 24, color: this.isDark ? '#55000000' : '#30101824', offsetY: 8 })
    .margin({ bottom: 30 })
    .zIndex(20)
  }

  // ===== 帖子 Tab 内容 =====

  @Builder
  PostTabContent() {
    Column() {
      if (this.postsState === ProfileLoadState.Loading) {
        ThreadListSkeleton({ count: 5 })
          .width('100%')
          .layoutWeight(1)
      } else if (this.postsState === ProfileLoadState.Error) {
        ErrorView({ message: this.postsError, onRetry: () => { this.loadPostsFirst(); } }).layoutWeight(1)
      } else if (this.postsState === ProfileLoadState.Empty) {
        EmptyView({ message: '还没有发布过主题帖', icon: '📄' }).layoutWeight(1)
      } else {
        List({ space: Spacing.sm, scroller: this.postsScroller }) {
          // 个人信息作为列表第一项，随内容一起滚动；关注的吧 Tab 不渲染 Header
          ListItem() {
            this.Header()
          }
          .width('100%')

          if (this.profileColumns() > 1) {
            // 多列档（§4.11，2026-09-15 用户拍板瀑布流竖 3 / 横 4）：列内独立堆叠（与首页 / §4.12 同款观感）。
            // ⚠️ 列外必须有横排 Row（§4.12 首版漏 Row 的坑）；外层 ForEach 只遍历列索引（key 稳定复用），
            // 内层**直读状态源** `bucketColumns(...)[colIdx]`（不用外层传入 col，否则复用断链不更新）。
            ListItem() {
              Row({ space: 8 }) {
                ForEach(this.profileColIndexes(), (colIdx: number) => {
                  Column({ space: 8 }) {
                    ForEach(this.bucketColumns(this.sortedPosts(), (it: PersonalContentItem) => this.estimateProfilePostCard(it))[colIdx],
                      (item: PersonalContentItem) => {
                        this.PostCard(item)
                      }, (item: PersonalContentItem) => `${item.tid}_${item.id}`)
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)
                }, (colIdx: number) => `pcol_${colIdx}`)
              }
              .width('100%')
              .alignItems(VerticalAlign.Top)
            }
          } else {
            ForEach(this.sortedPosts(), (item: PersonalContentItem) => {
              ListItem() {
                this.PostCard(item)
              }
            }, (item: PersonalContentItem) => `${item.tid}_${item.id}`)
          }
          // 底部占位：把最后一条内容顶上 Tab 上方，占位区滚到底后被 Tab/手势条遮住
          ListItem() {
            Column().width('100%').height(160)
          }
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: Spacing.lg, right: Spacing.lg })
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .onReachEnd(() => { this.loadPostsMore(); })
      }
    }
    .width('100%')
    // 用 layoutWeight(1) 填满 Header 之外的剩余空间，而不是 height('100%')
    // （height 100% 会与 Header 叠加溢出，导致 List 视口延伸到屏幕底部之外）
    .layoutWeight(1)
  }

  /** 帖子卡片：复用 PersonalContent.ContentCard 样式 */
  @Builder
  PostCard(item: PersonalContentItem) {
    Column({ space: 6 }) {
      Text(item.title)
        .fontSize(fs(16, this.fontScale))
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.textPrimary(this.isDark))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
      Text(item.abstract || '暂无摘要')
        .fontSize(fs(13, this.fontScale))
        .fontColor(Theme.textSecondary(this.isDark))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
      Row() {
        Text(item.forumName)
          .fontSize(fs(11, this.fontScale))
          .fontColor(Theme.brand())
        Blank()
        Text(`${item.replyNum} 回复`)
          .fontSize(fs(11, this.fontScale))
          .fontColor(Theme.textTertiary(this.isDark))
        Text(formatTime(item.createTime))
          .fontSize(fs(11, this.fontScale))
          .fontColor(Theme.textTertiary(this.isDark))
          .margin({ left: 8 })
      }
      .width('100%')
    }
    .width('100%')
    .padding(Spacing.lg)
    .backgroundColor(Theme.bgCard(this.isDark))
    // 卡片圆角 26：与首页 ThreadCard、详情页卡片、其余列表页卡片统一（不借用全局 Radius.lg）
    .borderRadius(26)
    .accessibilityText(item.title)
    .onClick(() => {
      // 点击即预取：利用跳转动画窗口后台取详情，详情页打开即命中缓存秒开
      TiebaService.getInstance().prefetchThreadDetail(`${item.tid}`, '');
      this.getUIContext().getRouter().pushUrl({
        url: 'pages/ThreadDetail',
        params: { tid: item.tid, forum: item.forumName }
      }).catch(() => {
      });
    })
  }

  // ===== 关注吧 Tab 内容 =====

  @Builder
  LikeTabContent() {
    if (this.likesState === ProfileLoadState.Loading) {
      ThreadListSkeleton({ count: 5 })
        .width('100%')
        .layoutWeight(1)
        .padding({ top: 98 })
    } else if (this.likesState === ProfileLoadState.Error) {
      ErrorView({ message: this.likesError, onRetry: () => { this.loadLikesFirst(); } })
        .layoutWeight(1)
        .padding({ top: 98 })
    } else if (this.likesState === ProfileLoadState.Empty) {
      EmptyView({ message: '对方隐藏了关注的吧信息', icon: '🫥' })
        .layoutWeight(1)
        .padding({ top: 98 })
    } else {
      List({ space: Spacing.sm, scroller: this.likesScroller }) {
        // 顶部占位：顶栏让位 98 整（与 Header 同源；真机两轮反馈呼吸 md→sm→0 收紧到位）
        ListItem() {
          Column().width('100%').height(98)
        }
        if (this.profileColumns() > 1) {
          // 多列档（§4.11）：关注的吧 3 / 4 列（列内独立堆叠，结构同帖子列表；LikeCard 等高小卡 → 滞回下恒为纯轮转）
          ListItem() {
            Row({ space: 8 }) {
              ForEach(this.profileColIndexes(), (colIdx: number) => {
                Column({ space: 8 }) {
                  ForEach(this.bucketColumns(this.likes, (it: UserLikeItem) => this.estimateProfileLikeCard(it))[colIdx],
                    (item: UserLikeItem) => {
                      this.LikeCard(item)
                    }, (item: UserLikeItem) => item.forumId.length > 0 ? item.forumId : item.forumName)
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
              }, (colIdx: number) => `lcol_${colIdx}`)
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)
          }
        } else {
          ForEach(this.likes, (item: UserLikeItem) => {
            ListItem() {
              this.LikeCard(item)
            }
          }, (item: UserLikeItem) => item.forumId.length > 0 ? item.forumId : item.forumName)
        }
        // 底部占位：把最后一条内容顶上 Tab 上方，占位区滚到底后被 Tab/手势条遮住
        ListItem() {
          Column().width('100%').height(160)
        }
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: Spacing.lg, right: Spacing.lg })
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .onReachEnd(() => { this.loadLikesMore(); })
    }
  }

  /** 吧卡片：吧头像 / 吧名 / 描述（无描述显示帖子数），点击进入吧 */
  @Builder
  LikeCard(item: UserLikeItem) {
    Row({ space: Spacing.md }) {
      if (item.avatar.length > 0) {
        Image(item.avatar)
          .width(48)
          .height(48)
          .borderRadius(Radius.md)
          .objectFit(ImageFit.Cover)
          .clip(true)
      } else {
        Stack() {
          Text(item.forumName.length > 0 ? item.forumName.charAt(0) : '吧')
            .fontSize(fs(20, this.fontScale))
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.brand())
        }
        .width(48)
        .height(48)
        .borderRadius(Radius.md)
        .backgroundColor(Theme.brandBg(this.isDark))
        .alignContent(Alignment.Center)
      }

      Column({ space: 4 }) {
        Text(item.forumName)
          .fontSize(fs(16, this.fontScale))
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textPrimary(this.isDark))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (item.intro.length > 0) {
          Text(item.intro)
            .fontSize(fs(13, this.fontScale))
            .fontColor(Theme.textSecondary(this.isDark))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        } else {
          Text(item.postCount > 0 ? `${item.postCount} 个帖子` : '贴吧')
            .fontSize(fs(13, this.fontScale))
            .fontColor(Theme.textTertiary(this.isDark))
            .maxLines(1)
        }
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
    // 卡片圆角 26：与帖子卡、首页 ThreadCard 统一（不借用全局 Radius.lg）
    .borderRadius(26)
    .accessibilityText(item.forumName)
    .onClick(() => {
      this.getUIContext().getRouter().pushUrl({
        url: 'pages/ThreadList',
        params: { kw: item.forumName, forumName: item.forumName, fid: item.forumId }
      }).catch(() => {
      });
    })
  }

  // ===== 悬浮沉浸顶栏（兜底路径专用：开关关闭 / 低版本才挂载；官方槽位版本见 TopTitleBar）=====

  /**
   * 顶部满宽渐显带（参考收藏页 Favorite.TopFadeBand 真机三次修复终版，2026-09-14）：
   * Stack 顶层满宽背景色渐变条——下层是纯页面背景色，背景色渐变条叠加 = 视觉等价渐隐，
   * 宽度跟随 ProfileStack 全宽，不依赖列表宿主宽度（overlay+blendMode OFFSCREEN 方案在
   * 手机端离屏层宽度解析异常，收藏页已弃用，勿回退）。
   * 高 132 = 顶栏 98 + 渐现尾段 34（收藏页用户拍板口径）；hitTestBehavior(None) 不挡交互；
   * zIndex 8：盖住双页内容，低于兜底 TopBar(10) / 底部分段胶囊(20) / 弹窗(100)，
   * 官方 title 槽位在 Navigation title 层更高。
   * 渐变从顶部即线性渐变、无全实段（[bg,0]→[透明bg,1]）：内容一进条顶就渐显，无硬切感。
   */
  @Builder
  TopFadeBand() {
    Column()
      .width('100%')
      .height(132)
      .linearGradient({
        direction: GradientDirection.Bottom,
        colors: [
          [Theme.bg(this.isDark), 0.0],
          [this.isDark ? '#00101114' : '#00F2F4F7', 1.0]
        ]
      })
      .hitTestBehavior(HitTestMode.None)
      .zIndex(8)
  }

  @Builder
  TopBar() {
    Stack() {
      Row() {
        Button() {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontColor([$r('sys.color.icon_primary')])
            .fontSize(fs(28, this.fontScale))
        }
        .width(44)
        .height(44)
        .backgroundColor(Theme.segGlass(this.isDark, false))
        .border({ width: 0.5, color: Theme.manualGlassBorder() })
        .backgroundBlurStyle(BlurStyle.Thin, { scale: 0.85 })
        .shadow(Theme.segGlassShadow(this.isDark, false))
        .borderRadius(Radius.full)
        .accessibilityText('返回')
        .onClick(() => { this.getUIContext().getRouter().back(); })
        Blank()
        // 排序按钮（仅帖子 Tab；位于黑名单左侧）
        if (this.activeTab === UserTab.Posts) {
          Button() {
            Text('⇅')
              .fontSize(fs(18, this.fontScale))
              .fontColor(Theme.textPrimary(this.isDark))
          }
          .width(44)
          .height(44)
          .backgroundColor(Theme.segGlass(this.isDark, false))
          .border({ width: 0.5, color: Theme.manualGlassBorder() })
          .backgroundBlurStyle(BlurStyle.Thin, { scale: 0.85 })
          .shadow(Theme.segGlassShadow(this.isDark, false))
          .borderRadius(Radius.full)
          .margin({ right: Spacing.sm })
          .accessibilityText('排序')
          .accessibilityDescription(this.postSortMode === PostSortMode.TimeDesc ? '最新时间' : '最早时间')
          .onClick(() => { this.showPostSortMenu = true; })
        }
        // 黑名单按钮（本人隐藏；用系统线性禁止符号 nosign，单色随主题，避免彩色 emoji 突兀）
        if (!this.isSelf()) {
          Button() {
            SymbolGlyph($r('sys.symbol.nosign'))
              .fontSize(fs(20, this.fontScale))
              .fontColor([this.isBlocked ? (Theme.danger() as ResourceColor) : $r('sys.color.icon_primary')])
              .renderingStrategy(SymbolRenderingStrategy.SINGLE)
          }
          .width(44)
          .height(44)
          .backgroundColor(Theme.segGlass(this.isDark, false))
          .border({ width: 0.5, color: Theme.manualGlassBorder() })
          .backgroundBlurStyle(BlurStyle.Thin, { scale: 0.85 })
          .shadow(Theme.segGlassShadow(this.isDark, false))
          .borderRadius(Radius.full)
          .margin({ right: Spacing.sm })
          .accessibilityText(this.isBlocked ? '已加入黑名单' : '加入黑名单')
          .onClick(() => { this.openBlockConfirm(); })
        }
        // 关注按钮（最右侧；未关注黑字，已关注 brand 字）
        if (!this.isSelf()) {
          Button() {
            Text(this.isFollowed ? '已关注 ✓' : '+ 关注')
              .fontSize(fs(14, this.fontScale))
              .fontWeight(FontWeight.Medium)
              .fontColor(this.isFollowed ? $r('sys.color.font_on_primary') : Theme.textPrimary(this.isDark))
          }
          .height(44)
          .padding({ left: 20, right: 20 })
          .backgroundColor(this.isFollowed ? Theme.manualGlass(this.isDark, true) : Theme.segGlass(this.isDark, false))
          .border({ width: 0.5, color: Theme.manualGlassBorder() })
          .backgroundBlurStyle(this.isFollowed ? BlurStyle.Regular : BlurStyle.Thin,
            { scale: this.isFollowed ? 0.8 : 0.85 })
          .shadow(Theme.segGlassShadow(this.isDark, this.isFollowed))
          .borderRadius(Radius.full)
          .accessibilityText(this.isFollowed ? '已关注，点击取消关注' : '关注')
          .onClick(() => { this.requestToggleFollow(); })
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
    .zIndex(10)
  }

  /**
   * 官方槽位标题栏（§6.10 同机制）：返回 44 圆钮 / 排序 44 圆钮（仅帖子 Tab）/ 黑名单 44 圆钮 /
   * 关注胶囊（后两枚本人页隐藏）。
   * 玻璃统一换成 `ImmMaterial.seg(...)`（中性档：关注态 REGULAR、其余 THIN），按坑 24 删除 `segGlass` /
   * `manualGlass` / `manualGlassBorder` / `backgroundBlurStyle` / `segGlassShadow` 全套自绘玻璃；
   * 四个都是 `Button`，补 `backgroundColor(Color.Transparent)` 清默认品牌蓝填充。
   * 关注钮旧写法「已关注 = 品牌蓝底 + 白字」按坑 25 改为「中性材质底 + 可反色文字」：状态感由
   * `seg(true)` 档位 + `Theme.segActiveText()` 承担（与详情页排序胶囊同口径，不引入染色档）。
   * 几何（top 44 / bottom 10 / 左右 Spacing.lg / Row 44 / 圆钮 44 / 关注钮 height 44 + padding 20 /
   * margin-right Spacing.sm）与旧写法逐项一致；旧外壳 `zIndex(10)` 槽内无叠层序需求，去掉。
   */
  @Builder
  TopTitleBar() {
    Row() {
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
      Blank()
      // 排序按钮（仅帖子 Tab；位于黑名单左侧）
      if (this.activeTab === UserTab.Posts) {
        Button() {
          Text('⇅')
            .fontSize(fs(18, this.fontScale))
            .fontColor(Theme.textPrimary(this.isDark))
        }
        .width(44)
        .height(44)
        .backgroundColor(Color.Transparent)
        .systemMaterial(ImmMaterial.seg(false))
        .borderRadius(Radius.full)
        .margin({ right: Spacing.sm })
        .accessibilityText('排序')
        .accessibilityDescription(this.postSortMode === PostSortMode.TimeDesc ? '最新时间' : '最早时间')
        .onClick(() => { this.showPostSortMenu = true; })
      }
      // 黑名单按钮（本人隐藏；用系统线性禁止符号 nosign，单色随主题，避免彩色 emoji 突兀）
      if (!this.isSelf()) {
        Button() {
          SymbolGlyph($r('sys.symbol.nosign'))
            .fontSize(fs(20, this.fontScale))
            .fontColor([this.isBlocked ? (Theme.danger() as ResourceColor) : $r('sys.color.icon_primary')])
            .renderingStrategy(SymbolRenderingStrategy.SINGLE)
        }
        .width(44)
        .height(44)
        .backgroundColor(Color.Transparent)
        .systemMaterial(ImmMaterial.seg(false))
        .borderRadius(Radius.full)
        .margin({ right: Spacing.sm })
        .accessibilityText(this.isBlocked ? '已加入黑名单' : '加入黑名单')
        .onClick(() => { this.openBlockConfirm(); })
      }
      // 关注按钮（最右侧；未关注深字 + THIN，已关注强调字 + REGULAR）
      if (!this.isSelf()) {
        Button() {
          Text(this.isFollowed ? '已关注 ✓' : '+ 关注')
            .fontSize(fs(14, this.fontScale))
            .fontWeight(FontWeight.Medium)
            .fontColor(this.isFollowed ? Theme.segActiveText(this.isDark) : Theme.textPrimary(this.isDark))
        }
        .height(44)
        .padding({ left: 20, right: 20 })
        .backgroundColor(Color.Transparent)
        .systemMaterial(ImmMaterial.seg(this.isFollowed))
        .borderRadius(Radius.full)
        .accessibilityText(this.isFollowed ? '已关注，点击取消关注' : '关注')
        .onClick(() => { this.requestToggleFollow(); })
      }
    }
    .width('100%')
    .padding({ left: Spacing.lg, right: Spacing.lg, top: 44, bottom: 10 })
  }

  // ===== 帖子排序菜单（本地复刻收藏页 SortMenuPanel，2 项）=====

  /**
   * 帖子排序菜单内容（系统 `bindMenu` 的 CustomBuilder）。
   * 原自绘浮层的外壳（全屏遮罩 / `position` / 玻璃自绘 / 弹出动画）已全部交给 `bindMenu`：
   * 定位 → 隐形锚点 + `Placement.BottomRight`；背景 / 圆角 / 描边 / 阴影 → `options.systemMaterial`。
   * 此处只保留菜单项本体（宽度 180、内边距、选中高亮 + ✓ 全部零改动）。
   */
  @Builder
  PostSortMenuContent() {
    Column({ space: 2 }) {
      this.PostSortMenuItem(PostSortMode.TimeDesc, '最新时间')
      this.PostSortMenuItem(PostSortMode.TimeAsc, '最早时间')
    }
    .padding({ top: 6, bottom: 6 })
  }

  @Builder
  PostSortMenuItem(mode: PostSortMode, label: string) {
    Row({ space: 10 }) {
      Text(label)
        .fontSize(fs(14, this.fontScale))
        .fontColor(this.postSortMode === mode ? Theme.brand() : Theme.textPrimary(this.isDark))
        .layoutWeight(1)
      if (this.postSortMode === mode) {
        Text('✓')
          .fontSize(fs(13, this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.brand())
      }
    }
    .width(180)
    .padding({ left: 16, right: 16, top: 13, bottom: 13 })
    .borderRadius(Radius.md)
    .onClick(() => { this.applyPostSort(mode); })
  }

  // ===== 确认弹窗（复用收藏页居中卡片浮层范式：暗蒙层 + 磨砂玻璃卡）=====

  /** 取消关注确认（已关注再点击，防误触） */
  @Builder
  UnfollowConfirmDialog() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#06000000')
        .onClick(() => { this.showUnfollowConfirm = false; })
        .transition(TransitionEffect.opacity(0).animation({ duration: 180, curve: Curve.EaseOut }))

      Column() {
        Column({ space: 6 }) {
          Text('取消关注')
            .fontSize(fs(17, this.fontScale))
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.textPrimary(this.isDark))
            .textAlign(TextAlign.Center)
          Text(`取消关注「${this.profile?.name ?? this.userName}」？`)
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
          .onClick(() => { this.showUnfollowConfirm = false; })

          Button() {
            Text('取消关注')
              .fontSize(fs(15, this.fontScale))
              .fontColor(Color.White)
              .fontWeight(FontWeight.Medium)
          }
          .layoutWeight(1)
          .height(44)
          .backgroundColor(Theme.brand())
          .borderRadius(Radius.full)
          .accessibilityText('确认取消关注')
          .onClick(() => { this.confirmUnfollow(); })
        }
        .width('100%')
        .padding({ left: Spacing.lg, right: Spacing.lg, bottom: Spacing.lg })
      }
      // 弹窗不拉伸（2026-09-15 拍板）：T-H 同款 max(200, min(400, 屏宽−48))，手机档 312 逐像素不变
      .width(this.panelWidth())
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

  /** 拉黑开关单行（标题 + 副说明 + 右侧 Toggle） */
  @Builder
  BlockSwitchRow(title: string, subtitle: string, isOn: boolean, onChange: (on: boolean) => void) {
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

  /** 拉黑确认（危险操作红色分组） */
  @Builder
  BlockConfirmDialog() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#06000000')
        .onClick(() => { this.closeBlockConfirm(); })
        .transition(TransitionEffect.opacity(0).animation({ duration: 180, curve: Curve.EaseOut }))

      Column() {
        Column({ space: 6 }) {
          Text('加入黑名单')
            .fontSize(fs(17, this.fontScale))
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.danger())
            .textAlign(TextAlign.Center)
          Text(`确定将「${this.profile?.name ?? this.userName}」加入黑名单吗？可分别设置禁止私信、关注与互动。`)
            .fontSize(fs(13, this.fontScale))
            .fontColor(Theme.textSecondary(this.isDark))
            .lineHeight(fs(18, this.fontScale))
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        .padding({ left: Spacing.lg, right: Spacing.lg, top: Spacing.lg, bottom: Spacing.md })

        Column({ space: 4 }) {
          this.BlockSwitchRow('禁止私信', '开启后对方无法给你发私信', this.blockChat, (on: boolean) => { this.blockChat = on; })
          this.BlockSwitchRow('禁止关注', '开启后对方无法关注你', this.blockFollow, (on: boolean) => { this.blockFollow = on; })
          this.BlockSwitchRow('禁止互动', '开启后对方无法评论、点赞、转发、@你', this.blockInteract, (on: boolean) => { this.blockInteract = on; })
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
          .onClick(() => { this.closeBlockConfirm(); })

          Button() {
            Text(this.blockBusy ? '处理中...' : '加入黑名单')
              .fontSize(fs(15, this.fontScale))
              .fontColor(Color.White)
              .fontWeight(FontWeight.Medium)
          }
          .layoutWeight(1)
          .height(44)
          .backgroundColor(Theme.danger())
          .borderRadius(Radius.full)
          .accessibilityText('确认加入黑名单')
          .onClick(() => { this.confirmBlock(); })
        }
        .width('100%')
        .padding({ left: Spacing.lg, right: Spacing.lg, bottom: Spacing.lg })
      }
      // 弹窗不拉伸（2026-09-15 拍板）：T-H 同款 max(200, min(400, 屏宽−48))，手机档 312 逐像素不变
      .width(this.panelWidth())
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
