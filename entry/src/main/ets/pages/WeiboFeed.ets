import { common } from '@kit.AbilityKit';
import { WeiboRichTextView } from '../components/WeiboRichTextView';
import { WeiboVideoPlayer } from '../components/WeiboVideoPlayer';
import { WeiboPostDetailBuilder, WeiboPostDetailRouteParam } from './WeiboPostDetail';
import { WeiboUserProfileBuilder, WeiboUserProfileRouteParam } from './WeiboUserProfile';
import { WeiboSearchResultBuilder, WeiboSearchResultRouteParam } from './WeiboSearchResult';
import { WeiboBrowserBuilder } from './WeiboBrowser';
import { WeiboComment, WeiboPost, WeiboUser } from '../model/WeiboModel';
import { WeiboHistoryManager, WeiboHistoryItem } from '../service/WeiboHistoryManager';
import { WeiboAuthManager } from '../service/WeiboAuthManager';
import { WeiboService, sanitizeHttpsUrl } from '../service/WeiboService';
import { Breakpoint, CARD_COLUMNS_KEY, ImmBlur, ImmMaterial, Radius, Spacing, Theme, fs, isDarkMode, isLargeScreenForm, isWideFormDevice as detectWideFormDevice, overrideColumns, readColumnMode } from '../common/Theme';
import { ShareUtil } from '../common/ShareUtil';
import { HdsNavigation, HdsNavigationTitleMode, HdsTabs, ScrollEffectType, hdsMaterial } from '@kit.UIDesignKit';

/** HDS mini title bar height below the system status-bar safe area. */
const WEIBO_FEED_TITLE_BAR_CONTENT_HEIGHT: number = 64;

/** PaperTalk-style lazy data source for the browser page's waterfall posts. */
class WeiboFeedDataSource implements IDataSource {
  private listeners: DataChangeListener[] = [];
  private items: WeiboPost[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): WeiboPost {
    return this.items[index];
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

  setItems(items: WeiboPost[]): void {
    this.items = items;
    for (let index: number = 0; index < this.listeners.length; index++) {
      this.listeners[index].onDataReloaded();
    }
  }
}

/** A post detail and account page with isolated authentication state. */
function historyItemToPost(item: WeiboHistoryItem): WeiboPost {
  const p: WeiboPost = {
    id: item.id,
    userId: item.userId,
    userName: item.userName,
    userAvatar: item.userAvatar,
    text: item.text,
    isLongText: false,
    pictures: item.pictures,
    videoUrl: '',
    videoCoverUrl: '',
    repostCount: 0,
    commentCount: 0,
    likeCount: 0,
    source: '',
    createdAt: '最近浏览',
    isLiked: false,
    isFavorited: false,
    repost: null
  };
  return p;
}

@Entry
@Component
export struct WeiboFeed {
  @Prop showBack: boolean = true;
  @Provide('weiboNavStack') weiboNavStack: NavPathStack = new NavPathStack();
  @State feedMode: string = 'user';
  @State feedTitle: string = '';
  @State isDark: boolean = isDarkMode();
  @State userIdDraft: string = '';
  @State profile: WeiboUser | null = null;
  @State @Watch('onPostsChange') posts: WeiboPost[] = [];
  @State selectedPostId: string = '';
  @State comments: WeiboComment[] = [];
  @State loading: boolean = false;
  @State loadingMore: boolean = false;
  @State feedPage: number = 0;
  @State hasMoreFeed: boolean = true;
  @State moreFeedError: string = '';
  private feedEpoch: number = 0;
  @State commentsLoading: boolean = false;
  @State commentDraft: string = '';
  @State commentSending: boolean = false;
  @State accountAvatarUrl: string = '';
  @State accountName: string = '';
  @State errorMessage: string = '';
  @State showUserIdSetup: boolean = true;
  @State viewportWidth: number = 0;
  @State viewportHeight: number = 0;
  @State feedDataSource: WeiboFeedDataSource = new WeiboFeedDataSource();
  @StorageLink('fontScale') fontScale: number = 1.0;
  @StorageLink('weibo.status_bar_height') statusBarHeight: number = 0;
  @StorageLink('weiboAuthTick') @Watch('onWeiboAuthTick') weiboAuthTick: number = 0;
  @StorageLink('columnMode') columnMode: number = 0;
  @StorageLink('columnModeTick') @Watch('onColumnModeTick') columnModeTick: number = 0;
  private pageScroller: Scroller = new Scroller();
  private readonly isWideFormDevice: boolean = detectWideFormDevice();
  private currentAccountId: string = '';
  private videoController: VideoController = new VideoController();
  @State videoLoadFailed: boolean = false;

