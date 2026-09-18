import { common } from '@kit.AbilityKit';
import { WeiboComment, WeiboPost, WeiboUser } from '../model/WeiboModel';
import { WeiboAuthManager } from '../service/WeiboAuthManager';
import { WeiboService } from '../service/WeiboService';
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

/** A post detail and account page; it never shares Tieba's authentication state. */
@Entry
@Component
export struct WeiboFeed {
  @Prop showBack: boolean = true;
  @State isDark: boolean = isDarkMode();
  @State userIdDraft: string = '';
  @State profile: WeiboUser | null = null;
  @State @Watch('onPostsChange') posts: WeiboPost[] = [];
  @State selectedPostId: string = '';
  @State comments: WeiboComment[] = [];
  @State loading: boolean = false;
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
    await this.loadCurrentAccountProfile();
    this.columnMode = readColumnMode();
    this.syncCardColumns();
    const params: Record<string, string> = this.getUIContext().getRouter().getParams() as Record<string, string>;

    if (WeiboAuthManager.getInstance().hasCookie()) {
      // 已登录时始终优先展示 Cookie 对应的账号，不再要求手动填写 UID。
      this.showUserIdSetup = false;
      if (this.currentAccountId.length > 0) {
        this.userIdDraft = this.currentAccountId;
      }
      if (this.userIdDraft.length > 0) {
        await this.loadFeed();
      } else {
        this.errorMessage = '当前登录账号资料读取失败，请返回“我的”刷新账号资料后重试';
      }
      if (params && params.postId && params.postId.length > 0) {
        await this.loadComments(params.postId);
      }
      return;
    }

