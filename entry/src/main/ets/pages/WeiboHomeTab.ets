import { WEIBO_TAP_MAX_MOVEMENT } from '../common/WeiboTabSwipe';
import { WeiboReadingPositionManager, WeiboTimelinePosition } from '../service/WeiboReadingPositionManager';
import { common } from '@kit.AbilityKit';
import { curves } from '@kit.ArkUI';
import { ThreadCard, ThreadItemData, ThreadSharePayload, EmptyView, ErrorView } from '../components/CommonComponents';
import { ThreadListSkeleton } from '../components/Skeleton';
import { Breakpoint, CARD_COLUMNS_KEY, ImmBlur, ImmMaterial, Radius, Spacing, Theme, fs, isDarkMode, isLargeScreenForm, isPuraXMaxDevice, isWideFormDevice as detectWideFormDevice, overrideColumns, readColumnMode } from '../common/Theme';
import { WeiboComment, WeiboDetailTab, WeiboPost, WeiboTimelinePage, WeiboUser } from '../model/WeiboModel';
import { WeiboAuthManager } from '../service/WeiboAuthManager';
import { WeiboService, sanitizeHttpsUrl } from '../service/WeiboService';
import { withWeiboFollow, withWeiboLike } from '../common/WeiboPostState';
import { ShareUtil } from '../common/ShareUtil';
import { Haptic } from '../common/Haptic';
import { WeiboComposeDialog } from '../components/WeiboComposeDialog';
import { WeiboRichTextView } from '../components/WeiboRichTextView';
import { WeiboSearchResultRouteParam } from './WeiboSearchResult';

/** Lazy WaterFlow data source: refreshes reload every card while paged results append only their tail. */
class WeiboPostDataSource implements IDataSource {
  private listeners: DataChangeListener[] = [];
  public data: WeiboPost[] = [];

  totalCount(): number {
    return this.data.length;
  }

  getData(index: number): WeiboPost {
    return this.data[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const index: number = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }

  reload(): void {
    for (let index: number = 0; index < this.listeners.length; index++) {
      this.listeners[index].onDataReloaded();
    }
  }

  notifyAdd(start: number): void {
    for (let index: number = 0; index < this.listeners.length; index++) {
      this.listeners[index].onDataAdd(start);
    }
  }
}

enum TimelineState {
  Idle = 0,
  Loading = 1,
  Success = 2,
  Empty = 3,
  Error = 4,
}

export enum WeiboTimelineMode {
  Recommend = 0,
  Following = 1,
}

type TabAnimationDirection = 'left' | 'right';

/**
 * Fluo 首页信息流层级与动态卡片。
 */
@Component
export struct WeiboHomeTab {
  @Prop mode: WeiboTimelineMode = WeiboTimelineMode.Recommend;
  @Prop showHeader: boolean = true;
  @Prop @Watch('onEnter') animationTrigger: number = 0;
  @Prop @Watch('onExit') exitTrigger: number = 0;
  @Prop @Watch('onRefreshTrigger') refreshTrigger: number = 0;
  /** The shell owns this scroller so HDS can natively hide its floating Dock while the feed moves. */
  pageScroller: Scroller = new Scroller();
  onScrollDirection: (visible: boolean) => void = () => {};
  /** Reserved in the scroll content, so floating host chrome never shrinks the scroll viewport. */
  @Prop topInset: number = 0;
  @Prop bottomInset: number = 116;
  onOpenPost: (post: WeiboPost, tab?: WeiboDetailTab, autoFocusComment?: boolean, targetCommentId?: string) => void = () => {};
  onOpenUserProfile: (userId: string, userName: string) => void = () => {};
  @State isDark: boolean = isDarkMode();
  @State userIdDraft: string = '';
  @State profile: WeiboUser | null = null;
  @State @Watch('onPostsChange') posts: WeiboPost[] = [];
  @StorageLink('weibo_sync_like') @Watch('onGlobalLikeSync') globalLikeSync: string = '';
  @StorageLink('weibo_sync_follow') @Watch('onGlobalFollowSync') globalFollowSync: string = '';

  private onGlobalLikeSync(): void {
    if (!this.globalLikeSync) { return; }
    const parts: string[] = this.globalLikeSync.split(':');
    if (parts.length >= 2) {
      const postId: string = parts[0];
      const liked: boolean = parts[1] === 'true';
      let changed: boolean = false;
      const updated: WeiboPost[] = this.posts.map((p: WeiboPost): WeiboPost => {
        if (p.id === postId && p.isLiked !== liked) {
          changed = true;
          return this.copyPostWithLike(p, liked);
        }
        return p;
      });
      if (changed) {
        this.posts = updated;
      }
    }
  }

  private onGlobalFollowSync(): void {
    if (!this.globalFollowSync) { return; }
    const parts: string[] = this.globalFollowSync.split(':');
    if (parts.length >= 2) {
      const userId: string = parts[0];
      const followed: boolean = parts[1] === 'true';
      let changed: boolean = false;
      const updated: WeiboPost[] = this.posts.map((p: WeiboPost): WeiboPost => {
        if (p.userId === userId && p.isFollowed !== followed) {
          changed = true;
          return withWeiboFollow(p, followed);
        }
        return p;
      });
      if (changed) {
        this.posts = updated;
      }
    }
  }
  @State timelineState: TimelineState = TimelineState.Idle;
  @State errorMessage: string = '';
  @State currentPage: number = 1;
  /** Desktop friends feed uses this opaque cursor rather than numbered pages. */
  @State followingMaxId: string = '0';
  @State loadingMore: boolean = false;
  @State likingPostIds: string[] = [];
  private timelineEpoch: number = 0;
  @Consume('weiboNavStack') weiboNavStack: NavPathStack;
  @State refreshing: boolean = false;
  /** Refresh's two-way binding may set refreshing before onRefreshing fires. */
  private refreshInFlight: boolean = false;
  @State hasMore: boolean = true;
  @State viewportWidth: number = 0;
  @State viewportHeight: number = 0;
  @State pageTranslateX: number = 0;
  @State pageOpacity: number = 1;
  @State isAnimating: boolean = false;
  /** Device capability gate for large-screen feeds. */
  private readonly isWideFormDevice: boolean = detectWideFormDevice();
  @State timelineDataSource: WeiboPostDataSource = new WeiboPostDataSource();
  @State newPostsAvailableCount: number = 0;
  @State newPostsPending: WeiboPost[] = [];
  private currentFirstVisibleIndex: number = 0;
  private currentTopPostId: string = '';
  private currentScrollYOffset: number = 0;
  private isRestoringPosition: boolean = false;
  private restoreTimeoutId: number = -1;
  @StorageLink('fontScale') fontScale: number = 1.0;
  @StorageLink('darkTick') @Watch('onDarkTick') darkTick: number = 0;
  @StorageLink('weiboAuthTick') @Watch('onWeiboAuthTick') weiboAuthTick: number = 0;
  @StorageLink('columnMode') columnMode: number = 0;
  @StorageLink('columnModeTick') @Watch('onColumnModeTick') columnModeTick: number = 0;

  async aboutToAppear(): Promise<void> {
    // This runs beside local auth initialization; it does not transfer feed data.
    WeiboService.getInstance().preconnectTimeline();
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    await WeiboAuthManager.getInstance().init(context);
    this.userIdDraft = WeiboAuthManager.getInstance().getTargetUserId();
    this.columnMode = readColumnMode();
    this.syncCardColumns();
    if (this.mode === WeiboTimelineMode.Recommend || this.mode === WeiboTimelineMode.Following || this.userIdDraft.trim().length > 0) {
      await this.initTimelineWithPosition();
    }
  }

  aboutToDisappear(): void {
    WeiboReadingPositionManager.getInstance().flush();
  }

  private onDarkTick(): void {
    this.isDark = isDarkMode();
  }