  async aboutToAppear(): Promise<void> {
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    await WeiboAuthManager.getInstance().init(context);
    this.columnMode = readColumnMode();
    this.syncCardColumns();
    const params: Record<string, string> = this.getUIContext().getRouter().getParams() as Record<string, string>;

    if (params && params.mode) {
      this.feedMode = params.mode;
    }
    if (params && params.userId && params.userId.length > 0) {
      this.userIdDraft = params.userId;
    }

    if (this.feedMode === 'favorites') {
      this.feedTitle = '我的收藏';
      this.showUserIdSetup = false;
      if (this.userIdDraft.length === 0) {
        await this.loadCurrentAccountProfile();
      }
      await this.loadFeed();
      return;
    } else if (this.feedMode === 'likes') {
      this.feedTitle = '我的点赞';
      this.showUserIdSetup = false;
      if (this.userIdDraft.length === 0) {
        await this.loadCurrentAccountProfile();
      }
      await this.loadFeed();
      return;
    } else if (this.feedMode === 'history') {
      this.feedTitle = '浏览历史';
      this.showUserIdSetup = false;
      await this.loadFeed();
      return;
    }

    if (params && params.ownProfile === 'true') {
      this.feedTitle = '我的微博';
    }

    this.showUserIdSetup = false;

    if (this.userIdDraft.length === 0) {
      await this.loadCurrentAccountProfile();
    }

    if (this.userIdDraft.length > 0) {
      await this.loadFeed();
    } else if (!WeiboAuthManager.getInstance().hasCookie()) {
      this.errorMessage = '请先登录微博账号';
    } else {
      this.errorMessage = '当前登录账号资料读取中，请稍后刷新重试';
    }

    if (params && params.postId && params.postId.length > 0) {
      const param: WeiboPostDetailRouteParam = { postId: params.postId };
      this.weiboNavStack.pushPath({ name: 'WeiboPostDetail', param: param });
    }
  }

  private async onWeiboAuthTick(): Promise<void> {
    this.feedEpoch++;
    this.posts = [];
    this.comments = [];
    this.profile = null;
    this.feedPage = 0;
    this.loading = false;
    this.loadingMore = false;
    this.currentAccountId = '';
    await this.loadCurrentAccountProfile();
    if (this.currentAccountId.length > 0 && this.userIdDraft.length === 0) {
      this.userIdDraft = this.currentAccountId;
    }
    this.showUserIdSetup = false;
    await this.loadFeed();
  }

  onPageShow(): void {
    if (this.feedPage > 0 && (this.feedMode === 'favorites' || this.feedMode === 'likes')) { this.loadFeed(); }
  }

  private onPostsChange(): void {
    this.feedDataSource.setItems(this.posts);
  }

  private onColumnModeTick(): void {
    this.columnMode = readColumnMode();
    this.syncCardColumns();
    try {
      this.pageScroller.scrollTo({ xOffset: 0, yOffset: 0 });
    } catch (error) {
    }
  }

  /** The browser page follows the same auto-column rule as the home feed. */
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

  private syncCardColumns(): void {
    AppStorage.setOrCreate<number>(CARD_COLUMNS_KEY, this.waterfallColumns());
  }

  /** Fetch the identity behind the saved Cookie for the reply composer avatar. */
  private async loadCurrentAccountProfile(): Promise<void> {
    const revision: number = WeiboAuthManager.getInstance().getSessionRevision();
    if (!WeiboAuthManager.getInstance().hasCookie()) {
      this.accountAvatarUrl = '';
      this.accountName = '';
      this.currentAccountId = '';
      return;
    }
    try {
      const account: WeiboUser = await WeiboService.getInstance().fetchCurrentUserProfile();
      WeiboAuthManager.getInstance().assertSession(revision);
      this.accountAvatarUrl = account.avatarUrl;
      this.accountName = account.screenName;
      this.currentAccountId = account.id;
    } catch (error) {
      if (revision !== WeiboAuthManager.getInstance().getSessionRevision()) { return; }
      // An expired Cookie must not prevent viewing the detail page. The capsule
      // falls back to the account glyph until the user signs in again.
      this.accountAvatarUrl = '';
      this.accountName = '';
      this.currentAccountId = '';
    }
  }

  private async saveSettings(): Promise<void> {
    await WeiboAuthManager.getInstance().setTargetUserId(this.userIdDraft);
    this.getUIContext().getPromptAction().showToast({ message: $r('app.string.weibo_saved') });
  }

