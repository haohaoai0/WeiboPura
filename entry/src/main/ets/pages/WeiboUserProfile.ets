import { WeiboPost, WeiboUser } from '../model/WeiboModel';
import { WeiboService, sanitizeHttpsUrl } from '../service/WeiboService';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ShareUtil } from '../common/ShareUtil';
import { ThreadCard, ThreadItemData } from '../components/CommonComponents';
import { ImmMaterial, Radius, Spacing, Theme, fs, isDarkMode } from '../common/Theme';
import { DividerShowType, HdsNavDestination, HdsNavDestinationTitleMode, ScrollEffectType, hdsMaterial } from '@kit.UIDesignKit';
import { WeiboPostDetailRouteParam } from './WeiboPostDetail';
import { syncWeiboSplitNavigation } from '../common/WeiboNavigationLayout';
import { WeiboAuthManager } from '../service/WeiboAuthManager';
import { Haptic } from '../common/Haptic';
import { WeiboSearchResultRouteParam } from './WeiboSearchResult';
import { withWeiboLike } from '../common/WeiboPostState';

/** Explicit route input so profile navigation never depends on a card's transient state. */
export interface WeiboUserProfileRouteParam {
  userId: string;
  userName: string;
}

@Builder
export function WeiboUserProfileBuilder(): void {
  WeiboUserProfile()
}