  /** Page replacement reloads, pagination appends. */
  private onPostsChange(): void {
    const previous: WeiboPost[] = this.timelineDataSource.data;
    let isAppend: boolean = previous.length > 0 && this.posts.length > previous.length;
    if (isAppend) {
      for (let index: number = 0; index < previous.length; index++) {
        if (previous[index].id !== this.posts[index].id) {
          isAppend = false;
          break;
        }
      }
    }
    this.timelineDataSource.data = this.posts;
    if (isAppend) {
      this.timelineDataSource.notifyAdd(previous.length);
    } else {
      this.timelineDataSource.reload();
    }
  }

  private onColumnModeTick(): void {
    this.columnMode = readColumnMode();
    this.syncCardColumns();
    if (this.currentFirstVisibleIndex > 0) {
      try {
        this.pageScroller.scrollToIndex(this.currentFirstVisibleIndex, false, ScrollAlign.START);
      } catch (error) {
      }
    }
  }

  /** Normal single-column feed for phones; large screen tablets adapt gracefully. */
  private waterfallColumns(): number {
    if (this.viewportWidth <= 0 || this.viewportHeight <= 0) {
      return 1;
    }
    const landscape: boolean = this.viewportWidth > this.viewportHeight;
    if (this.viewportWidth >= Breakpoint.sm && isLargeScreenForm(this.isWideFormDevice)) {
      const override: number = overrideColumns(this.columnMode, landscape);
      if (override > 0) {
        return override;
      }
      return landscape ? 2 : 1;
    }
    return 1;
  }

  private waterfallColumnsTemplate(): string {
    const columns: number = this.waterfallColumns();
    if (columns === 2) {
      return '1fr 1fr';
    }
    return '1fr';
  }

  /** Lets ThreadCard tune image geometry and text density to the active waterfall column count. */
  private syncCardColumns(): void {
    AppStorage.setOrCreate<number>(CARD_COLUMNS_KEY, this.waterfallColumns());
  }

  private animationDirection(): TabAnimationDirection {
    const storedDirection: string | undefined = AppStorage.get<string>('animationDirection');
    return storedDirection === 'right' ? 'right' : 'left';
  }

  private onEnter(): void {
    if (this.animationTrigger > 0) {
      this.isAnimating = false;
      this.playEnterAnimation(this.animationDirection());
    }
  }

  private onExit(): void {
    if (this.exitTrigger > 0) {
      this.playExitAnimation(this.animationDirection());
    }
  }

  private onRefreshTrigger(): void {
    if (this.refreshTrigger > 0) {
      this.refreshFeed();
    }
  }

  private currentAccountKey(): string {
    if (WeiboAuthManager.getInstance().hasCookie()) {
      const user: WeiboUser | null = WeiboService.getInstance().getCachedCurrentUser();
      if (user !== null && user.id.length > 0) {
        return user.id;
      }
      const authUid: string = WeiboAuthManager.getInstance().getCurrentUserId();
      if (authUid.length > 0) {
        return authUid;
      }
      const targetId: string = WeiboAuthManager.getInstance().getTargetUserId();
      return targetId.length > 0 ? targetId : 'logged_in';
    }
    return 'guest';
  }

  private scheduleSavePosition(): void {
    if (this.posts.length === 0 || this.timelineState !== TimelineState.Success) {
      return;
    }
    WeiboReadingPositionManager.getInstance().savePosition({
      mode: this.mode,
      accountKey: this.currentAccountKey(),
      topPostId: this.currentTopPostId,
      topIndex: this.currentFirstVisibleIndex,
      yOffset: this.currentScrollYOffset,
      updatedAt: Date.now(),
      posts: this.posts,
      currentPage: this.currentPage,
      hasMore: this.hasMore,
      followingMaxId: this.followingMaxId
    });
  }

  private async initTimelineWithPosition(): Promise<void> {
    const saved: WeiboTimelinePosition | null = await WeiboReadingPositionManager.getInstance()
      .getPosition(this.currentAccountKey(), this.mode);
    if (saved !== null && saved.posts.length > 0) {
      this.isRestoringPosition = true;
      this.posts = saved.posts;
      this.currentPage = saved.currentPage;
      this.hasMore = saved.hasMore;
      if (this.mode === WeiboTimelineMode.Following && saved.followingMaxId) {
        this.followingMaxId = saved.followingMaxId;
      }
      let targetIndex: number = saved.topIndex;
      if (saved.topPostId && saved.topPostId.length > 0) {
        const foundIndex: number = saved.posts.findIndex((p: WeiboPost): boolean => p.id === saved.topPostId);
        if (foundIndex >= 0) {
          targetIndex = foundIndex;
        }
      }
      this.currentFirstVisibleIndex = targetIndex;
      this.currentTopPostId = saved.topPostId;
      this.currentScrollYOffset = saved.yOffset;
      this.timelineState = TimelineState.Success;
      if (typeof setTimeout !== 'undefined') {
        this.restoreTimeoutId = setTimeout((): void => {
          if (targetIndex > 0) {
            try {
              this.pageScroller.scrollToIndex(targetIndex, false, ScrollAlign.START);
            } catch (error) {
            }
          }
          this.isRestoringPosition = false;
        }, 150);
      } else {
        this.isRestoringPosition = false;
      }
      this.checkForNewPosts();
      return;
    }
    await this.loadFirstPage();
  }

  private async checkForNewPosts(): Promise<void> {
    try {
      let fresh: WeiboPost[] = [];
      if (this.mode === WeiboTimelineMode.Recommend) {
        fresh = await WeiboService.getInstance().fetchRecommendTimeline(1);
      } else if (this.mode === WeiboTimelineMode.Following) {
        const page: WeiboTimelinePage = await WeiboService.getInstance().fetchFollowingTimeline('0');
        fresh = page.items;
      }
      if (fresh.length > 0 && this.posts.length > 0) {
        const newItems: WeiboPost[] = fresh.filter((p: WeiboPost): boolean =>
          !this.posts.some((existing: WeiboPost): boolean => existing.id === p.id)
        );
        if (newItems.length > 0) {
          this.newPostsPending = newItems;
          this.newPostsAvailableCount = newItems.length;
        }
      }
    } catch (e) {
      // Background check error is non-fatal
    }
  }

  private applyNewPosts(): void {
    if (this.newPostsPending.length > 0) {
      const merged: WeiboPost[] = this.newPostsPending.concat(
        this.posts.filter((p: WeiboPost): boolean => !this.newPostsPending.some((n: WeiboPost): boolean => n.id === p.id))
      );
      this.posts = merged;
      this.newPostsPending = [];
      this.newPostsAvailableCount = 0;
      this.currentFirstVisibleIndex = 0;
      if (this.posts.length > 0) {
        this.currentTopPostId = this.posts[0].id;
      }
      this.currentScrollYOffset = 0;
      this.timelineDataSource.data = this.posts;
      this.timelineDataSource.reload();
      try {
        this.pageScroller.scrollToIndex(0, true, ScrollAlign.START);
      } catch (error) {
      }
      this.scheduleSavePosition();
    } else {
      this.refreshFeed();
    }
  }

  private async refreshFeed(): Promise<void> {
    if (this.refreshInFlight) {
      return;
    }
    this.refreshInFlight = true;
    this.refreshing = true;
    try {
      await this.loadFirstPage(true);
    } finally {
      this.refreshInFlight = false;
      this.refreshing = false;
      this.currentFirstVisibleIndex = 0;
      if (this.posts && this.posts.length > 0) {
        this.currentTopPostId = this.posts[0].id;
      }
      this.currentScrollYOffset = 0;
      this.scheduleSavePosition();
      if (typeof setTimeout !== 'undefined') {
        setTimeout(() => {
          try {
            this.pageScroller.scrollToIndex(0, false, ScrollAlign.START);
          } catch (error) {
          }
          try {
            this.pageScroller.scrollEdge(Edge.Top);
          } catch (error) {
          }
        }, 100);
        setTimeout(() => {
          try {
            this.pageScroller.scrollToIndex(0, false, ScrollAlign.START);
          } catch (error) {
          }
        }, 300);
      }
    }
  }

