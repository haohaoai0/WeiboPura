import { common } from '@kit.AbilityKit';
import { curves } from '@kit.ArkUI';
import { WeiboComment, WeiboPost, WeiboUser } from '../model/WeiboModel';
import { WeiboAuthManager } from '../service/WeiboAuthManager';
import { WeiboService } from '../service/WeiboService';
import { ImmBlur, ImmMaterial, MaterialManager, Radius, Spacing, Theme, fs, isDarkMode } from '../common/Theme';
import { ShareUtil } from '../common/ShareUtil';
import { DividerShowType, HdsNavDestination, HdsNavDestinationTitleMode, HdsTabs, hdsMaterial, ScrollEffectType } from '@kit.UIDesignKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { uiMaterial } from '@kit.ArkUI';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { harmonyShare, systemShare } from '@kit.ShareKit';
import { syncWeiboSplitNavigation } from '../common/WeiboNavigationLayout';

/**
 * Routed post detail. It deliberately owns its scroll, comments, and bottom
 * composer so a timeline card never expands in place.
 */
export interface WeiboPostDetailRouteParam {
  postId: string;
}

@Builder
export function WeiboPostDetailBuilder(): void {
  WeiboPostDetail()
}

@Component
export struct WeiboPostDetail {
  @State isDark: boolean = isDarkMode();
  @State postId: string = '';
  @State post: WeiboPost | null = null;
  @State comments: WeiboComment[] = [];
  @State loading: boolean = true;
  @State commentsLoading: boolean = false;
  @State errorMessage: string = '';
  @State commentDraft: string = '';
  @State commentSending: boolean = false;
  @State accountAvatarUrl: string = '';
  @State accountName: string = '';
  /** One-shot entrance for the post and conversation after data becomes available. */
  @State contentOpacity: number = 0;
  @State contentTranslateY: number = 18;
  @State contentScale: number = 0.985;
  @StorageLink('fontScale') fontScale: number = 1.0;
  @StorageLink('weibo.status_bar_height') statusBarHeight: number = 0;
  @StorageLink('weibo.navigation_indicator_height') navigationIndicatorHeight: number = 0;
  @StorageLink('weiboAuthTick') @Watch('onWeiboAuthTick') weiboAuthTick: number = 0;
  @Consume('weiboNavStack') weiboNavStack: NavPathStack;
  private detailScroller: Scroller = new Scroller();
  private videoController: VideoController = new VideoController();
  private gestureShareListening: boolean = false;
  private gestureSharing: boolean = false;
  private gestureSharePreviewPostId: string = '';
  private gestureSharePreviewUri: string = '';
  private gestureSharePreviewContentKey: string = '';
  private gesturesShareCallback: (target: harmonyShare.SharableTarget) => void =
    (target: harmonyShare.SharableTarget): void => {
      this.sharePostByGesture(target);
    };
  @State videoLoadFailed: boolean = false;

  async aboutToAppear(): Promise<void> {
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    await WeiboAuthManager.getInstance().init(context);
    await this.loadCurrentAccountProfile();
    this.registerGesturesShare();
    setTimeout((): void => {
      this.loadRoutePost();
    }, 50);
  }

  aboutToDisappear(): void {
    this.unregisterGesturesShare();
  }

  /** HDS destinations receive their argument from the shared NavPathStack. */
  private async loadRoutePost(): Promise<void> {
    const params: WeiboPostDetailRouteParam[] =
      this.weiboNavStack.getParamByName('WeiboPostDetail') as WeiboPostDetailRouteParam[];
    if (params === undefined || params === null || params.length === 0) {
      this.loading = false;
      this.errorMessage = '该微博信息暂不可用';
      return;
    }
    const routeParam: WeiboPostDetailRouteParam = params[params.length - 1];
    this.postId = routeParam.postId;
    if (this.postId.length === 0) {
      this.loading = false;
      this.errorMessage = '该微博信息暂不可用';
      return;
    }
    const cached: WeiboPost | null = WeiboService.getInstance().getRememberedPost(this.postId);
    if (cached !== null) {
      this.post = cached;
      this.loading = false;
      this.presentPostContent();
      await this.prepareGestureSharePreview();
      await this.loadComments();
      return;
    }
    await this.loadPost();
  }