/** Public profile and recent posts for the author selected from a timeline card. */
@Component
export struct WeiboUserProfile {
  @State isDark: boolean = isDarkMode();
  @State userId: string = '';
  @State fallbackName: string = '';
  @State profile: WeiboUser | null = null;
  @State posts: WeiboPost[] = [];
  @State loading: boolean = true;
  @State loadingMore: boolean = false;
  @State hasMore: boolean = true;
  @State currentPage: number = 1;
  @State errorMessage: string = '';
  @State isFollowing: boolean = false;
  @State followLoading: boolean = false;
  @State likingIds: string[] = [];
  @State avatarFailed: boolean = false;
  private profileEpoch: number = 0;
  @StorageLink('weiboAuthTick') @Watch('onWeiboAuthTick') weiboAuthTick: number = 0;
  @StorageLink('fontScale') fontScale: number = 1.0;
  @StorageLink('weibo_sync_like') @Watch('onGlobalLikeSync') globalLikeSync: string = '';
  @StorageLink('weibo_sync_follow') @Watch('onGlobalFollowSync') globalFollowSync: string = '';
  /** Actual system top inset, populated by EntryAbility for each window. */
  @StorageLink('weibo.status_bar_height') statusBarHeight: number = 0;
  @Consume('weiboNavStack') weiboNavStack: NavPathStack;
  private profileScroller: Scroller = new Scroller();

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
          return withWeiboLike(p, liked);
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
      if (this.userId === userId && this.isFollowing !== followed) {
        this.isFollowing = followed;
        if (this.profile !== null) {
          this.profile.following = followed;
        }
      }
    }
  }

  aboutToAppear(): void {
    setTimeout((): void => { this.loadRouteProfile(); }, 50);
  }

  private async loadRouteProfile(): Promise<void> {
    const params: WeiboUserProfileRouteParam[] =
      this.weiboNavStack.getParamByName('WeiboUserProfile') as WeiboUserProfileRouteParam[];
    if (params === undefined || params === null || params.length === 0) {
      this.loading = false;
      this.errorMessage = '用户资料参数不完整';
      return;
    }
    const routeParam: WeiboUserProfileRouteParam = params[params.length - 1];
    this.userId = typeof routeParam.userId === 'string' ? routeParam.userId.trim() : '';
    this.fallbackName = typeof routeParam.userName === 'string' ? routeParam.userName.trim() : '';
    if (this.userId.length === 0 && this.fallbackName.length > 0) {
      this.loading = true;
      try {
        const resolvedId: string = await WeiboService.getInstance().resolveUserIdByName(this.fallbackName);
        if (resolvedId.length > 0) {
          this.userId = resolvedId;
        }
      } catch (_e) {}
    }
    if (this.userId.length === 0) {
      this.loading = false;
      this.errorMessage = '该用户资料暂不可用';
      return;
    }
    await this.loadProfile();
  }

  private onWeiboAuthTick(): void {
    this.profileEpoch++;
    this.profile = null;
    this.posts = [];
    this.isFollowing = false;
    this.followLoading = false;
    this.likingIds = [];
    this.currentPage = 1;
    this.hasMore = true;
    this.loadingMore = false;
    if (!WeiboAuthManager.getInstance().isSessionChanging()) { this.loadProfile(); }
  }

  private async loadProfile(): Promise<void> {
    if (this.userId.length === 0) {
      return;
    }
    const epoch: number = ++this.profileEpoch;
    this.loading = true;
    this.errorMessage = '';
    this.avatarFailed = false;
    try {
      const service: WeiboService = WeiboService.getInstance();
      const profile: WeiboUser = await service.fetchUserProfile(this.userId);
      if (epoch !== this.profileEpoch) { return; }
      const posts: WeiboPost[] = await service.fetchUserTimeline(this.userId, 1);
      if (epoch !== this.profileEpoch) { return; }
      this.profile = profile;
      this.isFollowing = profile.following;
      this.posts = posts;
      this.currentPage = 1;
      this.hasMore = posts.length > 0;
    } catch (error) {
      if (epoch !== this.profileEpoch) { return; }
      this.profile = null;
      this.posts = [];
      this.errorMessage = (error as Error).message ?? '用户资料加载失败，请稍后重试';
    } finally {
      if (epoch === this.profileEpoch) { this.loading = false; }
    }
  }

  /** 滚动到底加载下一页：与首页 loadMore 同口径（去重追加，空页即到底）。 */
  private async loadMorePosts(): Promise<void> {
    if (this.loading || this.loadingMore || !this.hasMore || this.userId.length === 0) {
      return;
    }
    const epoch: number = this.profileEpoch;
    this.loadingMore = true;
    try {
      const nextPage: number = this.currentPage + 1;
      const result: WeiboPost[] = await WeiboService.getInstance().fetchUserTimeline(this.userId, nextPage);
      if (epoch !== this.profileEpoch) { return; }
      const added: WeiboPost[] = result.filter((item: WeiboPost): boolean =>
        !this.posts.some((old: WeiboPost): boolean => old.id === item.id));
      if (added.length > 0) {
        this.posts = this.posts.concat(added);
        this.currentPage = nextPage;
        this.hasMore = result.length > 0;
      } else {
        this.hasMore = false;
      }
    } catch (error) {
      if (epoch === this.profileEpoch) {
        this.getUIContext().getPromptAction().showToast({ message: (error as Error).message ?? '加载更多微博失败，请重试' });
      }
    } finally {
      if (epoch === this.profileEpoch) { this.loadingMore = false; }
    }
  }

  private sharePost(post: WeiboPost): void {
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    ShareUtil.shareLink(this.getUIContext(), context, `https://m.weibo.cn/detail/${post.id}`,
      post.userName, post.text);
  }

  private toThreadCard(post: WeiboPost): ThreadItemData {
    const original: WeiboPost | null = post.repost;
    const mediaPost: WeiboPost = (post.pictures.length > 0 || post.videoUrl.length > 0 || original === null)
      ? post : original;
    const firstImage: string = mediaPost.pictures.length > 0 ? mediaPost.pictures[0] : '';
    return {
      tid: post.id,
      postId: post.id,
      forumId: '',
      title: post.text.length > 0 ? post.text : post.userName,
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
      videoAspectRatio: mediaPost.videoAspectRatio,
      createTime: post.createdAt,
      isTop: false,
      isGood: false,
    };
  }

  private openPost(post: WeiboPost): void {
    if (post.id.length === 0) {
      return;
    }
    WeiboService.getInstance().rememberPost(post);
    WeiboService.getInstance().prefetchComments(post.id);
    const param: WeiboPostDetailRouteParam = { postId: post.id, post: post };
    this.weiboNavStack.pushPath({ name: 'WeiboPostDetail', param: param });
  }

  private popRoute(): void {
    this.weiboNavStack.pop();
    syncWeiboSplitNavigation(this.weiboNavStack);
  }

  private openImagePreview(urls: string[], index: number, post: WeiboPost): void {
    if (urls.length === 0) {
      return;
    }
    this.getUIContext().getRouter().pushUrl({ url: 'pages/ImagePreview', params: { urls: urls, index: index, pictureVideos: (post.pictures.length > 0 ? post : post.repost)?.pictureVideos ?? {} } });
  }

  private async toggleFollow(): Promise<void> {
    if (this.followLoading || this.userId.length === 0) {
      return;
    }
    if (!WeiboAuthManager.getInstance().hasCookie()) {
      this.getUIContext().getPromptAction().showToast({ message: '请先在“我的”页面登录微博' });
      return;
    }
    const revision: number = WeiboAuthManager.getInstance().getSessionRevision();
    this.followLoading = true;
    try {
      Haptic.light();
      if (this.isFollowing) {
        await WeiboService.getInstance().unfollowUser(this.userId);
        WeiboAuthManager.getInstance().assertSession(revision);
        this.isFollowing = false;
        this.getUIContext().getPromptAction().showToast({ message: '已取消关注' });
      } else {
        await WeiboService.getInstance().followUser(this.userId);
        WeiboAuthManager.getInstance().assertSession(revision);
        this.isFollowing = true;
        this.getUIContext().getPromptAction().showToast({ message: '已关注' });
      }
    } catch (e) {
      if (revision !== WeiboAuthManager.getInstance().getSessionRevision()) { return; }
      const msg: string = (e as Error).message ?? '关注操作失败';
      this.getUIContext().getPromptAction().showToast({ message: msg });
    } finally {
      if (revision === WeiboAuthManager.getInstance().getSessionRevision()) { this.followLoading = false; }
    }
  }

  private openTopic(topic: string): void {
    const param: WeiboSearchResultRouteParam = { query: topic };
    this.weiboNavStack.pushPath({ name: 'WeiboSearchResult', param: param });
  }

  private openMention(name: string, id: string = ''): void {
    const param: WeiboUserProfileRouteParam = { userId: id, userName: name };
    this.weiboNavStack.pushPath({ name: 'WeiboUserProfile', param: param });
  }

  private async togglePostLike(post: WeiboPost): Promise<void> {
    if (this.likingIds.includes(post.id)) { return; }
    const revision: number = WeiboAuthManager.getInstance().getSessionRevision();
    this.likingIds = this.likingIds.concat([post.id]);
    try {
      await WeiboService.getInstance().setLike(post.id, !post.isLiked);
      WeiboAuthManager.getInstance().assertSession(revision);
      const updated: WeiboPost = withWeiboLike(post, !post.isLiked);
      this.posts = this.posts.map((item: WeiboPost): WeiboPost => item.id === post.id ? updated : item);
      Haptic.light();
    } catch (error) {
      if (revision === WeiboAuthManager.getInstance().getSessionRevision()) {
        this.getUIContext().getPromptAction().showToast({ message: (error as Error).message ?? '点赞失败，请重试' });
      }
    } finally {
      if (revision === WeiboAuthManager.getInstance().getSessionRevision()) {
        this.likingIds = this.likingIds.filter((id: string): boolean => id !== post.id);
      }
    }
  }

  @Builder
  ProfileHeader(currentProfile: WeiboUser) {
    Column({ space: Spacing.md }) {
      if (currentProfile.coverUrl.length > 0) {
        Image(currentProfile.coverUrl)
          .width('100%')
          .height(132)
          .objectFit(ImageFit.Cover)
          .borderRadius(Radius.postCard)
      } else {
        Stack() {
          SymbolGlyph($r('sys.symbol.person'))
            .fontSize(fs(36, this.fontScale))
            .fontColor([Theme.brand()])
        }
        .width('100%')
        .height(100)
        .backgroundColor(Theme.brandBg(this.isDark))
        .borderRadius(Radius.postCard)
        .alignContent(Alignment.Center)
      }
      Row({ space: Spacing.md }) {
        Stack() {
          Text(currentProfile.screenName.length > 0 ? currentProfile.screenName.substring(0, 1) : '微')
            .fontSize(fs(26, this.fontScale))
            .fontWeight(FontWeight.Bold)
            .fontColor(Color.White)
          if (currentProfile.avatarUrl.length > 0 && !this.avatarFailed) {
            Image(sanitizeHttpsUrl(currentProfile.avatarUrl))
              .width(72)
              .height(72)
              .borderRadius(Radius.full)
              .border({ width: 0.5, color: this.isDark ? 'rgba(255, 255, 255, 0.12)' : 'rgba(0, 0, 0, 0.08)', radius: Radius.full })
              .objectFit(ImageFit.Cover)
              .onError((err: ImageError) => {
                hilog.error(0x0A01, 'AvatarDebug', 'Profile avatar onError: url=%{public}s w=%{public}d h=%{public}d',
                  currentProfile.avatarUrl, err.componentWidth, err.componentHeight);
                this.avatarFailed = true;
              })
              .onComplete((msg) => {
                hilog.info(0x0A01, 'AvatarDebug', 'Profile avatar onComplete: url=%{public}s w=%{public}d h=%{public}d loadingStatus=%{public}d',
                  currentProfile.avatarUrl, msg?.width ?? 0, msg?.height ?? 0, msg?.loadingStatus ?? 0);
              })
          }
        }
        .width(72)
        .height(72)
        .backgroundColor(Theme.brand())
        .borderRadius(Radius.full)
        .alignContent(Alignment.Center)
        Column({ space: 4 }) {
          Text(currentProfile.screenName.length > 0 ? currentProfile.screenName : this.fallbackName)
            .fontSize(fs(20, this.fontScale))
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.textPrimary(this.isDark))
          if (currentProfile.verified && currentProfile.verifiedReason.length > 0) {
            Text(currentProfile.verifiedReason)
              .fontSize(fs(12, this.fontScale))
              .fontColor(Theme.brand())
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          Text(`@${currentProfile.id}`)
            .fontSize(fs(12, this.fontScale))
            .fontColor(Theme.textSecondary(this.isDark))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Button() {
          Row({ space: 4 }) {
            if (this.followLoading) {
              LoadingProgress()
                .width(14)
                .height(14)
                .color(this.isFollowing ? Theme.textSecondary(this.isDark) : Color.White)
            } else {
              SymbolGlyph(this.isFollowing ? $r('sys.symbol.checkmark') : $r('sys.symbol.plus'))
                .fontSize(fs(14, this.fontScale))
                .fontColor([this.isFollowing ? Theme.textSecondary(this.isDark) : Color.White])
            }
            Text(this.isFollowing ? '已关注' : '关注')
              .fontSize(fs(13, this.fontScale))
              .fontWeight(FontWeight.Medium)
              .fontColor(this.isFollowing ? Theme.textSecondary(this.isDark) : Color.White)
          }
        }
        .height(32)
        .padding({ left: 14, right: 14 })
        .backgroundColor(this.isFollowing ? (this.isDark ? '#26FFFFFF' : '#14000000') : Theme.brand())
        .borderRadius(Radius.full)
        .onClick((): void => {
          this.toggleFollow();
        })
      }
      .width('100%')
      if (currentProfile.description.length > 0) {
        Text(currentProfile.description)
          .fontSize(fs(14, this.fontScale))
          .lineHeight(fs(21, this.fontScale))
          .fontColor(Theme.textPrimary(this.isDark))
          .width('100%')
      }
      Row() {
        Text(`关注 ${currentProfile.followingCount}`)
          .layoutWeight(1)
          .fontSize(fs(13, this.fontScale))
          .fontColor(Theme.textSecondary(this.isDark))
        Text(`${currentProfile.followersCount} 粉丝`)
          .layoutWeight(1)
          .fontSize(fs(13, this.fontScale))
          .fontColor(Theme.textSecondary(this.isDark))
          .textAlign(TextAlign.Center)
        Text(`${currentProfile.statusesCount} 微博`)
          .layoutWeight(1)
          .fontSize(fs(13, this.fontScale))
          .fontColor(Theme.textSecondary(this.isDark))
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
  ProfileContent() {
    Scroll(this.profileScroller) {
      Column({ space: Spacing.md }) {
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
              .onClick((): void => { this.loadProfile(); })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
          .margin({ top: 120 })
        } else if (this.profile !== null) {
          this.ProfileHeader(this.profile)
          Text($r('app.string.weibo_profile_posts'))
            .fontSize(fs(17, this.fontScale))
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.textPrimary(this.isDark))
            .width('100%')
          if (this.posts.length === 0) {
            Text($r('app.string.weibo_profile_no_posts'))
              .width('100%')
              .fontSize(fs(13, this.fontScale))
              .fontColor(Theme.textSecondary(this.isDark))
              .textAlign(TextAlign.Center)
              .padding({ top: Spacing.xl, bottom: Spacing.xl })
          } else {
            ForEach(this.posts, (post: WeiboPost): void => {
              ThreadCard({
                item: this.toThreadCard(post),
                onTap: (_id: string): void => { this.openPost(post); },
                onAbstractTap: (): void => {
                  if (post.repost !== null) {
                    this.openPost(post.repost);
                  }
                },
                abstractIsLink: post.repost !== null,
                onComment: (_id: string): void => { this.openPost(post); },
                onShare: (): void => { this.sharePost(post); },
                onAvatarTap: (id: string, name: string): void => { this.openMention(name, id); },
                onTopicTap: (topic: string): void => { this.openTopic(topic); },
                onMentionTap: (name: string): void => { this.openMention(name); },
                onLike: (_id: string): void => { this.togglePostLike(post); },
                onImageTap: (urls: string[], index: number): void => { this.openImagePreview(urls, index, post); },
                skipImageCache: true
              })
            }, (post: WeiboPost): string => post.id)
            if (this.loadingMore) {
              Row({ space: Spacing.sm }) {
                LoadingProgress().width(20).height(20)
                Text('正在加载更多…')
                  .fontSize(fs(12, this.fontScale))
                  .fontColor(Theme.textTertiary(this.isDark))
              }
              .width('100%')
              .justifyContent(FlexAlign.Center)
              .padding({ top: Spacing.md, bottom: Spacing.md })
            } else if (!this.hasMore) {
              Text('已加载全部内容')
                .width('100%')
                .fontSize(fs(12, this.fontScale))
                .fontColor(Theme.textTertiary(this.isDark))
                .textAlign(TextAlign.Center)
                .padding({ top: Spacing.md, bottom: Spacing.md })
            }
          }
        }
      }
      .width('100%')
      .padding({
        left: Spacing.lg,
        right: Spacing.lg,
        top: this.statusBarHeight + 64,
        bottom: Spacing.xl
      })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .onScrollEdge((edge: Edge): void => {
      if (edge === Edge.Bottom) {
        this.loadMorePosts();
      }
    })
  }

  @Builder
  ProfileTitleBar() {
    Row() {
      Button() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(fs(28, this.fontScale))
          .fontColor([$r('sys.color.icon_primary')])
      }
      .width(44)
      .height(44)
      .backgroundColor(Color.Transparent)
      .systemMaterial(ImmMaterial.control())
      .borderRadius(Radius.full)
      .accessibilityText($r('app.string.weibo_back'))
      .onClick((): void => { this.popRoute(); })
      Text($r('app.string.weibo_profile_title'))
        .layoutWeight(1)
        .fontSize(fs(17, this.fontScale))
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.textPrimary(this.isDark))
        .textAlign(TextAlign.Center)
      Blank().width(44)
    }
    .width('100%')
    .height(64)
    .padding({ left: Spacing.lg, right: Spacing.lg })
  }

  build() {
    HdsNavDestination() {
      this.ProfileContent()
    }
    .titleMode(HdsNavDestinationTitleMode.MINI)
    .hideBackButton(true)
    .onBackPressed((): boolean => {
      this.popRoute();
      return true;
    })
    .bindToScrollable([this.profileScroller])
    .titleBar({
      avoidLayoutSafeArea: true,
      content: {
        stackBuilder: (): void => this.ProfileTitleBar(),
        divider: { showType: DividerShowType.OFF }
      },
      style: {
        scrollEffectOpts: { enableScrollEffect: true, scrollEffectType: ScrollEffectType.GRADIENT_BLUR },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.IMMERSIVE,
          materialLevel: hdsMaterial.MaterialLevel.EXQUISITE
        }
      }
    })
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg(this.isDark))
  }
}