  private playExitAnimation(direction: TabAnimationDirection): void {
    if (this.isAnimating) {
      return;
    }
    this.isAnimating = true;
    const endX: number = direction === 'left' ? -350 : 350;
    this.getUIContext().animateTo({
      duration: 250,
      curve: Curve.EaseIn,
      onFinish: (): void => { this.isAnimating = false; }
    }, (): void => {
      this.pageTranslateX = endX;
      this.pageOpacity = 0;
    });
  }

  private playEnterAnimation(direction: TabAnimationDirection): void {
    if (this.isAnimating) {
      return;
    }
    this.isAnimating = true;
    const startX: number = direction === 'left' ? 350 : -350;
    this.pageTranslateX = startX;
    this.pageOpacity = 0;
    setTimeout((): void => {
      this.getUIContext().animateTo({ duration: 300, curve: curves.springMotion() }, (): void => {
        this.pageTranslateX = 0;
        this.pageOpacity = 1;
      });
    }, 0);
    setTimeout((): void => { this.isAnimating = false; }, 600);
  }

  /** A successful in-app login happens on a routed page. Reload both retained
   * timeline tabs when it returns so users do not have to recreate the page. */
  private onWeiboAuthTick(): void {
    this.posts = [];
    this.profile = null;
    this.loadingMore = false;
    this.refreshing = false;
    this.likingPostIds = [];
    this.loadFirstPage();
  }

  /**
   * Pull-to-refresh keeps the current recommendation cards visible until the
   * fresh first page arrives. Initial loading and explicit retry still use the
   * full loading state.
   */
  private async loadFirstPage(preserveCurrentContent: boolean = false): Promise<void> {
    const epoch: number = ++this.timelineEpoch;
    if (this.mode === WeiboTimelineMode.Recommend || this.mode === WeiboTimelineMode.Following) {
      const keepCurrentContent: boolean = preserveCurrentContent
        && this.timelineState === TimelineState.Success
        && this.posts.length > 0;
      if (!keepCurrentContent) {
        this.timelineState = TimelineState.Loading;
      }
      this.errorMessage = '';
      try {
        let result: WeiboPost[] = [];
        let more: boolean = false;
        if (this.mode === WeiboTimelineMode.Recommend) {
          result = await WeiboService.getInstance().fetchRecommendTimeline(1);
          more = result.length > 0;
        } else {
          const followingPage: WeiboTimelinePage = await WeiboService.getInstance().fetchFollowingTimeline('0');
          if (epoch !== this.timelineEpoch) { return; }
          result = followingPage.items;
          this.followingMaxId = followingPage.nextMaxId;
          more = followingPage.hasMore;
        }
        if (epoch !== this.timelineEpoch) { return; }
        this.posts = result;
        this.currentPage = 1;
        this.hasMore = more;
        this.newPostsPending = [];
        this.newPostsAvailableCount = 0;
        this.timelineState = result.length > 0 ? TimelineState.Success : TimelineState.Empty;
        this.currentFirstVisibleIndex = 0;
        if (result.length > 0) {
          this.currentTopPostId = result[0].id;
        }
        this.currentScrollYOffset = 0;
        this.scheduleSavePosition();
      } catch (error) {
        if (epoch !== this.timelineEpoch) { return; }
        this.errorMessage = (error as Error).message ?? '推荐微博加载失败，请稍后重试';
        if (keepCurrentContent) {
          this.getUIContext().getPromptAction().showToast({ message: this.errorMessage });
          return;
        }
        this.posts = [];
        this.timelineState = TimelineState.Error;
      }
      return;
    }
    const userId: string = this.userIdDraft.trim();
    if (userId.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.weibo_missing_user_id') });
      return;
    }
    this.timelineState = TimelineState.Loading;
    this.errorMessage = '';
    try {
      await WeiboAuthManager.getInstance().setTargetUserId(userId);
      const service: WeiboService = WeiboService.getInstance();
      const profile: WeiboUser = await service.fetchUserProfile(userId);
      if (epoch !== this.timelineEpoch) { return; }
      const result: WeiboPost[] = await service.fetchUserTimeline(userId, 1);
      if (epoch !== this.timelineEpoch) { return; }
      this.profile = profile;
      this.posts = result;
      this.currentPage = 1;
      this.hasMore = result.length > 0;
      this.timelineState = result.length > 0 ? TimelineState.Success : TimelineState.Empty;
      this.currentFirstVisibleIndex = 0;
      if (result.length > 0) {
        this.currentTopPostId = result[0].id;
      }
      this.currentScrollYOffset = 0;
      this.scheduleSavePosition();
    } catch (error) {
      if (epoch !== this.timelineEpoch) { return; }
      this.profile = null;
      this.posts = [];
      this.errorMessage = (error as Error).message ?? '微博加载失败，请稍后重试';
      this.timelineState = TimelineState.Error;
    }
  }

  private async loadMore(): Promise<void> {
    if (this.loadingMore || !this.hasMore || this.timelineState !== TimelineState.Success) {
      return;
    }
    const userId: string = this.userIdDraft.trim();
    if (this.mode !== WeiboTimelineMode.Recommend && this.mode !== WeiboTimelineMode.Following && userId.length === 0) {
      return;
    }
    const epoch: number = this.timelineEpoch;
    this.loadingMore = true;
    try {
      const nextPage: number = this.currentPage + 1;
      let result: WeiboPost[] = [];
      let more: boolean = false;
      if (this.mode === WeiboTimelineMode.Recommend) {
        result = await WeiboService.getInstance().fetchRecommendTimeline(nextPage);
        more = result.length > 0;
      } else if (this.mode === WeiboTimelineMode.Following) {
        const followingPage: WeiboTimelinePage = await WeiboService.getInstance()
          .fetchFollowingTimeline(this.followingMaxId);
        if (epoch !== this.timelineEpoch) { return; }
        result = followingPage.items;
        this.followingMaxId = followingPage.nextMaxId;
        more = followingPage.hasMore;
      } else {
        result = await WeiboService.getInstance().fetchUserTimeline(userId, nextPage);
        more = result.length > 0;
      }
      if (epoch !== this.timelineEpoch) { return; }
      const added: WeiboPost[] = result.filter((item: WeiboPost): boolean => !this.posts.some((old: WeiboPost): boolean => old.id === item.id));
      if (added.length > 0) {
        this.posts = this.posts.concat(added);
        this.currentPage = nextPage;
        this.hasMore = more;
        this.scheduleSavePosition();
      } else {
        this.hasMore = false;
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.weibo_empty') });
      }
    } catch (error) {
      if (epoch !== this.timelineEpoch) { return; }
      this.errorMessage = (error as Error).message ?? '微博加载失败，请稍后重试';
      this.getUIContext().getPromptAction().showToast({ message: this.errorMessage });
    } finally {
      if (epoch === this.timelineEpoch) { this.loadingMore = false; }
    }
  }

  private toThreadCard(post: WeiboPost): ThreadItemData {
    const original: WeiboPost | null = post.repost;
    const mediaPost: WeiboPost = (post.pictures.length > 0 || post.videoUrl.length > 0 || original === null)
      ? post : original;
    const firstImage: string = mediaPost.pictures.length > 0 ? mediaPost.pictures[0] : '';
    const titleText: string = post.text.length > 0 ? post.text : post.userName;
    return {
      tid: post.id,
      postId: post.id,
      forumId: '',
      title: titleText,
      forumName: post.source.length > 0 ? post.source : '微博',
      forumAvatar: '',
      author: post.userName,
      authorId: post.userId,
      authorAvatar: post.userAvatar,
      replyNum: post.commentCount,
      likeCount: post.likeCount,
      isLiked: post.isLiked,
      abstract: original === null ? '' : original.text,
      repostAuthor: original === null ? '' : original.userName,
      isSocialPost: true,
      firstImage: firstImage,
      images: mediaPost.pictures,
      videoUrl: mediaPost.videoUrl,
      videoCoverUrl: mediaPost.videoCoverUrl,
      createTime: post.createdAt,
      isTop: false,
      isGood: false,
    };
  }

