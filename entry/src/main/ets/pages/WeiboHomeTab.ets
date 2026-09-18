import { common } from '@kit.AbilityKit';
import { curves } from '@kit.ArkUI';
import { ThreadCard, ThreadItemData, ThreadSharePayload, EmptyView, ErrorView } from '../components/CommonComponents';
import { ThreadListSkeleton } from '../components/Skeleton';
import { Breakpoint, CARD_COLUMNS_KEY, ImmBlur, ImmMaterial, Radius, Spacing, Theme, fs, isDarkMode, isLargeScreenForm, isWideFormDevice as detectWideFormDevice, overrideColumns, readColumnMode } from '../common/Theme';
import { WeiboPost, WeiboTimelinePage, WeiboUser } from '../model/WeiboModel';
import { WeiboAuthManager } from '../service/WeiboAuthManager';
import { WeiboService } from '../service/WeiboService';
import { ShareUtil } from '../common/ShareUtil';

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
 * TiebaPura 首页的信息层级与帖子卡片，数据仅来自微博只读适配层。
 * 这里特意不复用 HomeTab：该页的推荐、关注吧和互动回调均依赖贴吧协议。
 */
@Component
export struct WeiboHomeTab {
  @Prop mode: WeiboTimelineMode = WeiboTimelineMode.Recommend;
  @Prop showHeader: boolean = true;
  @Prop @Watch('onEnter') animationTrigger: number = 0;
  @Prop @Watch('onExit') exitTrigger: number = 0;
  /** Reserved in the scroll content, so floating host chrome never shrinks the scroll viewport. */
  @Prop topInset: number = 0;
  @Prop bottomInset: number = 116;
  onOpenPost: (post: WeiboPost) => void = () => {};
  onOpenUserProfile: (userId: string, userName: string) => void = () => {};
  @State isDark: boolean = isDarkMode();
  @State userIdDraft: string = '';
  @State profile: WeiboUser | null = null;
  @State @Watch('onPostsChange') posts: WeiboPost[] = [];
  @State timelineState: TimelineState = TimelineState.Idle;
  @State errorMessage: string = '';
  @State currentPage: number = 1;
  /** Desktop friends feed uses this opaque cursor rather than numbered pages. */
  @State followingMaxId: string = '0';
  @State loadingMore: boolean = false;
  @State hasMore: boolean = true;
  @State viewportWidth: number = 0;
  @State viewportHeight: number = 0;
  @State pageTranslateX: number = 0;
  @State pageOpacity: number = 1;
  @State isAnimating: boolean = false;
  /** Device capability gate shared with TiebaPura's large-screen feeds. */
  private readonly isWideFormDevice: boolean = detectWideFormDevice();
  private timelineScroller: Scroller = new Scroller();
  @State timelineDataSource: WeiboPostDataSource = new WeiboPostDataSource();
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
      await this.loadFirstPage();
    }
  }

  private onDarkTick(): void {
    this.isDark = isDarkMode();
  }

  /** Mirrors TiebaPura's WaterFlow contract: page replacement reloads, pagination appends. */
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
    try {
      this.timelineScroller.scrollTo({ xOffset: 0, yOffset: 0 });
    } catch (error) {
    }
  }

  /** Phones and narrow windows retain one column; large forms receive a true waterfall layout. */
  private waterfallColumns(): number {
    if (this.viewportWidth <= 0 || this.viewportHeight <= 0 || this.viewportWidth < Breakpoint.sm) {
      return 1;
    }
    if (!isLargeScreenForm(this.isWideFormDevice)) {
      return 1;
    }
    const override: number = overrideColumns(this.columnMode, this.viewportWidth > this.viewportHeight);
    if (override > 0) {
      return override;
    }
    return this.viewportWidth > this.viewportHeight ? 3 : 2;
  }

  private waterfallColumnsTemplate(): string {
    const columns: number = this.waterfallColumns();
    if (columns === 4) {
      return '1fr 1fr 1fr 1fr';
    }
    return columns === 3 ? '1fr 1fr 1fr' : '1fr 1fr';
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
    // A refreshed account session can change the server's personalized feed.
    // Keep current cards visible until its first fresh page replaces them.
    this.loadFirstPage(true);
  }

  /**
   * Pull-to-refresh keeps the current recommendation cards visible until the
   * fresh first page arrives. Initial loading and explicit retry still use the
   * full loading state.
   */
  private async loadFirstPage(preserveCurrentContent: boolean = false): Promise<void> {
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
          result = followingPage.items;
          this.followingMaxId = followingPage.nextMaxId;
          more = followingPage.hasMore;
        }
        this.posts = result;
        this.currentPage = 1;
        this.hasMore = more;
        this.timelineState = result.length > 0 ? TimelineState.Success : TimelineState.Empty;
      } catch (error) {
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
      this.profile = await service.fetchUserProfile(userId);
      const result: WeiboPost[] = await service.fetchUserTimeline(userId, 1);
      this.posts = result;
      this.currentPage = 1;
      this.hasMore = result.length > 0;
      this.timelineState = result.length > 0 ? TimelineState.Success : TimelineState.Empty;
    } catch (error) {
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
        result = followingPage.items;
        this.followingMaxId = followingPage.nextMaxId;
        more = followingPage.hasMore;
      } else {
        result = await WeiboService.getInstance().fetchUserTimeline(userId, nextPage);
        more = result.length > 0;
      }
      if (result.length > 0) {
        this.posts = this.posts.concat(result);
        this.currentPage = nextPage;
        this.hasMore = more;
      } else {
        this.hasMore = false;
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.weibo_empty') });
      }
    } catch (error) {
      this.errorMessage = (error as Error).message ?? '微博加载失败，请稍后重试';
      this.getUIContext().getPromptAction().showToast({ message: this.errorMessage });
    } finally {
      this.loadingMore = false;
    }
  }

  private toThreadCard(post: WeiboPost): ThreadItemData {
    const firstImage: string = post.pictures.length > 0 ? post.pictures[0] : '';
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
      abstract: post.repost === null ? '' : post.repost.text,
      firstImage: firstImage,
      images: post.pictures,
      videoUrl: post.videoUrl,
      videoCoverUrl: post.videoCoverUrl,
      createTime: post.createdAt,
      isTop: false,
      isGood: false,
    };
  }

  private openPost(post: WeiboPost): void {
    if (post.id.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.weibo_post_unavailable') });
      return;
    }
    this.onOpenPost(post);
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
      pictures: post.pictures,
      videoUrl: post.videoUrl,
      videoCoverUrl: post.videoCoverUrl,
      createdAt: post.createdAt,
      source: post.source,
      likeCount: liked ? post.likeCount + 1 : Math.max(0, post.likeCount - 1),
      commentCount: post.commentCount,
      repostCount: post.repostCount,
      isLiked: liked,
      repost: post.repost,
    };
  }

  private async toggleLike(post: WeiboPost, liked: boolean): Promise<void> {
    try {
      await WeiboService.getInstance().setLike(post.id, liked);
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
      const message: string = (error as Error).message ?? '微博操作失败';
      this.getUIContext().getPromptAction().showToast({ message: message });
    }
  }

  @Builder
  Header() {
    Column({ space: Spacing.sm }) {
      Row({ space: Spacing.md }) {
        Column({ space: 2 }) {
          Text(this.mode === WeiboTimelineMode.Recommend ? $r('app.string.weibo_recommend_title') : $r('app.string.weibo_following_title'))
            .fontSize(fs(20, this.fontScale))
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.textPrimary(this.isDark))
          Text(this.mode === WeiboTimelineMode.Recommend ? $r('app.string.weibo_recommend_hint') : $r('app.string.weibo_following_hint'))
            .fontSize(fs(12, this.fontScale))
            .fontColor(Theme.textSecondary(this.isDark))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Button($r('app.string.weibo_load'))
          .height(36)
          .fontSize(fs(13, this.fontScale))
          .backgroundColor(Theme.manualGlass(this.isDark, true))
          .fontColor(Color.White)
          .border({ width: 0.5, color: Theme.manualGlassBorder() })
          .shadow(Theme.glassShadowStyle())
          .backgroundEffect(ImmBlur.accent())
          .systemMaterial(ImmMaterial.accent(this.isDark))
          .borderRadius(Radius.full)
          .onClick(() => { this.loadFirstPage(); })
      }
      .width('100%')
      if (this.profile !== null) {
        Text(`${this.profile.screenName} · ${this.profile.followersCount} 粉丝 · ${this.profile.statusesCount} 微博`)
          .width('100%')
          .fontSize(fs(12, this.fontScale))
          .fontColor(Theme.textSecondary(this.isDark))
          .maxLines(1)
      }
    }
    .width('100%')
    .padding({ top: 52, left: Spacing.lg, right: Spacing.lg, bottom: Spacing.md })
    .backgroundColor(Theme.bg(this.isDark))
  }

  @Builder
  PostCard(post: WeiboPost): void {
    ThreadCard({
      item: this.toThreadCard(post),
      onTap: (_id: string): void => { this.openPost(post); },
      onComment: (_id: string): void => { this.openPost(post); },
      onLike: (_id: string, _postId: string, liked: boolean): void => { this.toggleLike(post, liked); },
      onShare: (data: ThreadSharePayload): void => { this.onShare(data); },
      onAvatarTap: (id: string, name: string): void => { this.openUserProfile(id, name); },
      onImageTap: (urls: string[], index: number): void => { this.openImagePreview(urls, index); },
      skipImageCache: true
    })
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
  WaterfallTimeline(): void {
    WaterFlow() {
      LazyForEach(this.timelineDataSource, (post: WeiboPost): void => {
        FlowItem() {
          this.PostCard(post)
        }
        .width('100%')
      }, (post: WeiboPost): string => post.id)
    }
    .columnsTemplate(this.waterfallColumnsTemplate())
    .columnsGap(Spacing.md)
    .rowsGap(Spacing.md)
    .width('100%')
    .layoutDirection(FlexDirection.Column)
    .cachedCount(6)
  }

  @Builder
  Timeline() {
    if (this.timelineState === TimelineState.Loading) {
      ThreadListSkeleton({ count: 4 })
        .margin({ top: Spacing.md })
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
        }, (post: WeiboPost): string => post.id)
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

  /** PaperTalk-style page scroll: Scroll owns the viewport; WaterFlow is a direct content block. */
  @Builder
  TimelineScroller() {
    Scroll(this.timelineScroller) {
      Column() {
        if (this.timelineState === TimelineState.Success && this.waterfallColumns() > 1) {
          this.WaterfallTimeline()
        } else {
          this.Timeline()
        }
      }
      .width('100%')
      .padding({ left: Spacing.lg, right: Spacing.lg, top: this.topInset, bottom: this.bottomInset })
    }
    .layoutWeight(1)
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .onReachEnd((): void => {
      if (this.timelineState === TimelineState.Success && this.waterfallColumns() > 1) {
        this.loadMore();
      }
    })
  }

  /** Same alpha-mask used by TiebaPura's HomeTab: content fades when it enters the floating title area. */
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

  build() {
    Column() {
      if (this.showHeader) {
        this.Header()
      }
      this.TimelineScroller()
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
    .translate({ x: this.pageTranslateX })
    .opacity(this.pageOpacity)
  }
}