  private async fetchFeedPage(page: number): Promise<WeiboPost[]> {
    const service: WeiboService = WeiboService.getInstance();
    const targetUid: string = this.userIdDraft.trim().length > 0 ? this.userIdDraft.trim() : this.currentAccountId.trim();
    if (this.feedMode === 'history') {
      const accountKey: string = targetUid.length > 0 ? targetUid : 'guest';
      const historyItems: WeiboHistoryItem[] = await WeiboHistoryManager.getInstance().getHistory(accountKey);
      const posts: WeiboPost[] = [];
      for (const item of historyItems) {
        posts.push(historyItemToPost(item));
      }
      return posts;
    }
    if (this.feedMode === 'favorites') { return service.fetchFavorites(page, targetUid); }
    if (this.feedMode === 'likes') { return service.fetchLikes(targetUid, page); }
    return service.fetchUserTimeline(targetUid, page);
  }

  private async loadFeed(): Promise<void> {
    if (this.loading || this.loadingMore) { return; }
    if (this.feedMode === 'user' && this.userIdDraft.trim().length === 0) {
      if (WeiboAuthManager.getInstance().hasCookie()) {
        await this.loadCurrentAccountProfile();
      }
      if (this.userIdDraft.trim().length === 0) {
        if (!WeiboAuthManager.getInstance().hasCookie()) {
          this.errorMessage = '请先登录微博账号';
        } else {
          this.errorMessage = '当前登录账号资料读取失败，请点击重试';
        }
        return;
      }
    }
    const userId: string = this.userIdDraft.trim();
    const epoch: number = ++this.feedEpoch;
    this.loading = true;
    this.errorMessage = '';
    this.moreFeedError = '';
    this.selectedPostId = '';
    this.comments = [];
    this.feedPage = 0;
    try {
      if (this.feedMode === 'user') {
        await WeiboAuthManager.getInstance().setTargetUserId(userId);
        const profile: WeiboUser = await WeiboService.getInstance().fetchUserProfile(userId);
        if (epoch !== this.feedEpoch) { return; }
        this.profile = profile;
      }
      const items: WeiboPost[] = await this.fetchFeedPage(1);
      if (epoch !== this.feedEpoch) { return; }
      this.posts = items;
      this.feedPage = 1;
      this.hasMoreFeed = items.length > 0;
    } catch (error) {
      if (epoch !== this.feedEpoch) { return; }
      this.posts = [];
      this.hasMoreFeed = false;
      this.errorMessage = (error as Error).message ?? '微博加载失败，请稍后重试';
    } finally {
      if (epoch === this.feedEpoch) {
        this.loading = false;
        setTimeout((): void => {
          try {
            this.pageScroller.scrollEdge(Edge.Top);
          } catch (_e) {}
        }, 100);
      }
    }
  }

  private async loadMoreFeed(): Promise<void> {
    if (this.loading || this.loadingMore || !this.hasMoreFeed || this.feedPage === 0) { return; }
    const epoch: number = this.feedEpoch;
    this.loadingMore = true;
    this.moreFeedError = '';
    try {
      const items: WeiboPost[] = await this.fetchFeedPage(this.feedPage + 1);
      if (epoch !== this.feedEpoch) { return; }
      const next: WeiboPost[] = items.filter((item: WeiboPost): boolean => !this.posts.some((old: WeiboPost): boolean => old.id === item.id));
      this.posts = this.posts.concat(next);
      this.feedPage++;
      this.hasMoreFeed = items.length > 0 && next.length > 0;
    } catch (error) {
      if (epoch === this.feedEpoch) { this.moreFeedError = (error as Error).message ?? '加载失败，请点击重试'; }
    } finally { if (epoch === this.feedEpoch) { this.loadingMore = false; } }
  }