  private openPost(post: WeiboPost, tab?: WeiboDetailTab, autoFocusComment?: boolean, targetCommentId?: string): void {
    if (post.id.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.weibo_post_unavailable') });
      return;
    }
    this.onOpenPost(post, tab, autoFocusComment, targetCommentId);
  }

  private openOriginalPost(post: WeiboPost): void {
    const original: WeiboPost | null = post.repost;
    if (original === null || original.id.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.weibo_post_unavailable') });
      return;
    }
    this.openPost(original);
  }

  private openUserProfile(userId: string, userName: string): void {
    const id: string = typeof userId === 'string' ? userId.trim() : '';
    const name: string = typeof userName === 'string' ? userName.trim() : '';
    if (id.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.weibo_profile_unavailable') });
      return;
    }
    this.onOpenUserProfile(id, name);
  }

  private openImagePreview(urls: string[], index: number): void {
    if (urls.length === 0) {
      return;
    }
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/ImagePreview',
      params: { urls: urls, index: index }
    }).catch((): void => {
      this.getUIContext().getPromptAction().showToast({ message: '原图预览打开失败，请稍后重试' });
    });
  }

  private onShare(data: ThreadSharePayload): void {
    const url: string = `https://m.weibo.cn/detail/${data.tid}`;
    const abstract: string = data.abstract.length > 0 ? data.abstract : data.title;
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    ShareUtil.shareLink(this.getUIContext(), context, url, data.author, abstract);
  }

  private copyPostWithLike(post: WeiboPost, liked: boolean): WeiboPost {
    return {
      id: post.id,
      userId: post.userId,
      userName: post.userName,
      userAvatar: post.userAvatar,
      text: post.text,
      isLongText: post.isLongText,
      pictures: post.pictures,
      pictureVideos: post.pictureVideos,
      isFavorited: post.isFavorited, isFollowed: post.isFollowed,
      videoAspectRatio: post.videoAspectRatio,
      videoUrl: post.videoUrl,
      videoCoverUrl: post.videoCoverUrl,
      createdAt: post.createdAt,
      source: post.source,
      likeCount: liked ? post.likeCount + 1 : Math.max(0, post.likeCount - 1),
      commentCount: post.commentCount,
      repostCount: post.repostCount,
      isLiked: liked,
      repost: post.repost,
      hotComment: post.hotComment,
    };
  }

  private async toggleLike(post: WeiboPost, liked: boolean): Promise<void> {
    if (this.likingPostIds.includes(post.id)) { return; }
    const revision: number = WeiboAuthManager.getInstance().getSessionRevision();
    this.likingPostIds = this.likingPostIds.concat([post.id]);
    try {
      Haptic.light();
      await WeiboService.getInstance().setLike(post.id, liked);
      WeiboAuthManager.getInstance().assertSession(revision);
      const updated: WeiboPost[] = [];
      for (let index: number = 0; index < this.posts.length; index++) {
        const item: WeiboPost = this.posts[index];
        updated.push(item.id === post.id ? this.copyPostWithLike(item, liked) : item);
      }
      this.posts = updated;
      this.getUIContext().getPromptAction().showToast({
        message: liked ? $r('app.string.weibo_like_success') : $r('app.string.weibo_unlike_success')
      });
    } catch (error) {
      if (revision !== WeiboAuthManager.getInstance().getSessionRevision()) { return; }
      const message: string = (error as Error).message ?? '微博操作失败';
      this.getUIContext().getPromptAction().showToast({ message: message });
    } finally {
      if (revision === WeiboAuthManager.getInstance().getSessionRevision()) {
        this.likingPostIds = this.likingPostIds.filter((id: string): boolean => id !== post.id);
      }
    }
  }

  private openTopic(topic: string): void {
    const param: WeiboSearchResultRouteParam = { query: topic };
    this.weiboNavStack.pushPath({ name: 'WeiboSearchResult', param: param });
  }

  @Builder
  Header() {
    Row() {
      // 左侧头像
      Stack() {
        SymbolGlyph($r('sys.symbol.person'))
          .fontSize(fs(24, this.fontScale))
          .fontColor([Theme.brand()])
        if (this.profile !== null && this.profile.avatarUrl.length > 0) {
          Image(sanitizeHttpsUrl(this.profile.avatarUrl))
            .width(36)
            .height(36)
            .borderRadius(18)
            .objectFit(ImageFit.Cover)
        }
      }
      .width(36)
      .height(36)
      .alignContent(Alignment.Center)
      .borderRadius(18)
      .backgroundColor(this.isDark ? 'rgba(255, 255, 255, 0.08)' : 'rgba(0, 0, 0, 0.04)')

      Blank()

      // 中间胶囊分段 (关注 / 推荐)
      Row({ space: 4 }) {
        Text($r('app.string.weibo_following_title'))
          .fontSize(fs(13, this.fontScale))
          .fontWeight(this.mode === WeiboTimelineMode.Following ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(this.mode === WeiboTimelineMode.Following ? Color.White : Theme.textSecondary(this.isDark))
          .backgroundColor(this.mode === WeiboTimelineMode.Following ? Theme.brand() : Color.Transparent)
          .borderRadius(16)
          .padding({ left: 14, right: 14, top: 6, bottom: 6 })
          .shadow(this.mode === WeiboTimelineMode.Following
            ? { radius: 8, color: 'rgba(78, 170, 120, 0.35)', offsetY: 2 } : { radius: 0, color: '#00000000' })
          .onClick(() => { this.loadFirstPage(); })

        Text($r('app.string.weibo_recommend_title'))
          .fontSize(fs(13, this.fontScale))
          .fontWeight(this.mode === WeiboTimelineMode.Recommend ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(this.mode === WeiboTimelineMode.Recommend ? Color.White : Theme.textSecondary(this.isDark))
          .backgroundColor(this.mode === WeiboTimelineMode.Recommend ? Theme.brand() : Color.Transparent)
          .borderRadius(16)
          .padding({ left: 14, right: 14, top: 6, bottom: 6 })
          .shadow(this.mode === WeiboTimelineMode.Recommend
            ? { radius: 8, color: 'rgba(78, 170, 120, 0.35)', offsetY: 2 } : { radius: 0, color: '#00000000' })
          .onClick(() => { this.loadFirstPage(); })
      }
      .padding(3)
      .borderRadius(20)
      .backgroundColor(this.isDark ? 'rgba(255, 255, 255, 0.08)' : 'rgba(0, 0, 0, 0.05)')

      Blank()

      // 右侧加号按钮
      Button() {
        SymbolGlyph($r('sys.symbol.plus'))
          .fontSize(fs(18, this.fontScale))
          .fontColor([Theme.textPrimary(this.isDark)])
      }
      .width(36)
      .height(36)
      .backgroundColor(this.isDark ? 'rgba(255, 255, 255, 0.08)' : 'rgba(0, 0, 0, 0.04)')
      .borderRadius(18)
      .accessibilityText('发微博')
      .onClick(() => { this.openComposeDialog(); })
    }
    .width('100%')
    .padding({ top: 52, left: Spacing.lg, right: Spacing.lg, bottom: Spacing.md })
    .backgroundColor(Theme.bg(this.isDark))
  }

  private socialMediaPost(post: WeiboPost): WeiboPost {
    if (post.pictures.length > 0 || post.videoCoverUrl.length > 0 || post.videoUrl.length > 0 || post.repost === null) {
      return post;
    }
    return post.repost;
  }

  private socialCoverUrl(post: WeiboPost): string {
    const media: WeiboPost = this.socialMediaPost(post);
    if (media.pictures.length > 0) {
      return media.pictures[0];
    }
    return media.videoCoverUrl;
  }

  private isGifOrLive(url: string, pictureVideos: Record<string, string>): string {
    if ((pictureVideos[url] ?? '').length > 0) { return '实况'; }
    const lower: string = url.toLowerCase();
    if (lower.includes('.gif')) {
      return 'GIF';
    }
    return '';
  }

  private maxContentWidth(): number {
    if (this.viewportWidth <= 0) {
      return 320;
    }
    const cardWidth: number = Math.min(this.viewportWidth - 24, 840);
    return Math.max(200, cardWidth - 32);
  }

  private isLargeScreen(): boolean {
    return this.viewportWidth >= Breakpoint.sm;
  }

  private pictureGap(): number {
    return this.maxContentWidth() >= 480 ? Spacing.sm : Spacing.xs;
  }

  private pictureCellWidth(count: number): number {
    const maxW: number = this.maxContentWidth();
    const gap: number = this.pictureGap();
    if (count === 2 || count === 4) {
      const targetW: number = Math.min(maxW, 360);
      return Math.floor((targetW - gap) / 2);
    }
    const targetW: number = Math.min(maxW, 544);
    return Math.floor((targetW - gap * 2) / 3);
  }

  private pictureCellHeight(count: number): number {
    const cellW: number = this.pictureCellWidth(count);
    if (count === 3) {
      return Math.min(240, Math.round(cellW * 4 / 3));
    }
    return cellW;
  }

  private pictureGridWidth(count: number): number {
    const gap: number = this.pictureGap();
    const cellW: number = this.pictureCellWidth(count);
    if (count === 2 || count === 4) {
      return cellW * 2 + gap;
    }
    return cellW * 3 + gap * 2;
  }

  private pictureGridHeight(count: number): number {
    const gap: number = this.pictureGap();
    const cellH: number = this.pictureCellHeight(count);
    if (count === 2) {
      return cellH;
    }
    if (count === 4) {
      return cellH * 2 + gap;
    }
    if (count === 3) {
      return cellH;
    }
    const rows: number = Math.ceil(Math.min(count, 9) / 3);
    return rows * cellH + (rows - 1) * gap;
  }

  private sharePost(post: WeiboPost): void {
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const url: string = `https://m.weibo.cn/detail/${post.id}`;
    const abstract: string = post.text.length > 0 ? post.text : '微博分享';
    ShareUtil.shareLink(this.getUIContext(), context, url, post.userName, abstract);
  }

  private async toggleFollow(post: WeiboPost): Promise<void> {
    const isFollowed: boolean = !!post.isFollowed;
    const nextFollowed: boolean = !isFollowed;
    try {
      Haptic.light();
      if (nextFollowed) {
        await WeiboService.getInstance().followUser(post.userId);
      } else {
        await WeiboService.getInstance().unfollowUser(post.userId);
      }
      this.posts = this.posts.map((item: WeiboPost): WeiboPost => {
        if (item.userId === post.userId) {
          const clone: WeiboPost = {
            id: item.id,
            userId: item.userId,
            userName: item.userName,
            userAvatar: item.userAvatar,
            text: item.text,
            isLongText: item.isLongText,
            pictures: item.pictures,
            pictureVideos: item.pictureVideos,
            videoUrl: item.videoUrl,
            videoCoverUrl: item.videoCoverUrl,
            videoAspectRatio: item.videoAspectRatio,
            createdAt: item.createdAt,
            source: item.source,
            likeCount: item.likeCount,
            commentCount: item.commentCount,
            repostCount: item.repostCount,
            isLiked: item.isLiked,
            isFavorited: item.isFavorited,
            isFollowed: nextFollowed,
            repost: item.repost,
            hotComment: item.hotComment
          };
          return clone;
        }
        return item;
      });
      this.timelineDataSource.data = this.posts;
      this.timelineDataSource.reload();
      this.getUIContext().getPromptAction().showToast({
        message: nextFollowed ? `已关注 @${post.userName}` : `已取消关注 @${post.userName}`
      });
    } catch (error) {
      const msg: string = (error as Error).message ?? '关注操作未完成';
      this.getUIContext().getPromptAction().showToast({ message: msg });
    }
  }

  @Builder
  SocialMedia(post: WeiboPost): void {
    if (post.videoUrl.length > 0 || (post.pictures.length === 0 && this.socialMediaPost(post).videoUrl.length > 0)) {
      Stack({ alignContent: Alignment.Center }) {
        Image(sanitizeHttpsUrl(post.videoCoverUrl.length > 0 ? post.videoCoverUrl : this.socialCoverUrl(post)))
          .width('100%')
          .aspectRatio(16 / 9)
          .objectFit(ImageFit.Cover)
          .borderRadius(14)
        // Centered play button (native start playing style)
        Stack() {
          Polygon({ width: 20, height: 22 })
            .points([[0, 0], [20, 11], [0, 22]])
            .fill(Color.White)
            .margin({ left: 3 })
        }
        .width(54)
        .height(54)
        .backgroundColor('rgba(0, 0, 0, 0.60)')
        .border({ width: 1.5, color: 'rgba(255, 255, 255, 0.40)' })
        .borderRadius(27)
        .shadow({ radius: 14, color: 'rgba(0, 0, 0, 0.40)', offsetY: 4 })
        .alignContent(Alignment.Center)

        // Corner video badge
        Row({ space: 4 }) {
          Polygon({ width: 7, height: 8 })
            .points([[0, 0], [7, 4], [0, 8]])
            .fill(Color.White)
          Text('视频')
            .fontSize(11)
            .fontColor(Color.White)
            .fontWeight(FontWeight.Medium)
        }
        .padding({ left: 8, right: 8, top: 3, bottom: 3 })
        .backgroundColor('rgba(0, 0, 0, 0.60)')
        .borderRadius(8)
        .position({ x: '100%', y: '100%' })
        .markAnchor({ x: '100%', y: '100%' })
        .margin(10)
      }
      .width('100%')
      .constraintSize({ maxWidth: Math.min(this.maxContentWidth(), 560) })
      .alignSelf(ItemAlign.Start)
      .hitTestBehavior(HitTestMode.Default)
      .onClick((): void => { this.openPost(post); }, WEIBO_TAP_MAX_MOVEMENT)
    } else if (post.pictures.length === 1) {
      Stack({ alignContent: Alignment.BottomEnd }) {
        Image(sanitizeHttpsUrl(post.pictures[0]))
          .width('100%')
          .height(Math.min(320, Math.round(Math.min(this.maxContentWidth(), 480) * 0.75)))
          .constraintSize({ maxWidth: Math.min(this.maxContentWidth(), 480) })
          .objectFit(ImageFit.Cover)
          .borderRadius(14)
        if (this.isGifOrLive(post.pictures[0], post.pictureVideos ?? {}).length > 0) {
          Text(this.isGifOrLive(post.pictures[0], post.pictureVideos ?? {}))
            .fontSize(10)
            .fontWeight(FontWeight.Bold)
            .fontColor(Color.White)
            .backgroundColor(this.isGifOrLive(post.pictures[0], post.pictureVideos ?? {}) === '实况'
              ? Theme.brand() : '#80000000')
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .borderRadius(4)
            .margin(6)
        }
      }
      .alignSelf(ItemAlign.Start)
      .hitTestBehavior(HitTestMode.Default)
      .onClick((): void => {
        const media: WeiboPost = this.socialMediaPost(post);
        this.getUIContext().getRouter().pushUrl({
          url: 'pages/ImagePreview',
          params: { urls: media.pictures, index: 0, pictureVideos: media.pictureVideos ?? {} }
        });
      }, WEIBO_TAP_MAX_MOVEMENT)
    } else if (post.pictures.length === 2 || post.pictures.length === 4) {
      Grid() {
        ForEach(post.pictures.slice(0, post.pictures.length), (pic: string, index: number): void => {
          GridItem() {
            Stack({ alignContent: Alignment.BottomEnd }) {
              Image(sanitizeHttpsUrl(pic))
                .width('100%')
                .height(this.pictureCellHeight(post.pictures.length))
                .objectFit(ImageFit.Cover)
                .borderRadius(10)
              if (this.isGifOrLive(pic, post.pictureVideos ?? {}).length > 0) {
                Text(this.isGifOrLive(pic, post.pictureVideos ?? {}))
                  .fontSize(9)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(Color.White)
                  .backgroundColor(this.isGifOrLive(pic, post.pictureVideos ?? {}) === '实况'
                    ? Theme.brand() : '#80000000')
                  .padding({ left: 5, right: 5, top: 1, bottom: 1 })
                  .borderRadius(4)
                  .margin(4)
              }
            }
            .hitTestBehavior(HitTestMode.Default)
            .onClick((): void => {
              const media: WeiboPost = this.socialMediaPost(post);
              this.getUIContext().getRouter().pushUrl({
                url: 'pages/ImagePreview',
                params: { urls: media.pictures, index: index, pictureVideos: media.pictureVideos ?? {} }
              });
            }, WEIBO_TAP_MAX_MOVEMENT)
          }
        }, (pic: string, idx: number): string => `${idx}`)
      }
      .columnsTemplate('1fr 1fr')
      .columnsGap(this.pictureGap())
      .rowsGap(this.pictureGap())
      .width(this.pictureGridWidth(post.pictures.length))
      .height(this.pictureGridHeight(post.pictures.length))
      .constraintSize({ maxWidth: this.maxContentWidth() })
      .alignSelf(ItemAlign.Start)
    } else if (post.pictures.length > 1) {
      Grid() {
        ForEach(post.pictures.slice(0, 9), (pic: string, index: number): void => {
          GridItem() {
            Stack({ alignContent: Alignment.BottomEnd }) {
              Image(sanitizeHttpsUrl(pic))
                .width('100%')
                .height(this.pictureCellHeight(post.pictures.length))
                .objectFit(ImageFit.Cover)
                .borderRadius(8)
              if (post.pictures.length === 3) {
                Text('长图')
                  .fontSize(9)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Color.White)
                  .backgroundColor('rgba(0, 0, 0, 0.55)')
                  .padding({ left: 4, right: 4, top: 1, bottom: 1 })
                  .borderRadius(3)
                  .margin(4)
              } else if (this.isGifOrLive(pic, post.pictureVideos ?? {}).length > 0) {
                Text(this.isGifOrLive(pic, post.pictureVideos ?? {}))
                  .fontSize(9)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(Color.White)
                  .backgroundColor(this.isGifOrLive(pic, post.pictureVideos ?? {}) === '实况'
                    ? Theme.brand() : '#80000000')
                  .padding({ left: 5, right: 5, top: 1, bottom: 1 })
                  .borderRadius(4)
                  .margin(4)
              }
            }
            .hitTestBehavior(HitTestMode.Default)
            .onClick((): void => {
              const media: WeiboPost = this.socialMediaPost(post);
              this.getUIContext().getRouter().pushUrl({
                url: 'pages/ImagePreview',
                params: { urls: media.pictures, index: index, pictureVideos: media.pictureVideos ?? {} }
              });
            }, WEIBO_TAP_MAX_MOVEMENT)
          }
        }, (pic: string, idx: number): string => `${idx}`)
      }
      .columnsTemplate('1fr 1fr 1fr')
      .columnsGap(this.pictureGap())
      .rowsGap(this.pictureGap())
      .width(this.pictureGridWidth(post.pictures.length))
      .height(this.pictureGridHeight(post.pictures.length))
      .constraintSize({ maxWidth: this.maxContentWidth() })
      .alignSelf(ItemAlign.Start)
    }
  }

  @Builder
  SocialAuthor(post: WeiboPost): void {
    Row({ space: Spacing.sm }) {
      Stack() {
        Text(post.userName.length > 0 ? post.userName.charAt(0) : '微')
          .fontSize(fs(18, this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
        if (post.userAvatar.length > 0) {
          Image(sanitizeHttpsUrl(post.userAvatar))
            .width(42)
            .height(42)
            .objectFit(ImageFit.Cover)
            .borderRadius(21)
            .clip(true)
        }
      }
      .width(42)
      .height(42)
      .borderRadius(21)
      .backgroundColor(Theme.brand())
      .alignContent(Alignment.Center)
      .hitTestBehavior(HitTestMode.Default)
      .onClick((): void => { this.openUserProfile(post.userId, post.userName); }, WEIBO_TAP_MAX_MOVEMENT)
      Column({ space: 3 }) {
        Text(post.userName)
          .fontSize(fs(15, this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.textPrimary(this.isDark))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .hitTestBehavior(HitTestMode.Default)
          .onClick((): void => { this.openUserProfile(post.userId, post.userName); }, WEIBO_TAP_MAX_MOVEMENT)
        Row({ space: 4 }) {
          Text(post.createdAt)
            .fontSize(fs(11, this.fontScale))
            .fontColor(Theme.textSecondary(this.isDark))
          if (post.source.length > 0) {
            Text(`· 来自 ${post.source}`)
              .fontSize(fs(11, this.fontScale))
              .fontColor(Theme.textSecondary(this.isDark))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      // "+ 关注" / "已关注" 胶囊按钮
      Row() {
        Text(post.isFollowed ? '已关注' : '+ 关注')
          .fontSize(fs(11, this.fontScale))
          .fontWeight(FontWeight.Medium)
          .fontColor(post.isFollowed ? Theme.textSecondary(this.isDark) : Theme.brand())
      }
      .height(26)
      .padding({ left: 10, right: 10 })
      .borderRadius(13)
      .border({ width: 0.5, color: post.isFollowed ? Theme.cardBorder(this.isDark) : Theme.brand() })
      .backgroundColor(post.isFollowed ? Color.Transparent : Theme.brandLight(this.isDark))
      .hitTestBehavior(HitTestMode.Default)
      .onClick((): void => { this.toggleFollow(post); }, WEIBO_TAP_MAX_MOVEMENT)

      Button() {
        SymbolGlyph($r('sys.symbol.dot_grid_1x2'))
          .fontSize(fs(16, this.fontScale))
          .fontColor([Theme.textSecondary(this.isDark)])
      }
      .width(28)
      .height(28)
      .backgroundColor(Color.Transparent)
      .accessibilityText('更多操作')
      .onClick((): void => { this.openPost(post); }, WEIBO_TAP_MAX_MOVEMENT)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  PostActionBar(post: WeiboPost): void {
    Row() {
      // 转发
      Row({ space: 5 }) {
        SymbolGlyph($r('sys.symbol.arrow_clockwise'))
          .fontSize(fs(14, this.fontScale))
          .fontColor([Theme.textSecondary(this.isDark)])
        Text(post.repostCount > 0 ? `${post.repostCount}` : '转发')
          .fontSize(fs(12, this.fontScale))
          .fontColor(Theme.textSecondary(this.isDark))
      }
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .height(44)
      .hitTestBehavior(HitTestMode.Default)
      .onClick((): void => { this.openPost(post, WeiboDetailTab.Reposts); }, WEIBO_TAP_MAX_MOVEMENT)

      // 评论
      Row({ space: 5 }) {
        SymbolGlyph($r('sys.symbol.message'))
          .fontSize(fs(14, this.fontScale))
          .fontColor([Theme.textSecondary(this.isDark)])
        Text(post.commentCount > 0 ? `${post.commentCount}` : '评论')
          .fontSize(fs(12, this.fontScale))
          .fontColor(Theme.textSecondary(this.isDark))
      }
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .height(44)
      .hitTestBehavior(HitTestMode.Default)
      .onClick((): void => { this.openPost(post, WeiboDetailTab.Comments, true); }, WEIBO_TAP_MAX_MOVEMENT)

      // 点赞 (鼠尾草绿/薄荷绿高亮)
      Row({ space: 5 }) {
        SymbolGlyph(post.isLiked ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'))
          .fontSize(fs(15, this.fontScale))
          .fontColor([post.isLiked ? Theme.brand() : Theme.textSecondary(this.isDark)])
        Text(post.likeCount > 0 ? `${post.likeCount}` : '点赞')
          .fontSize(fs(12, this.fontScale))
          .fontWeight(post.isLiked ? FontWeight.Bold : FontWeight.Normal)
          .fontColor(post.isLiked ? Theme.brand() : Theme.textSecondary(this.isDark))
      }
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .height(44)
      .hitTestBehavior(HitTestMode.Default)
      .accessibilityText(post.isLiked ? '取消点赞' : '点赞')
      .onClick((): void => { this.toggleLike(post, !post.isLiked); }, WEIBO_TAP_MAX_MOVEMENT)

      // 分享
      Row({ space: 5 }) {
        SymbolGlyph($r('sys.symbol.share'))
          .fontSize(fs(14, this.fontScale))
          .fontColor([Theme.textSecondary(this.isDark)])
      }
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .height(44)
      .hitTestBehavior(HitTestMode.Default)
      .onClick((): void => { this.sharePost(post); }, WEIBO_TAP_MAX_MOVEMENT)
    }
    .width('100%')
    .padding({ top: 8 })
    .border({ width: { top: 0.5 }, color: Theme.cardBorder(this.isDark) })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  HotCommentBox(comment: WeiboComment, post: WeiboPost): void {
    Column({ space: Spacing.xs }) {
      Row({ space: 6 }) {
        Text(comment.likeCount > 0 ? `${comment.likeCount} 赞` : '精选神评')
          .fontSize(10)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
          .backgroundColor(Theme.brand())
          .padding({ left: 6, right: 6, top: 1, bottom: 1 })
          .borderRadius(4)
        Text(comment.userName)
          .fontSize(fs(12, this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.textPrimary(this.isDark))
      }
      .alignItems(VerticalAlign.Center)

      Text(comment.text)
        .fontSize(fs(12.5, this.fontScale))
        .fontColor(Theme.textSecondary(this.isDark))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .lineHeight(fs(18, this.fontScale))
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .backgroundColor(Theme.bgSubCard(this.isDark))
    .borderRadius(12)
    .border({ width: 0.5, color: Theme.cardBorder(this.isDark) })
    .hitTestBehavior(HitTestMode.Default)
    .accessibilityText(`神评预览：${comment.userName}，${comment.text}`)
    .onClick((): void => { this.openPost(post, WeiboDetailTab.Comments, false, comment.id); }, WEIBO_TAP_MAX_MOVEMENT)
  }

  @Builder
  PostCard(post: WeiboPost): void {
    Column({ space: Spacing.sm }) {
      this.SocialAuthor(post)
      if (post.text.length > 0) {
        WeiboRichTextView({
          text: post.text,
          fontSize: fs(15, this.fontScale),
          lineHeight: fs(22, this.fontScale),
          fontColor: Theme.textPrimary(this.isDark),
          maxLines: 8,
          onTopicClick: (topic: string): void => { this.openTopic(topic); },
          onMentionClick: (name: string): void => { this.openUserProfile('', name); }
        }).width('100%')
      }
      if (post.isLongText) {
        Row({ space: 4 }) {
          Text('… 查看全文')
            .fontSize(fs(14, this.fontScale))
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.brand())
        }
        .padding({ top: 2, bottom: 2 })
        .alignSelf(ItemAlign.Start)
        .hitTestBehavior(HitTestMode.Default)
        .accessibilityText('查看微博全文')
        .onClick((): void => {
          this.openPost(post);
        }, WEIBO_TAP_MAX_MOVEMENT)
      }
      if (post.pictures.length > 0 || post.videoUrl.length > 0) {
        this.SocialMedia(post)
      }
      if (post.repost !== null) {
        Column({ space: Spacing.xs }) {
          if (post.repost.text.length > 0) {
            WeiboRichTextView({
              text: `@${post.repost.userName}：${post.repost.text}`,
              fontSize: fs(13, this.fontScale),
              lineHeight: fs(19, this.fontScale),
              fontColor: Theme.textSecondary(this.isDark),
              maxLines: 4,
              onTopicClick: (topic: string): void => { this.openTopic(topic); },
              onMentionClick: (name: string): void => { this.openUserProfile('', name); }
            }).width('100%')
          }
          if (post.repost.isLongText) {
            Row({ space: 4 }) {
              Text('… 查看全文')
                .fontSize(fs(13, this.fontScale))
                .fontWeight(FontWeight.Medium)
                .fontColor(Theme.brand())
            }
            .padding({ top: 2, bottom: 2 })
            .alignSelf(ItemAlign.Start)
            .hitTestBehavior(HitTestMode.Default)
            .accessibilityText('查看原微博全文')
            .onClick((): void => {
              this.openOriginalPost(post);
            }, WEIBO_TAP_MAX_MOVEMENT)
          }
          if (post.repost.pictures.length > 0 || post.repost.videoUrl.length > 0) {
            this.SocialMedia(post.repost)
          }
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding({ left: 12, right: 12, top: 10, bottom: 10 })
        .backgroundColor(Theme.bgSubCard(this.isDark))
        .borderRadius(12)
        .border({ width: 0.5, color: Theme.cardBorder(this.isDark) })
        .hitTestBehavior(HitTestMode.Default)
        .accessibilityText(`查看@${post.repost.userName}的原微博`)
        .onClick((): void => { this.openOriginalPost(post); }, WEIBO_TAP_MAX_MOVEMENT)
      }
      if (post.hotComment !== null && post.hotComment !== undefined) {
        this.HotCommentBox(post.hotComment, post)
      }
      this.PostActionBar(post)
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .constraintSize({ maxWidth: 840 })
    .padding({ left: 16, right: 16, top: 14, bottom: 10 })
    .backgroundColor(Theme.bgCard(this.isDark))
    .borderRadius(20)
    .border({ width: 0.5, color: Theme.cardBorder(this.isDark) })
    .shadow(Theme.feedCardShadow(this.isDark))
    .onClick((): void => { this.openPost(post); }, WEIBO_TAP_MAX_MOVEMENT)
  }

  @Builder
  LoadMoreButton(): void {
    Button(this.loadingMore ? $r('app.string.weibo_loading') : $r('app.string.weibo_timeline_load_more'))
      .width('100%')
      .height(42)
      .fontSize(fs(13, this.fontScale))
      .backgroundColor(Theme.sheetGlass(this.isDark))
      .fontColor(Theme.textPrimary(this.isDark))
      .backgroundBlurStyle(BlurStyle.Regular, { scale: 0.85 })
      .border({ width: 0.5, color: Theme.manualGlassBorder() })
      .shadow(Theme.glassShadowStyle())
      .backgroundEffect(ImmBlur.cardAction())
      .systemMaterial(ImmMaterial.cardAction())
      .borderRadius(Radius.full)
      .onClick((): void => { this.loadMore(); })
  }

  @Builder
  WaterfallFooter(): void {
    Column({ space: Spacing.sm }) {
      if (this.hasMore) { this.LoadMoreButton() }
      else { Text('已加载全部内容').fontSize(fs(12, this.fontScale)).fontColor(Theme.textSecondary(this.isDark)) }
    }.width('100%').padding({ top: Spacing.md, bottom: Spacing.sm })
  }

  @Builder
  WaterfallTimeline(): void {
    // Exactly one vertical scroll owner, also bound to the shell's native Dock.
    List({ scroller: this.pageScroller, space: 12, initialIndex: this.currentFirstVisibleIndex }) {
      LazyForEach(this.timelineDataSource, (post: WeiboPost): void => {
        ListItem() {
          Row() {
            Blank()
            this.PostCard(post)
            Blank()
          }
          .width('100%')
          .padding({ left: 12, right: 12 })
        }
        .width('100%')
      }, (post: WeiboPost): string => `${post.id}:${post.isFollowed ?? false}`)

      ListItem() {
        this.WaterfallFooter()
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .padding({ left: 0, right: 0 })
    .contentStartOffset(this.topInset)
    .contentEndOffset(this.bottomInset)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .cachedCount(6)
    .onTouch((event: TouchEvent): void => {
      if (event.type === TouchType.Down && this.isRestoringPosition) {
        this.isRestoringPosition = false;
        if (this.restoreTimeoutId !== -1 && typeof clearTimeout !== 'undefined') {
          clearTimeout(this.restoreTimeoutId);
          this.restoreTimeoutId = -1;
        }
      }
    })
    .onScrollIndex((firstIndex: number): void => {
      if (this.isRestoringPosition) {
        return;
      }
      // 用户不点提示、主动滑回顶部时视为「已读最新」：直接合入 pending 新微博并摘下胶囊。
      if (firstIndex === 0 && this.newPostsAvailableCount > 0) {
        this.applyNewPosts();
        return;
      }
      this.currentFirstVisibleIndex = firstIndex;
      if (firstIndex >= 0 && firstIndex < this.posts.length) {
        this.currentTopPostId = this.posts[firstIndex].id;
        this.scheduleSavePosition();
      }
    })
    .onScrollStop((): void => {
      if (!this.isRestoringPosition) {
        this.currentScrollYOffset = this.pageScroller.currentOffset().yOffset;
        if (this.currentFirstVisibleIndex >= 0 && this.currentFirstVisibleIndex < this.posts.length) {
          this.currentTopPostId = this.posts[this.currentFirstVisibleIndex].id;
        }
        this.scheduleSavePosition();
      }
    })
    .onDidScroll((yOffset: number, scrollState: ScrollState): void => {
      this.currentScrollYOffset = this.pageScroller.currentOffset().yOffset;
      if (scrollState === ScrollState.Scroll && !this.isRestoringPosition) {
        this.scheduleSavePosition();
      }
      if (scrollState !== ScrollState.Scroll) { return; }
      // Restore the floating Dock at the start of the feed; preserve hide/show on scroll.
      if (this.pageScroller.currentOffset().yOffset <= 0) {
        this.onScrollDirection(true);
        return;
      }
      if (yOffset > 10) { this.onScrollDirection(false); }
      else if (yOffset < -10) { this.onScrollDirection(true); }
    })
    .onReachEnd((): void => { this.loadMore(); })
  }

  @Builder
  Timeline() {
    if (this.timelineState === TimelineState.Loading) {
      ThreadListSkeleton({ count: 8, columns: this.waterfallColumns() })
        .margin({ top: Spacing.sm })
    } else if (this.timelineState === TimelineState.Error) {
      ErrorView({ message: this.errorMessage, onRetry: (): void => { this.loadFirstPage(); } })
        .height('65%')
    } else if (this.timelineState === TimelineState.Empty) {
      EmptyView({
        message: this.mode === WeiboTimelineMode.Following
          ? $r('app.string.weibo_following_empty')
          : $r('app.string.weibo_empty'),
        icon: '○'
      })
        .height('65%')
    } else if (this.timelineState === TimelineState.Success) {
      Column({ space: Spacing.md }) {
        ForEach(this.posts, (post: WeiboPost): void => {
          this.PostCard(post)
        }, (post: WeiboPost): string => `${post.id}:${post.isFollowed ?? false}`)
        if (this.hasMore) {
          this.LoadMoreButton()
        }
      }
      .width('100%')
    } else {
      EmptyView({ message: $r('app.string.weibo_empty'), icon: '○' })
        .height('65%')
    }
  }

  /** Success uses native lazy scrolling for both one-column and masonry layouts. */
  @Builder
  TimelineScroller() {
    if (this.timelineState === TimelineState.Success) {
      this.WaterfallTimeline()
    } else {
      // Skeleton/empty/error content has no nested scrollable children.
      Scroll(this.pageScroller) {
        Column() { this.Timeline() }
          .width('100%')
          .padding({ left: Spacing.sm, right: Spacing.sm, top: this.topInset, bottom: this.bottomInset })
      }.width('100%').height('100%').scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
    }
  }

  @Builder
  RefreshableTimeline() {
    Stack({ alignContent: Alignment.Top }) {
      Refresh({ refreshing: $$this.refreshing, offset: 64, friction: 62 }) {
        this.TimelineScroller()
      }
      .layoutWeight(1)
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Transparent)
      .onRefreshing((): void => {
        Haptic.light();
        this.refreshFeed();
      })

      if (this.newPostsAvailableCount > 0) {
        Row({ space: 6 }) {
          SymbolGlyph($r('sys.symbol.arrow_up'))
            .fontSize(fs(13, this.fontScale))
            .fontColor([Color.White])
          Text(`有 ${this.newPostsAvailableCount} 条新微博`)
            .fontSize(fs(12, this.fontScale))
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.White)
        }
        .padding({ left: 14, right: 14, top: 6, bottom: 6 })
        .backgroundColor(Theme.brand())
        .borderRadius(Radius.full)
        .shadow({ radius: 8, color: 'rgba(0, 0, 0, 0.25)', offsetY: 2 })
        .margin({ top: this.topInset + 8 })
        .onClick((): void => {
          this.applyNewPosts();
        })
      }
    }
    .layoutWeight(1)
    .width('100%')
    .height('100%')
  }

  /** Content fades when it enters the floating title area. */
  private topFadeStop(): number {
    if (this.viewportWidth < 840 || this.viewportHeight <= 0) {
      return 0.15;
    }
    return Math.min(0.15, 108 / this.viewportHeight);
  }

  @Builder
  TopFadeOverlay() {
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

  private composeDialogController: CustomDialogController | null = null;

  private openComposeDialog(): void {
    if (!WeiboAuthManager.getInstance().hasCookie()) {
      this.getUIContext().getPromptAction().showToast({ message: '请先在“我的”页面登录微博' });
      return;
    }
    this.composeDialogController = new CustomDialogController({
      builder: WeiboComposeDialog({
        mode: 'publish',
        onSuccess: (): void => {
          this.refreshFeed();
        }
      }),
      alignment: DialogAlignment.Bottom,
      customStyle: true,
      autoCancel: false,
      offset: { dx: 0, dy: -20 }
    });
    this.composeDialogController.open();
  }

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Column() {
        if (this.showHeader) {
          this.Header()
        }
        this.RefreshableTimeline()
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.bg(this.isDark))
      .onAreaChange((_oldValue: Area, newValue: Area) => {
        this.viewportWidth = newValue.width as number;
        this.viewportHeight = newValue.height as number;
        this.syncCardColumns();
      })
      .overlay(this.showHeader ? undefined : this.TopFadeOverlay())
      .blendMode(this.showHeader ? BlendMode.SRC_OVER : BlendMode.SRC_OVER, BlendApplyType.OFFSCREEN)

      if (this.showHeader) {
        Button() {
          SymbolGlyph($r('sys.symbol.plus'))
            .fontSize(fs(24, this.fontScale))
            .fontColor([Color.White])
        }
        .width(52)
        .height(52)
        .backgroundColor(Theme.brand())
        .borderRadius(Radius.full)
        .shadow(Theme.glassShadowStyle())
        .margin({ right: 20, bottom: 90 })
        .accessibilityText('发微博')
        .onClick((): void => {
          this.openComposeDialog();
        })
      }
    }
    .width('100%')
    .height('100%')
  }
}