    this.showUserIdSetup = true;
    this.userIdDraft = WeiboAuthManager.getInstance().getTargetUserId();
    if (params && params.userId && params.userId.length > 0) {
      this.userIdDraft = params.userId;
      await this.loadFeed();
      if (params.postId && params.postId.length > 0) {
        await this.loadComments(params.postId);
      }
    } else if (this.currentAccountId.length > 0) {
      this.userIdDraft = this.currentAccountId;
    }
  }

  private onWeiboAuthTick(): void {
    this.loadCurrentAccountProfile();
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
    if (!WeiboAuthManager.getInstance().hasCookie()) {
      this.accountAvatarUrl = '';
      this.accountName = '';
      return;
    }
    try {
      const account: WeiboUser = await WeiboService.getInstance().fetchCurrentUserProfile();
      this.accountAvatarUrl = account.avatarUrl;
      this.accountName = account.screenName;
      this.currentAccountId = account.id;
    } catch (error) {
      // An expired Cookie must not prevent viewing the detail page. The capsule
      // falls back to the account glyph until the user signs in again.
      this.accountAvatarUrl = '';
      this.accountName = '';
    }
  }

  private async saveSettings(): Promise<void> {
    await WeiboAuthManager.getInstance().setTargetUserId(this.userIdDraft);
    this.getUIContext().getPromptAction().showToast({ message: $r('app.string.weibo_saved') });
  }

  private async loadFeed(): Promise<void> {
    const userId: string = this.userIdDraft.trim();
    if (userId.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.weibo_missing_user_id') });
      return;
    }
    this.loading = true;
    this.errorMessage = '';
    this.selectedPostId = '';
    this.comments = [];
    try {
      await WeiboAuthManager.getInstance().setTargetUserId(userId);
      const service: WeiboService = WeiboService.getInstance();
      this.profile = await service.fetchUserProfile(userId);
      this.posts = await service.fetchUserTimeline(userId, 1);
    } catch (error) {
      this.profile = null;
      this.posts = [];
      this.errorMessage = (error as Error).message ?? '微博加载失败，请稍后重试';
    } finally {
      this.loading = false;
    }
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
  SetupCard() {
    Column({ space: Spacing.sm }) {
      Text($r('app.string.weibo_user_id_label'))
        .fontSize(fs(13, this.fontScale))
        .fontColor(Theme.textSecondary(this.isDark))
      TextInput({ text: this.userIdDraft, placeholder: $r('app.string.weibo_user_id_placeholder') })
        .type(InputType.Number)
        .fontSize(fs(14, this.fontScale))
        .onChange((value: string): void => { this.userIdDraft = value; })
        .width('100%')
        .height(48)
        .backgroundColor(Theme.segGlass(this.isDark, false))
        .backgroundBlurStyle(BlurStyle.Regular, { scale: 0.85 })
        .border({ width: 0.5, color: Theme.manualGlassBorder() })
        .shadow(Theme.segGlassShadow(this.isDark, false))
        .borderRadius(Radius.md)
      Row({ space: Spacing.sm }) {
        Button($r('app.string.weibo_login_title'))
          .layoutWeight(1)
          .height(44)
          .fontSize(fs(14, this.fontScale))
          .backgroundColor(Theme.sheetGlass(this.isDark))
          .fontColor(Theme.brand())
          .backgroundBlurStyle(BlurStyle.Regular, { scale: 0.85 })
          .border({ width: 0.5, color: Theme.manualGlassBorder() })
          .shadow(Theme.glassShadowStyle())
          .backgroundEffect(ImmBlur.cardAction())
          .systemMaterial(ImmMaterial.cardAction())
          .borderRadius(Radius.md)
          .onClick(() => {
            this.getUIContext().getRouter().pushUrl({ url: 'pages/WeiboLogin' }).catch(() => {
              this.getUIContext().getPromptAction().showToast({ message: '登录页打开失败，请稍后重试' });
            });
          })
        Button($r('app.string.weibo_load'))
          .layoutWeight(1)
          .height(44)
          .fontSize(fs(14, this.fontScale))
          .backgroundColor(Theme.manualGlass(this.isDark, true))
          .fontColor(Color.White)
          .border({ width: 0.5, color: Theme.manualGlassBorder() })
          .shadow(Theme.glassShadowStyle())
          .backgroundEffect(ImmBlur.accent())
          .systemMaterial(ImmMaterial.accent(this.isDark))
          .borderRadius(Radius.md)
          .onClick(() => { this.loadFeed(); })
      }
      .width('100%')
    }
    .width('100%')
    .padding(Spacing.lg)
    .backgroundColor(Theme.sheetGlass(this.isDark))
    .backgroundBlurStyle(BlurStyle.Regular, { scale: 0.85 })
    .border({ width: 0.5, color: Theme.manualGlassBorder() })
    .shadow(Theme.glassShadowStyle())
    .systemMaterial(ImmMaterial.rowItem())
    .borderRadius(Radius.postCard)
  }

  @Builder
  ProfileCard(currentProfile: WeiboUser | null) {
    if (currentProfile !== null) {
      Row({ space: Spacing.md }) {
        if (currentProfile.avatarUrl.length > 0) {
          Image(currentProfile.avatarUrl)
            .width(52)
            .height(52)
            .borderRadius(26)
            .objectFit(ImageFit.Cover)
        } else {
          Stack() {
            Text(currentProfile.screenName.substring(0, 1))
              .fontColor(Theme.brand())
              .fontWeight(FontWeight.Bold)
          }
          .width(52)
          .height(52)
          .borderRadius(26)
          .backgroundColor(Theme.brandBg(this.isDark))
          .alignContent(Alignment.Center)
        }
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

  @Builder
  PictureGrid(pictures: string[]) {
    if (this.pictureCount(pictures) === 1) {
      Image(pictures[0])
        .width('100%')
        .height(210)
        .constraintSize({ maxWidth: 360 })
        .objectFit(ImageFit.Cover)
        .borderRadius(Radius.md)
        .onClick((): void => { this.openImagePreview(pictures, 0); })
    } else if (this.pictureCount(pictures) > 1) {
      Grid() {
        ForEach(pictures.slice(0, this.pictureCount(pictures)), (picture: string, index: number): void => {
          GridItem() {
            Image(picture)
              .width('100%')
              .height(this.pictureGridCellHeight(pictures))
              .objectFit(ImageFit.Cover)
              .borderRadius(Radius.md)
              .onClick((): void => { this.openImagePreview(pictures, index); })
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
      Row({ space: 4 }) {
        Text($r('app.string.weibo_repost_label'))
          .fontSize(fs(12, this.fontScale))
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textSecondary(this.isDark))
        Text(`@${repost.userName}`)
          .fontSize(fs(12, this.fontScale))
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textPrimary(this.isDark))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .width('100%')
      if (repost.text.length > 0) {
        Text(repost.text)
          .fontSize(fs(14, this.fontScale))
          .lineHeight(fs(20, this.fontScale))
          .fontColor(Theme.textPrimary(this.isDark))
          .maxLines(4)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      if (repost.pictures.length > 0) {
        this.PictureGrid(repost.pictures)
      }
    }
    .width('100%')
    .padding(Spacing.md)
    .backgroundColor(Theme.brandBg(this.isDark))
    .borderRadius(Radius.md)
  }

  @Builder
  PostCard(post: WeiboPost) {
    Column({ space: Spacing.sm }) {
      Row({ space: Spacing.sm }) {
        if (post.userAvatar.length > 0) {
          Image(post.userAvatar)
            .width(38)
            .height(38)
            .borderRadius(19)
            .objectFit(ImageFit.Cover)
        }
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
      Text(post.text)
        .fontSize(fs(15, this.fontScale))
        .fontColor(Theme.textPrimary(this.isDark))
        .lineHeight(fs(22, this.fontScale))
        .textAlign(TextAlign.Start)
        .width('100%')
      this.VideoPlayer(post)
      if (post.pictures.length > 0) {
        this.PictureGrid(post.pictures)
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
          .onClick(() => { this.loadComments(post.id); })
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
  }

  @Builder
  CommentAvatar() {
    if (this.accountAvatarUrl.length > 0) {
      Image(this.accountAvatarUrl)
        .width(40)
        .height(40)
        .objectFit(ImageFit.Cover)
        .borderRadius(20)
        .clip(true)
    } else if (this.accountName.length > 0) {
      Text(this.accountName.substring(0, 1).toUpperCase())
        .width(40)
        .height(40)
        .fontSize(fs(16, this.fontScale))
        .fontWeight(FontWeight.Bold)
        .fontColor(Color.White)
        .backgroundColor(Theme.brand())
        .borderRadius(20)
        .textAlign(TextAlign.Center)
    } else {
      SymbolGlyph($r('sys.symbol.person'))
        .width(40)
        .height(40)
        .fontSize(fs(20, this.fontScale))
        .fontColor([$r('sys.color.icon_primary')])
        .backgroundColor(Theme.segGlass(this.isDark, false))
        .borderRadius(20)
    }
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
    HdsNavigation() {
      Column() {
      Scroll(this.pageScroller) {
        Column() {
          if (this.showUserIdSetup) {
            this.SetupCard()
          }
          this.ProfileCard(this.profile)
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
      content: { title: { mainTitle: $r('app.string.weibo_title') } },
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
    .mode(NavigationMode.Stack)
    .titleMode(HdsNavigationTitleMode.MINI)
    .hideBackButton(false)
    .bindToScrollable([this.pageScroller])
    .clip(false)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