  private onWeiboAuthTick(): void {
    this.loadCurrentAccountProfile();
  }

  /** The reply capsule shows the actual account avatar represented by the saved Cookie. */
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
    } catch (error) {
      this.accountAvatarUrl = '';
      this.accountName = '';
    }
  }

  private async loadPost(): Promise<void> {
    this.loading = true;
    this.errorMessage = '';
    this.contentOpacity = 0;
    this.contentTranslateY = 18;
    this.contentScale = 0.985;
    try {
      this.post = await WeiboService.getInstance().fetchPost(this.postId);
      this.presentPostContent();
      await this.prepareGestureSharePreview();
      await this.loadComments();
    } catch (error) {
      this.errorMessage = (error as Error).message ?? '帖子详情加载失败，请稍后重试';
    } finally {
      this.loading = false;
    }
  }

  private presentPostContent(): void {
    this.getUIContext().animateTo({ curve: curves.interpolatingSpring(0, 1, 360, 34) }, (): void => {
      this.contentOpacity = 1;
      this.contentTranslateY = 0;
      this.contentScale = 1;
    });
  }

  private popRoute(): void {
    this.weiboNavStack.pop();
    syncWeiboSplitNavigation(this.weiboNavStack);
  }

  private async loadComments(): Promise<void> {
    if (this.postId.length === 0 || this.commentsLoading) {
      return;
    }
    this.commentsLoading = true;
    try {
      const page = await WeiboService.getInstance().fetchComments(this.postId, 1);
      this.comments = page.items;
    } catch (error) {
      const message: string = (error as Error).message ?? '帖子详情加载失败，请稍后重试';
      this.getUIContext().getPromptAction().showToast({ message: message });
    } finally {
      this.commentsLoading = false;
    }
  }

  private copyPostWithLike(source: WeiboPost, liked: boolean): WeiboPost {
    return {
      id: source.id,
      userId: source.userId,
      userName: source.userName,
      userAvatar: source.userAvatar,
      text: source.text,
      pictures: source.pictures,
      videoUrl: source.videoUrl,
      videoCoverUrl: source.videoCoverUrl,
      createdAt: source.createdAt,
      source: source.source,
      likeCount: liked ? source.likeCount + 1 : Math.max(0, source.likeCount - 1),
      commentCount: source.commentCount,
      repostCount: source.repostCount,
      isLiked: liked,
      repost: source.repost,
    };
  }

  private async toggleLike(): Promise<void> {
    if (this.post === null) {
      return;
    }
    const source: WeiboPost = this.post;
    const liked: boolean = !source.isLiked;
    try {
      await WeiboService.getInstance().setLike(source.id, liked);
      const updated: WeiboPost = this.copyPostWithLike(source, liked);
      this.post = updated;
      WeiboService.getInstance().rememberPost(updated);
      this.getUIContext().getPromptAction().showToast({
        message: liked ? $r('app.string.weibo_like_success') : $r('app.string.weibo_unlike_success')
      });
    } catch (error) {
      const message: string = (error as Error).message ?? '微博操作失败';
      this.getUIContext().getPromptAction().showToast({ message: message });
    }
  }

  private sharePost(): void {
    if (this.post === null) {
      return;
    }
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    ShareUtil.shareLink(this.getUIContext(), context, `https://m.weibo.cn/detail/${this.post.id}`,
      this.post.userName, this.post.text);
  }

  /** Mobile link sent when the user performs HarmonyOS' one-grab-one-release gesture. */
  private postShareUrl(post: WeiboPost): string {
    return `https://m.weibo.cn/detail/${post.id}`;
  }

  /** Register only while this detail is visible so another page can own the same system gesture. */
  private registerGesturesShare(): void {
    if (this.gestureShareListening || !canIUse('SystemCapability.Collaboration.HarmonyShare')) {
      return;
    }
    try {
      harmonyShare.on('gesturesShare', this.gesturesShareCallback);
      this.gestureShareListening = true;
    } catch {
      this.gestureShareListening = false;
    }
  }

  private unregisterGesturesShare(): void {
    if (!this.gestureShareListening) {
      return;
    }
    try {
      harmonyShare.off('gesturesShare', this.gesturesShareCallback);
    } catch {
      // The page is leaving; discarding the local registration state is safe.
    }
    this.gestureShareListening = false;
  }

  private createGestureShareData(post: WeiboPost, thumbnailUri: string): systemShare.SharedData {
    if (thumbnailUri.length > 0) {
      return new systemShare.SharedData({
        utd: utd.UniformDataType.HYPERLINK,
        content: this.postShareUrl(post),
        thumbnailUri: thumbnailUri,
        title: post.userName + ' 的微博',
        description: post.text
      });
    }
    return new systemShare.SharedData({
      utd: utd.UniformDataType.HYPERLINK,
      content: this.postShareUrl(post),
      title: post.userName + ' 的微博',
      description: post.text
    });
  }

  private async captureGestureSharePreview(post: WeiboPost): Promise<string> {
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const previewPath: string = context.filesDir + '/weibo-gesture-share-' + post.id + '.png';
    try {
      const pixelMap: image.PixelMap = await this.getUIContext().getComponentSnapshot().createFromBuilder(
        (): void => {
          this.GestureSharePreview();
        }, 0, true, { scale: 1, waitUntilRenderFinished: true });
      const packer: image.ImagePacker = image.createImagePacker();
      const data: ArrayBuffer = await packer.packToData(pixelMap, { format: 'image/png', quality: 100 });
      const file: fileIo.File = fileIo.openSync(previewPath, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);
      try {
        fileIo.writeSync(file.fd, data);
      } finally {
        fileIo.closeSync(file.fd);
      }
      return fileUri.getUriFromPath(previewPath);
    } catch {
      return '';
    }
  }

  private async prepareGestureSharePreview(): Promise<void> {
    const currentPost: WeiboPost | null = this.post;
    if (currentPost === null) {
      return;
    }
    const contentKey: string = this.gestureSharePreviewKey(currentPost);
    if (this.gestureSharePreviewPostId === currentPost.id && this.gestureSharePreviewContentKey === contentKey) {
      return;
    }
    const previewUri: string = await this.captureGestureSharePreview(currentPost);
    if (this.post !== null && this.post.id === currentPost.id &&
      this.gestureSharePreviewKey(this.post) === contentKey) {
      this.gestureSharePreviewPostId = currentPost.id;
      this.gestureSharePreviewUri = previewUri;
      this.gestureSharePreviewContentKey = contentKey;
    }
  }

  private gestureSharePreviewKey(post: WeiboPost): string {
    const mediaUrl: string = post.pictures.length > 0 ? post.pictures[0] : post.videoCoverUrl;
    return `${post.id}|${post.userName}|${post.userAvatar}|${post.text}|${post.createdAt}|${post.source}|` +
      `${post.repostCount}|${post.commentCount}|${post.likeCount}|${mediaUrl}`;
  }

  private async sharePostByGesture(target: harmonyShare.SharableTarget): Promise<void> {
    const currentPost: WeiboPost | null = this.post;
    if (currentPost === null || this.gestureSharing) {
      return;
    }
    this.gestureSharing = true;
    try {
      if (this.gestureSharePreviewPostId !== currentPost.id ||
        this.gestureSharePreviewContentKey !== this.gestureSharePreviewKey(currentPost)) {
        await this.prepareGestureSharePreview();
      }
      const shareData: systemShare.SharedData = this.createGestureShareData(currentPost, this.gestureSharePreviewUri);
      await target.share(shareData);
    } catch {
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.weibo_gesture_share_failed') });
    }
    this.gestureSharing = false;
  }

  @Builder
  GestureSharePreview() {
    if (this.post !== null) {
      Column({ space: Spacing.sm }) {
        Row({ space: Spacing.sm }) {
          if (this.post.userAvatar.length > 0) {
            Image(this.post.userAvatar)
              .width(42)
              .height(42)
              .objectFit(ImageFit.Cover)
              .borderRadius(Radius.full)
              .clip(true)
          } else {
            Stack() {
              Text(this.post.userName.substring(0, 1))
                .fontSize(18)
                .fontWeight(FontWeight.Bold)
                .fontColor(Color.White)
            }
            .width(42)
            .height(42)
            .backgroundColor(Theme.brand())
            .borderRadius(Radius.full)
            .alignContent(Alignment.Center)
          }
          Column({ space: 2 }) {
            Text(this.post.userName)
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor(Theme.textPrimary(this.isDark))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(`${this.post.createdAt}${this.post.source.length > 0 ? ' · ' + this.post.source : ''}`)
              .fontSize(12)
              .fontColor(Theme.textSecondary(this.isDark))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        Text(this.post.text)
          .width('100%')
          .fontSize(16)
          .lineHeight(24)
          .fontColor(Theme.textPrimary(this.isDark))
          .maxLines(5)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.post.pictures.length > 0) {
          Image(this.post.pictures[0])
            .width('100%')
            .height(148)
            .objectFit(ImageFit.Cover)
            .borderRadius(Radius.md)
        } else if (this.post.videoCoverUrl.length > 0) {
          Image(this.post.videoCoverUrl)
            .width('100%')
            .height(148)
            .objectFit(ImageFit.Cover)
            .borderRadius(Radius.md)
        }
        Row({ space: Spacing.md }) {
          Text($r('app.string.weibo_gesture_share_reposts'))
            .fontSize(12)
            .fontColor(Theme.textSecondary(this.isDark))
          Text(`${this.post.repostCount}`)
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.textPrimary(this.isDark))
          Text($r('app.string.weibo_gesture_share_comments'))
            .fontSize(12)
            .fontColor(Theme.textSecondary(this.isDark))
          Text(`${this.post.commentCount}`)
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.textPrimary(this.isDark))
          Text($r('app.string.weibo_gesture_share_likes'))
            .fontSize(12)
            .fontColor(Theme.textSecondary(this.isDark))
          Text(`${this.post.likeCount}`)
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.textPrimary(this.isDark))
        }
        .width('100%')
        Text(this.postShareUrl(this.post))
          .width('100%')
          .fontSize(11)
          .fontColor(Theme.brand())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width(320)
      .padding(Spacing.lg)
      .backgroundColor(Theme.bgCard(this.isDark))
      .border({ width: 1, color: Theme.manualGlassBorder() })
      .borderRadius(Radius.postCard)
    }
  }

  private async sendComment(): Promise<void> {
    if (this.commentSending || this.commentDraft.trim().length === 0 || this.postId.length === 0) {
      return;
    }
    this.commentSending = true;
    try {
      await WeiboService.getInstance().publishComment(this.postId, this.commentDraft);
      this.commentDraft = '';
      await this.loadComments();
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.weibo_comment_success') });
    } catch (error) {
      const message: string = (error as Error).message ?? '评论发送失败';
      this.getUIContext().getPromptAction().showToast({ message: message });
    } finally {
      this.commentSending = false;
    }
  }

  private visiblePictureCount(pictures: string[]): number {
    return pictures.length > 9 ? 9 : pictures.length;
  }

  private pictureColumns(pictures: string[]): number {
    const count: number = this.visiblePictureCount(pictures);
    return count === 2 || count === 4 ? 2 : 3;
  }

  private pictureCellHeight(pictures: string[]): number {
    const count: number = this.visiblePictureCount(pictures);
    return count === 2 || count === 4 ? 150 : 106;
  }

  private pictureGridHeight(pictures: string[]): number {
    const count: number = this.visiblePictureCount(pictures);
    const columns: number = this.pictureColumns(pictures);
    const rows: number = Math.ceil(count / columns);
    return rows * this.pictureCellHeight(pictures) + (rows - 1) * Spacing.sm;
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
  DetailTitleBar() {
    Column() {
      Row() {
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
        .accessibilityText($r('app.string.weibo_back'))
        .onClick((): void => { this.popRoute(); })
        Text($r('app.string.weibo_post_detail_title'))
          .layoutWeight(1)
          .fontSize(fs(17, this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.textPrimary(this.isDark))
          .textAlign(TextAlign.Center)
        Button() {
          SymbolGlyph($r('sys.symbol.share'))
            .fontColor([$r('sys.color.icon_primary')])
            .fontSize(fs(20, this.fontScale))
        }
        .width(44)
        .height(44)
        .backgroundColor(Color.Transparent)
        .systemMaterial(ImmMaterial.control())
        .borderRadius(Radius.full)
        .accessibilityText($r('app.string.weibo_share'))
        .onClick(() => { this.sharePost(); })
      }
      .width('100%')
      .height(64)
      .padding({ left: Spacing.lg, right: Spacing.lg })
    }
    .width('100%')
  }

  @Builder
  PictureGrid(pictures: string[]) {
    if (this.visiblePictureCount(pictures) === 1) {
      Image(pictures[0])
        .width('100%')
        .height(260)
        .constraintSize({ maxWidth: 460 })
        .objectFit(ImageFit.Cover)
        .borderRadius(Radius.md)
        .onClick((): void => { this.openImagePreview(pictures, 0); })
    } else if (this.visiblePictureCount(pictures) > 1) {
      Grid() {
        ForEach(pictures.slice(0, this.visiblePictureCount(pictures)), (picture: string, index: number): void => {
          GridItem() {
            Image(picture)
              .width('100%')
              .height(this.pictureCellHeight(pictures))
              .objectFit(ImageFit.Cover)
              .borderRadius(Radius.md)
              .onClick((): void => { this.openImagePreview(pictures, index); })
          }
        }, (picture: string, index: number): string => `${index}`)
      }
      .columnsTemplate(this.pictureColumns(pictures) === 2 ? '1fr 1fr' : '1fr 1fr 1fr')
      .columnsGap(Spacing.sm)
      .rowsGap(Spacing.sm)
      .width('100%')
      .height(this.pictureGridHeight(pictures))
      .constraintSize({ maxWidth: 460 })
      .enableScrollInteraction(false)
    }
  }

  @Builder
  VideoPlayer(currentPost: WeiboPost) {
    if (currentPost.videoUrl.length > 0) {
      Stack() {
        Video({
          src: currentPost.videoUrl,
          previewUri: currentPost.videoCoverUrl,
          controller: this.videoController
        })
          .width('100%')
          .height(260)
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
      .height(260)
      .backgroundColor(Color.Black)
      .borderRadius(Radius.md)
      .clip(true)
    }
  }

  @Builder
  RepostCard(repost: WeiboPost) {
    Column({ space: Spacing.sm }) {
      Row({ space: 4 }) {
        Text($r('app.string.weibo_repost_label'))
          .fontSize(fs(13, this.fontScale))
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textSecondary(this.isDark))
        Text(`· @${repost.userName}`)
          .fontSize(fs(13, this.fontScale))
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textSecondary(this.isDark))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      Text(repost.text)
        .fontSize(fs(14, this.fontScale))
        .lineHeight(fs(21, this.fontScale))
        .fontColor(Theme.textPrimary(this.isDark))
        .width('100%')
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
  PostBody(currentPost: WeiboPost) {
    Column({ space: Spacing.md }) {
      Row({ space: Spacing.sm }) {
        if (currentPost.userAvatar.length > 0) {
          Image(currentPost.userAvatar)
            .width(44)
            .height(44)
            .borderRadius(Radius.full)
            .objectFit(ImageFit.Cover)
        } else {
          Stack() {
            Text(currentPost.userName.substring(0, 1))
              .fontSize(fs(17, this.fontScale))
              .fontWeight(FontWeight.Bold)
              .fontColor(Theme.brand())
          }
          .width(44)
          .height(44)
          .backgroundColor(Theme.brandBg(this.isDark))
          .borderRadius(Radius.full)
          .alignContent(Alignment.Center)
        }
        Column({ space: 2 }) {
          Text(currentPost.userName)
            .fontSize(fs(16, this.fontScale))
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.textPrimary(this.isDark))
          Text(`${currentPost.createdAt}${currentPost.source.length > 0 ? ' · ' + currentPost.source : ''}`)
            .fontSize(fs(12, this.fontScale))
            .fontColor(Theme.textSecondary(this.isDark))
            .maxLines(1)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      Text(currentPost.text)
        .fontSize(fs(17, this.fontScale))
        .lineHeight(fs(27, this.fontScale))
        .fontColor(Theme.textPrimary(this.isDark))
        .width('100%')
      this.VideoPlayer(currentPost)
      if (currentPost.pictures.length > 0) {
        this.PictureGrid(currentPost.pictures)
      }
      if (currentPost.repost !== null) {
        this.RepostCard(currentPost.repost)
      }
      Row({ space: Spacing.md }) {
        Text(`转发 ${currentPost.repostCount}`)
          .fontSize(fs(13, this.fontScale))
          .fontColor(Theme.textSecondary(this.isDark))
          .layoutWeight(1)
        Text(`评论 ${currentPost.commentCount}`)
          .fontSize(fs(13, this.fontScale))
          .fontColor(Theme.textSecondary(this.isDark))
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
        Text(`${currentPost.isLiked ? '♥' : '♡'} ${currentPost.likeCount}`)
          .fontSize(fs(13, this.fontScale))
          .fontColor(Theme.brand())
          .layoutWeight(1)
          .textAlign(TextAlign.End)
      }
      .width('100%')
    }
    .width('100%')
    .padding(Spacing.lg)
    .backgroundColor(Theme.bgCard(this.isDark))
    .borderRadius(Radius.postCard)
  }

  @Builder
  CommentsSection() {
    Column({ space: Spacing.md }) {
      Text($r('app.string.weibo_post_comments_title'))
        .fontSize(fs(18, this.fontScale))
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.textPrimary(this.isDark))
        .width('100%')
      if (this.commentsLoading) {
        Row({ space: Spacing.sm }) {
          LoadingProgress().width(18).height(18)
          Text($r('app.string.weibo_comments_loading'))
            .fontSize(fs(13, this.fontScale))
            .fontColor(Theme.textSecondary(this.isDark))
        }
      } else if (this.comments.length === 0) {
        Text($r('app.string.weibo_no_comments'))
          .fontSize(fs(13, this.fontScale))
          .fontColor(Theme.textSecondary(this.isDark))
      } else {
        ForEach(this.comments, (comment: WeiboComment): void => {
          Row({ space: Spacing.sm }) {
            if (comment.userAvatar.length > 0) {
              Image(comment.userAvatar)
                .width(34)
                .height(34)
                .borderRadius(Radius.full)
                .objectFit(ImageFit.Cover)
            }
            Column({ space: 3 }) {
              Row() {
                Text(comment.userName)
                  .fontSize(fs(13, this.fontScale))
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Theme.textPrimary(this.isDark))
                  .layoutWeight(1)
                Text(`${comment.likeCount}`)
                  .fontSize(fs(12, this.fontScale))
                  .fontColor(Theme.textSecondary(this.isDark))
              }
              .width('100%')
              Text(comment.text)
                .fontSize(fs(14, this.fontScale))
                .lineHeight(fs(21, this.fontScale))
                .fontColor(Theme.textPrimary(this.isDark))
                .width('100%')
              Text(comment.createdAt)
                .fontSize(fs(11, this.fontScale))
                .fontColor(Theme.textSecondary(this.isDark))
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .padding({ top: Spacing.sm, bottom: Spacing.md })
          .border({ width: { bottom: 0.5 }, color: Theme.manualGlassBorder() })
        }, (comment: WeiboComment): string => comment.id)
      }
    }
    .width('100%')
    .padding(Spacing.lg)
    .backgroundColor(Theme.bgCard(this.isDark))
    .borderRadius(Radius.postCard)
    .margin({ top: Spacing.md })
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

  private capsuleMaterial(materialEnabled: boolean): uiMaterial.Material | undefined {
    if (!materialEnabled) {
      return undefined;
    }
    if (deviceInfo.apiAvailable('26.0.0')) {
      if (!MaterialManager.isSupported()) {
        return undefined;
      }
      try {
        return new uiMaterial.ImmersiveMaterial({
          style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
          interactive: true,
          applyShadow: false,
          colorInvert: true,
          lightEffect: { color: Theme.brand() }
        });
      } catch (e) {
        return undefined;
      }
    }
    return undefined;
  }

  private controlMaterial(materialEnabled: boolean): uiMaterial.Material | undefined {
    if (!materialEnabled) {
      return undefined;
    }
    if (deviceInfo.apiAvailable('26.0.0')) {
      if (!MaterialManager.isSupported()) {
        return undefined;
      }
      try {
        return new uiMaterial.ImmersiveMaterial({
          style: uiMaterial.ImmersiveStyle.THIN,
          interactive: true,
          applyShadow: false,
          colorInvert: true,
          lightEffect: { color: Theme.brand() }
        });
      } catch (e) {
        return undefined;
      }
    }
    return undefined;
  }

  @Builder
  CommentAvatarButton(materialEnabled: boolean) {
    Button({ type: ButtonType.Circle, stateEffect: true }) {
      this.CommentAvatar()
    }
    .width(42)
    .height(42)
    .padding(1)
    .backgroundColor(materialEnabled ? Color.Transparent : Theme.segGlass(this.isDark, false))
    .borderRadius(21)
    .clip(true)
    .systemMaterial(this.controlMaterial(materialEnabled))
  }

  @Builder
  CommentToolButton(symbol: Resource, materialEnabled: boolean) {
    Button({ type: ButtonType.Circle, stateEffect: true }) {
      SymbolGlyph(symbol)
        .fontSize(fs(22, this.fontScale))
        .fontColor([$r('sys.color.icon_primary')])
    }
    .width(42)
    .height(42)
    .backgroundColor(materialEnabled ? Color.Transparent : Theme.segGlass(this.isDark, false))
    .borderRadius(21)
    .clip(true)
    .systemMaterial(this.controlMaterial(materialEnabled))
  }

  @Builder
  CommentComposerContent(materialEnabled: boolean) {
    Row({ space: 6 }) {
      this.CommentAvatarButton(materialEnabled)
      TextInput({ text: this.commentDraft, placeholder: $r('app.string.weibo_comment_placeholder') })
        .layoutWeight(1)
        .height(48)
        .fontSize(fs(17, this.fontScale))
        .backgroundColor(materialEnabled ? Color.Transparent : Theme.segGlass(this.isDark, false))
        .fontColor(Theme.textPrimary(this.isDark))
        .placeholderColor(Theme.textSecondary(this.isDark))
        .borderRadius(Radius.full)
        .clip(true)
        .padding({ left: Spacing.md, right: Spacing.md })
        .onChange((value: string): void => { this.commentDraft = value; })
        .systemMaterial(this.controlMaterial(materialEnabled))
      this.CommentToolButton($r('sys.symbol.picture'), materialEnabled)
      Button({ type: ButtonType.Circle, stateEffect: true }) {
        SymbolGlyph($r('sys.symbol.paperplane_fill'))
          .fontSize(fs(21, this.fontScale))
          .fontColor([this.commentDraft.trim().length > 0 && !this.commentSending
            ? $r('sys.color.icon_emphasize') : $r('sys.color.icon_primary')])
      }
      .width(42)
      .height(42)
      .backgroundColor(materialEnabled ? Color.Transparent : Theme.segGlass(this.isDark, false))
      .borderRadius(21)
      .clip(true)
      .enabled(this.commentDraft.trim().length > 0 && !this.commentSending)
      .accessibilityText($r('app.string.weibo_send_comment'))
      .onClick(() => { this.sendComment(); })
      .systemMaterial(this.controlMaterial(materialEnabled))
    }
    .width('100%')
    .height(64)
    .padding({ left: 10, right: 8 })
    .borderRadius(32)
    .clip(true)
    .backgroundColor(materialEnabled ? Color.Transparent : Theme.bgCard(this.isDark))
    .border({ width: materialEnabled ? 0 : 1, color: Theme.manualGlassBorder() })
    .systemMaterial(this.capsuleMaterial(materialEnabled))
  }

  /** HDS floating tab bar is HarmonyX's reply-composer capsule shell. */
  @Builder
  CommentComposerCapsule() {
    // HDS 悬浮栏和其 systemMaterialEffect 从 6.1.0(23) 即可用；
    // 不要将它错误地与 API 26 的 ArkUI uiMaterial 绑在一起。
    if (deviceInfo.apiAvailable('6.1.0(23)')) {
      HdsTabs() {
        TabContent() {
        }
        .tabBar(this.CommentComposerContent(true))
      }
      .scrollable(false)
      .barPosition(BarPosition.End)
      .barMode(BarMode.Fixed)
      .barHeight('100%')
      .barWidth('100%')
      .barFloatingStyle({
        lightColor: Theme.brand(),
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
        },
        thermoCtrl: true
      })
      .width('100%')
      .height(64)
    } else {
      this.CommentComposerContent(false)
    }
  }

  @Builder
  BottomComposer() {
    Column() {
      this.CommentComposerCapsule()
    }
    .width('100%')
    .padding({ left: 12, right: 12, bottom: this.navigationIndicatorHeight + 12 })
  }

  @Builder
  DetailContent() {
    Stack({ alignContent: Alignment.Bottom }) {
      Scroll(this.detailScroller) {
        Column() {
          if (this.loading) {
            LoadingProgress().width(28).height(28).margin({ top: 120 })
          } else if (this.errorMessage.length > 0) {
            Column({ space: Spacing.md }) {
              Text(this.errorMessage)
                .fontSize(fs(14, this.fontScale))
                .fontColor(Theme.danger())
                .textAlign(TextAlign.Center)
              Button($r('app.string.weibo_load'))
                .fontSize(fs(14, this.fontScale))
                .onClick(() => { this.loadPost(); })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Center)
            .margin({ top: 120 })
          } else if (this.post !== null) {
            Column() {
              this.PostBody(this.post)
              this.CommentsSection()
            }
            .width('100%')
            .opacity(this.contentOpacity)
            .translate({ y: this.contentTranslateY })
            .scale({ x: this.contentScale, y: this.contentScale })
            .renderGroup(true)
          }
        }
        .width('100%')
        .padding({
          left: 12,
          right: 12,
          top: this.statusBarHeight + 64,
          bottom: this.navigationIndicatorHeight + 92
        })
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      if (this.post !== null && !this.loading) {
        this.BottomComposer()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg(this.isDark))
  }

  build() {
    HdsNavDestination() {
      this.DetailContent()
    }
    .titleMode(HdsNavDestinationTitleMode.MINI)
    .hideBackButton(true)
    .onBackPressed((): boolean => {
      this.popRoute();
      return true;
    })
    .bindToScrollable([this.detailScroller])
    .titleBar({
      avoidLayoutSafeArea: true,
      content: {
        stackBuilder: (): void => this.DetailTitleBar(),
        divider: { showType: DividerShowType.OFF }
      },
      style: {
        scrollEffectOpts: {
          enableScrollEffect: true,
          scrollEffectType: ScrollEffectType.GRADIENT_BLUR
        },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.IMMERSIVE,
          materialLevel: hdsMaterial.MaterialLevel.EXQUISITE
        }
      }
    })
    .backgroundColor(Theme.bg(this.isDark))
  }
}