  private async loadComments(postId: string): Promise<void> {
    if (this.commentsLoading) {
      return;
    }
    this.selectedPostId = postId;
    this.comments = [];
    this.commentsLoading = true;
    try {
      const page = await WeiboService.getInstance().fetchComments(postId, 1);
      this.comments = page.items;
    } catch (error) {
      this.errorMessage = (error as Error).message ?? '评论读取失败，请稍后重试';
    } finally {
      this.commentsLoading = false;
    }
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

  private async toggleLike(post: WeiboPost): Promise<void> {
    const liked: boolean = !post.isLiked;
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

  private sharePost(post: WeiboPost): void {
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    ShareUtil.shareLink(this.getUIContext(), context, `https://m.weibo.cn/detail/${post.id}`, post.userName, post.text);
  }

  private async sendComment(): Promise<void> {
    const postId: string = this.selectedPostId;
    if (postId.length === 0 || this.commentSending) {
      return;
    }
    this.commentSending = true;
    try {
      await WeiboService.getInstance().publishComment(postId, this.commentDraft);
      this.commentDraft = '';
      await this.loadComments(postId);
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.weibo_comment_success') });
    } catch (error) {
      const message: string = (error as Error).message ?? '评论发送失败';
      this.getUIContext().getPromptAction().showToast({ message: message });
    } finally {
      this.commentSending = false;
    }
  }

  @Builder
  FeedTitleBar() {
    Row() {
      if (this.showBack) {
        Button() {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontColor([$r('sys.color.icon_primary')])
            .fontSize(fs(28, this.fontScale))
        }
        .width(44)
        .height(44)
        .backgroundColor(Color.Transparent)
        .systemMaterial(ImmMaterial.control())
        .borderRadius(Radius.full)
        .onClick(() => this.getUIContext().getRouter().back())
      }
      Column({ space: 2 }) {
        Text($r('app.string.weibo_title'))
          .fontSize(fs(18, this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.textPrimary(this.isDark))
        Text($r('app.string.weibo_description'))
          .fontSize(fs(11, this.fontScale))
          .fontColor(Theme.textSecondary(this.isDark))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ top: 40, left: Spacing.lg, right: Spacing.lg, bottom: Spacing.sm })
  }

  @Builder
  LoginPromptCard() {
    Column({ space: Spacing.sm }) {
      SymbolGlyph($r('sys.symbol.person_fill'))
        .fontSize(44)
        .fontColor([Theme.brand()])
        .margin({ top: 30 })
      Text('请先登录微博账号')
        .fontSize(fs(17, this.fontScale))
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.textPrimary(this.isDark))
      Text('登录后即可查看你的微博发布历史、收藏与点赞动态')
        .fontSize(fs(13, this.fontScale))
        .fontColor(Theme.textSecondary(this.isDark))
        .textAlign(TextAlign.Center)
        .padding({ left: 24, right: 24 })
      Button('去登录')
        .width(130)
        .height(40)
        .margin({ top: 16 })
        .fontSize(fs(14, this.fontScale))
        .backgroundColor(Theme.brand())
        .fontColor(Color.White)
        .borderRadius(Radius.full)
        .onClick(() => {
          this.getUIContext().getRouter().pushUrl({ url: 'pages/WeiboLogin' }).catch(() => {});
        })
    }
    .width('100%')
    .padding(Spacing.xl)
    .backgroundColor(Theme.bgCard(this.isDark))
    .borderRadius(Radius.postCard)
    .alignItems(HorizontalAlign.Center)
    .shadow(Theme.glassShadowStyle())
  }

  @Builder
  ProfileCard(currentProfile: WeiboUser | null) {
    if (currentProfile !== null) {
      Row({ space: Spacing.md }) {
        Stack() {
          Text(currentProfile.screenName.length > 0 ? currentProfile.screenName.substring(0, 1) : '微')
            .fontColor(Theme.brand())
            .fontWeight(FontWeight.Bold)
          if (currentProfile.avatarUrl.length > 0) {
            Image(sanitizeHttpsUrl(currentProfile.avatarUrl))
              .width(52)
              .height(52)
              .borderRadius(26)
              .objectFit(ImageFit.Cover)
          }
        }
        .width(52)
        .height(52)
        .borderRadius(26)
        .backgroundColor(Theme.brandBg(this.isDark))
        .alignContent(Alignment.Center)
        Column({ space: 4 }) {
          Text(currentProfile.screenName)
            .fontSize(fs(17, this.fontScale))
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.textPrimary(this.isDark))
          Text(`${currentProfile.followersCount} 粉丝 · ${currentProfile.statusesCount} 微博`)
            .fontSize(fs(12, this.fontScale))
            .fontColor(Theme.textSecondary(this.isDark))
            .maxLines(1)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .padding(Spacing.lg)
      .backgroundColor(Theme.bgCard(this.isDark))
      .borderRadius(Radius.postCard)
      .margin({ top: Spacing.md })
    }
  }

  @Builder
  Comments() {
    Column({ space: Spacing.sm }) {
      if (this.commentsLoading) {
        Row({ space: Spacing.sm }) {
          LoadingProgress().width(18).height(18)
          Text($r('app.string.weibo_comments_loading'))
            .fontSize(fs(12, this.fontScale))
            .fontColor(Theme.textSecondary(this.isDark))
        }
      } else if (this.comments.length === 0) {
        Text($r('app.string.weibo_no_comments'))
          .fontSize(fs(12, this.fontScale))
          .fontColor(Theme.textSecondary(this.isDark))
      } else {
        ForEach(this.comments, (comment: WeiboComment): void => {
          Column({ space: 3 }) {
            Text(`${comment.userName} · ${comment.createdAt}`)
              .fontSize(fs(12, this.fontScale))
              .fontColor(Theme.textSecondary(this.isDark))
            Text(comment.text)
              .fontSize(fs(13, this.fontScale))
              .fontColor(Theme.textPrimary(this.isDark))
              .width('100%')
          }
          .width('100%')
          .padding({ top: Spacing.sm, bottom: Spacing.sm })
        }, (comment: WeiboComment): string => comment.id)
      }
    }
    .width('100%')
    .padding({ top: Spacing.sm })
  }

  private pictureCount(pictures: string[]): number {
    return pictures.length > 9 ? 9 : pictures.length;
  }

  private pictureGridColumns(pictures: string[]): number {
    const count: number = this.pictureCount(pictures);
    return count === 2 || count === 4 ? 2 : 3;
  }

  private pictureGridCellHeight(pictures: string[]): number {
    const count: number = this.pictureCount(pictures);
    return count === 2 || count === 4 ? 136 : 92;
  }

  private pictureGridHeight(pictures: string[]): number {
    const count: number = this.pictureCount(pictures);
    const columns: number = this.pictureGridColumns(pictures);
    const rows: number = Math.ceil(count / columns);
    const gap: number = Spacing.sm;
    return rows * this.pictureGridCellHeight(pictures) + (rows - 1) * gap;
  }

  private openImagePreview(urls: string[], index: number, tracks: Record<string, string> = {}): void {
    if (urls.length === 0) {
      return;
    }
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/ImagePreview',
      params: { urls: urls, index: index, pictureVideos: tracks }
    }).catch((): void => {
      this.getUIContext().getPromptAction().showToast({ message: '原图预览打开失败，请稍后重试' });
    });
  }

  private openPost(post: WeiboPost): void {
    WeiboService.getInstance().rememberPost(post);
    WeiboService.getInstance().prefetchComments(post.id);
    const param: WeiboPostDetailRouteParam = { postId: post.id, post: post };
    this.weiboNavStack.pushPath({ name: 'WeiboPostDetail', param: param });
  }

  private openMention(name: string, id: string = ''): void {
    const param: WeiboUserProfileRouteParam = { userName: name, userId: id };
    this.weiboNavStack.pushPath({ name: 'WeiboUserProfile', param: param });
  }

  private openTopic(topic: string): void {
    const param: WeiboSearchResultRouteParam = { query: topic };
    this.weiboNavStack.pushPath({ name: 'WeiboSearchResult', param: param });
  }

  @Builder
  WeiboNavigationBuilder(name: string) {
    if (name === 'WeiboPostDetail') { WeiboPostDetailBuilder() }
    else if (name === 'WeiboUserProfile') { WeiboUserProfileBuilder() }
    else if (name === 'WeiboSearchResult') { WeiboSearchResultBuilder() }
    else if (name === 'WeiboBrowser') { WeiboBrowserBuilder() }
  }

  @Builder
  PictureGrid(pictures: string[], tracks: Record<string, string> = {}) {
    if (this.pictureCount(pictures) === 1) {
      Stack({ alignContent: Alignment.BottomEnd }) {
        Image(sanitizeHttpsUrl(pictures[0]))
          .width('100%')
          .height(210)
          .constraintSize({ maxWidth: 360 })
          .objectFit(ImageFit.Cover)
          .borderRadius(Radius.md)
      }
      .hitTestBehavior(HitTestMode.Default)
      .onClick((): void => { this.openImagePreview(pictures, 0, tracks); })
    } else if (this.pictureCount(pictures) > 1) {
      Grid() {
        ForEach(pictures.slice(0, this.pictureCount(pictures)), (picture: string, index: number): void => {
          GridItem() {
            Stack({ alignContent: Alignment.BottomEnd }) {
              Image(sanitizeHttpsUrl(picture))
                .width('100%')
                .height(this.pictureGridCellHeight(pictures))
                .objectFit(ImageFit.Cover)
                .borderRadius(Radius.md)
            }
            .hitTestBehavior(HitTestMode.Default)
            .onClick((): void => { this.openImagePreview(pictures, index, tracks); })
          }
        }, (picture: string, index: number): string => `${index}`)
      }
      .columnsTemplate(this.pictureGridColumns(pictures) === 2 ? '1fr 1fr' : '1fr 1fr 1fr')
      .columnsGap(Spacing.sm)
      .rowsGap(Spacing.sm)
      .width('100%')
      .height(this.pictureGridHeight(pictures))
      .constraintSize({ maxWidth: 360 })
      .enableScrollInteraction(false)
      .hitTestBehavior(HitTestMode.Default)
      .nestedScroll({
        scrollForward: NestedScrollMode.PARENT_FIRST,
        scrollBackward: NestedScrollMode.PARENT_FIRST
      })
    }
  }

  @Builder
  VideoPlayer(post: WeiboPost) {
    if (post.videoUrl.length > 0) {
      Stack() {
        Video({
          src: post.videoUrl,
          previewUri: post.videoCoverUrl,
          controller: this.videoController
        })
          .width('100%')
          .height(220)
          .controls(true)
          .autoPlay(false)
          .loop(false)
          .objectFit(ImageFit.Contain)
          .backgroundColor(Color.Transparent)
          .borderRadius(Radius.md)
          .onError((): void => {
            this.videoLoadFailed = true;
          })
        if (this.videoLoadFailed) {
          Text('视频加载失败，请稍后重试')
            .fontSize(fs(13, this.fontScale))
            .fontColor(Color.White)
            .padding(12)
            .backgroundColor('#99000000')
            .borderRadius(Radius.full)
        }
      }
      .width('100%')
      .height(220)
      .backgroundColor(Color.Black)
      .borderRadius(Radius.md)
      .clip(true)
    }
  }

  @Builder
  RepostSummary(repost: WeiboPost) {
    Column({ space: Spacing.sm }) {
      WeiboRichTextView({ text: `@${repost.userName}：${repost.text}`, fontSize: fs(14, this.fontScale),
        fontColor: Theme.textPrimary(this.isDark), lineHeight: fs(20, this.fontScale), maxLines: 4,
        onMentionClick: (name: string): void => { this.openMention(name, name === repost.userName ? repost.userId : ''); },
        onTopicClick: (topic: string): void => { this.openTopic(topic); }
      }).width('100%')
      if (repost.pictures.length > 0) {
        this.PictureGrid(repost.pictures, repost.pictureVideos ?? {})
      }
    }
    .width('100%')
    .padding(Spacing.md)
    .backgroundColor(Theme.brandBg(this.isDark))
    .borderRadius(Radius.md)
    .hitTestBehavior(HitTestMode.Default)
    .accessibilityText(`查看@${repost.userName}的原微博`)
    .onClick((): void => {
      if (repost.id.length > 0) {
        this.openPost(repost);
      }
    })
  }

  @Builder
  PostCard(post: WeiboPost) {
    Column({ space: Spacing.sm }) {
      Row({ space: Spacing.sm }) {
        Stack() {
          Text(post.userName.length > 0 ? post.userName.charAt(0) : '微')
            .fontSize(fs(16, this.fontScale))
            .fontWeight(FontWeight.Bold)
            .fontColor(Color.White)
          if (post.userAvatar.length > 0) {
            Image(sanitizeHttpsUrl(post.userAvatar))
              .width(38)
              .height(38)
              .borderRadius(19)
              .objectFit(ImageFit.Cover)
          }
        }
        .width(38)
        .height(38)
        .borderRadius(19)
        .backgroundColor(Theme.brand())
        .alignContent(Alignment.Center)
        Column({ space: 2 }) {
          Text(post.userName)
            .fontSize(fs(14, this.fontScale))
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.textPrimary(this.isDark))
          Text(`${post.createdAt}${post.source.length > 0 ? ' · ' + post.source : ''}`)
            .fontSize(fs(11, this.fontScale))
            .fontColor(Theme.textSecondary(this.isDark))
            .maxLines(1)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      WeiboRichTextView({ text: post.text, fontSize: fs(15, this.fontScale),
        fontColor: Theme.textPrimary(this.isDark), lineHeight: fs(22, this.fontScale),
        onMentionClick: (name: string): void => { this.openMention(name); },
        onTopicClick: (topic: string): void => { this.openTopic(topic); }
      }).width('100%')
      if (post.videoUrl.length > 0) {
        WeiboVideoPlayer({ src: post.videoUrl, cover: post.videoCoverUrl, videoRatio: post.videoAspectRatio ?? 16 / 9 })
      }
      if (post.pictures.length > 0) {
        this.PictureGrid(post.pictures, post.pictureVideos ?? {})
      }
      if (post.repost !== null) {
        this.RepostSummary(post.repost)
      }
      Row({ space: Spacing.sm }) {
        Button($r('app.string.weibo_share'))
          .layoutWeight(1)
          .height(32)
          .fontSize(fs(12, this.fontScale))
          .backgroundColor(Theme.sheetGlass(this.isDark))
          .fontColor(Theme.textPrimary(this.isDark))
          .backgroundBlurStyle(BlurStyle.Regular, { scale: 0.85 })
          .border({ width: 0.5, color: Theme.manualGlassBorder() })
          .shadow(Theme.glassShadowStyle())
          .backgroundEffect(ImmBlur.cardAction())
          .systemMaterial(ImmMaterial.cardAction())
          .borderRadius(Radius.full)
          .onClick(() => { this.sharePost(post); })
        Button(`${this.selectedPostId === post.id ? $r('app.string.weibo_comments_opened') : $r('app.string.weibo_comment')} ${post.commentCount}`)
          .layoutWeight(1)
          .fontSize(fs(12, this.fontScale))
          .height(32)
          .backgroundColor(Theme.sheetGlass(this.isDark))
          .fontColor(Theme.brand())
          .backgroundBlurStyle(BlurStyle.Regular, { scale: 0.85 })
          .border({ width: 0.5, color: Theme.manualGlassBorder() })
          .shadow(Theme.glassShadowStyle())
          .backgroundEffect(ImmBlur.cardAction())
          .systemMaterial(ImmMaterial.cardAction())
          .borderRadius(Radius.full)
          .onClick(() => { this.openPost(post); })
        Button(`${post.isLiked ? '♥' : '♡'} ${post.likeCount}`)
          .layoutWeight(1)
          .height(32)
          .fontSize(fs(12, this.fontScale))
          .backgroundColor(Theme.sheetGlass(this.isDark))
          .fontColor(Theme.brand())
          .backgroundBlurStyle(BlurStyle.Regular, { scale: 0.85 })
          .border({ width: 0.5, color: Theme.manualGlassBorder() })
          .shadow(Theme.glassShadowStyle())
          .backgroundEffect(ImmBlur.cardAction())
          .systemMaterial(ImmMaterial.cardAction())
          .borderRadius(Radius.full)
          .onClick(() => { this.toggleLike(post); })
      }
      .width('100%')
      Text(`转发 ${post.repostCount}`)
        .fontSize(fs(11, this.fontScale))
        .fontColor(Theme.textSecondary(this.isDark))
        .width('100%')
      if (this.selectedPostId === post.id) {
        this.Comments()
        Column() {
          this.CommentComposerCapsule()
        }
        .width('100%')
        .margin({ top: Spacing.sm })
      }
    }
    .width('100%')
    .padding(Spacing.lg)
    .backgroundColor(Theme.bgCard(this.isDark))
    .borderRadius(Radius.postCard)
    .margin({ top: Spacing.md })
    .hitTestBehavior(HitTestMode.Default)
    .onClick((): void => { this.openPost(post); })
  }

  /** Direct PaperTalk-style WaterFlow content; the surrounding page Scroll owns scrolling. */
  @Builder
  WaterfallPosts(): void {
    WaterFlow() {
      LazyForEach(this.feedDataSource, (post: WeiboPost): void => {
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
    .enableScrollInteraction(false)
    .hitTestBehavior(HitTestMode.Default)
    .nestedScroll({
      scrollForward: NestedScrollMode.PARENT_FIRST,
      scrollBackward: NestedScrollMode.PARENT_FIRST
    })
  }

  @Builder
  CommentAvatar() {
    Stack() {
      if (this.accountName.length > 0) {
        Text(this.accountName.substring(0, 1).toUpperCase())
          .fontSize(fs(16, this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
      } else {
        SymbolGlyph($r('sys.symbol.person'))
          .fontSize(fs(20, this.fontScale))
          .fontColor([Color.White])
      }
      if (this.accountAvatarUrl.length > 0) {
        Image(sanitizeHttpsUrl(this.accountAvatarUrl))
          .width(40)
          .height(40)
          .objectFit(ImageFit.Cover)
          .borderRadius(20)
          .clip(true)
      }
    }
    .width(40)
    .height(40)
    .borderRadius(20)
    .backgroundColor(Theme.brand())
    .alignContent(Alignment.Center)
  }

  @Builder
  CommentComposerContent() {
    Row({ space: 6 }) {
      this.CommentAvatar()
      TextInput({ text: this.commentDraft, placeholder: $r('app.string.weibo_comment_placeholder') })
        .layoutWeight(1)
        .height(48)
        .fontSize(fs(15, this.fontScale))
        .backgroundColor(Color.Transparent)
        .fontColor(Theme.textPrimary(this.isDark))
        .borderRadius(Radius.full)
        .padding({ left: Spacing.md, right: Spacing.md })
        .onChange((value: string): void => { this.commentDraft = value; })
      Button(this.commentSending ? $r('app.string.weibo_sending') : $r('app.string.weibo_send_comment'))
        .height(42)
        .fontSize(fs(12, this.fontScale))
        .backgroundColor(Color.Transparent)
        .fontColor($r('sys.color.font_emphasize'))
        .systemMaterial(ImmMaterial.cardAction())
        .borderRadius(Radius.full)
        .enabled(this.commentDraft.trim().length > 0 && !this.commentSending)
        .onClick(() => { this.sendComment(); })
    }
    .width('100%')
    .height(64)
    .padding({ left: 10, right: 8 })
    .borderRadius(32)
  }

  /** Same HDS floating capsule host used by HarmonyX's reply composer. */
  @Builder
  CommentComposerCapsule() {
    HdsTabs() {
      TabContent() {
      }
      .tabBar(this.CommentComposerContent())
    }
    .scrollable(false)
    .barPosition(BarPosition.End)
    .barMode(BarMode.Fixed)
    .barHeight('100%')
    .barWidth('100%')
    .barFloatingStyle({
      systemMaterialEffect: {
        materialType: hdsMaterial.MaterialType.ADAPTIVE,
        materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
      },
      thermoCtrl: true
    })
    .width('100%')
    .height(64)
  }

  build() {
    HdsNavigation(this.weiboNavStack) {
      Column() {
      Scroll(this.pageScroller) {
        Column() {
          if (!WeiboAuthManager.getInstance().hasCookie() && this.userIdDraft.trim().length === 0) {
            this.LoginPromptCard()
          }
          if (this.feedMode === 'user' && this.profile !== null) {
            this.ProfileCard(this.profile)
          }
          if (this.loading) {
            Row({ space: Spacing.sm }) {
              LoadingProgress().width(22).height(22)
              Text($r('app.string.weibo_loading'))
                .fontSize(fs(14, this.fontScale))
                .fontColor(Theme.textSecondary(this.isDark))
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
            .margin({ top: Spacing.xl })
          } else if (this.errorMessage.length > 0) {
            Text(this.errorMessage)
              .width('100%')
              .fontSize(fs(13, this.fontScale))
              .fontColor(Theme.danger())
              .margin({ top: Spacing.lg })
            Button('重试').height(44).onClick((): void => { this.loadFeed(); })
          } else if (this.posts.length === 0) {
            Text($r('app.string.weibo_empty'))
              .width('100%')
              .textAlign(TextAlign.Center)
              .fontSize(fs(13, this.fontScale))
              .fontColor(Theme.textSecondary(this.isDark))
              .margin({ top: Spacing.xl })
          } else {
            if (this.waterfallColumns() > 1) {
              this.WaterfallPosts()
            } else {
              ForEach(this.posts, (post: WeiboPost): void => {
                this.PostCard(post)
              }, (post: WeiboPost): string => post.id)
            }
            if (this.loadingMore) {
              LoadingProgress().width(24).height(44)
            } else if (this.hasMoreFeed) {
              Button(this.moreFeedError.length > 0 ? `${this.moreFeedError} · 重试` : '加载更多')
                .height(44).onClick((): void => { this.loadMoreFeed(); })
            } else {
              Text('已显示全部微博').fontSize(13).fontColor(Theme.textSecondary(this.isDark)).padding(12)
            }
          }
        }
        .width('100%')
        // The page expands into the system safe area; reserve the status bar and
        // HDS mini title bar so the first card never sits behind the title bar.
        .padding({
          left: Spacing.lg,
          right: Spacing.lg,
          top: this.statusBarHeight + WEIBO_FEED_TITLE_BAR_CONTENT_HEIGHT,
          bottom: Spacing.xl
        })
      }
      .scrollBar(BarState.Off)
      .scrollable(ScrollDirection.Vertical)
      .onScrollEdge((edge: Edge): void => { if (edge === Edge.Bottom && this.moreFeedError.length === 0) { this.loadMoreFeed(); } })
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .layoutWeight(1)
      .width('100%')
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.bg(this.isDark))
      .onAreaChange((_oldValue: Area, newValue: Area): void => {
        this.viewportWidth = newValue.width as number;
        this.viewportHeight = newValue.height as number;
        this.syncCardColumns();
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg(this.isDark))
    .titleBar({
      avoidLayoutSafeArea: true,
      content: { title: { mainTitle: this.feedTitle.length > 0 ? this.feedTitle : $r('app.string.weibo_title') } },
      style: {
        scrollEffectOpts: {
          enableScrollEffect: true,
          scrollEffectType: ScrollEffectType.IMMERSIVE_GRADIENT_BLUR
        },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.IMMERSIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
        }
      }
    })
    // This is a standalone browser page, never a source/destination split pane.
    .navDestination(this.WeiboNavigationBuilder)
    .mode(NavigationMode.Stack)
    .titleMode(HdsNavigationTitleMode.MINI)
    .hideBackButton(false)
    .bindToScrollable([this.pageScroller])
    .clip(false)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
