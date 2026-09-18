import { WeiboPost, WeiboUser } from '../model/WeiboModel';
import { WeiboService } from '../service/WeiboService';
import { ThreadCard, ThreadItemData } from '../components/CommonComponents';
import { ImmMaterial, Radius, Spacing, Theme, fs, isDarkMode } from '../common/Theme';
import { DividerShowType, HdsNavDestination, HdsNavDestinationTitleMode, ScrollEffectType, hdsMaterial } from '@kit.UIDesignKit';
import { WeiboPostDetailRouteParam } from './WeiboPostDetail';
import { syncWeiboSplitNavigation } from '../common/WeiboNavigationLayout';

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
  @State errorMessage: string = '';
  @StorageLink('fontScale') fontScale: number = 1.0;
  /** Actual system top inset, populated by EntryAbility for each window. */
  @StorageLink('weibo.status_bar_height') statusBarHeight: number = 0;
  @Consume('weiboNavStack') weiboNavStack: NavPathStack;
  private profileScroller: Scroller = new Scroller();

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
    if (this.userId.length === 0) {
      this.loading = false;
      this.errorMessage = '该用户资料暂不可用';
      return;
    }
    await this.loadProfile();
  }

  private async loadProfile(): Promise<void> {
    if (this.userId.length === 0) {
      return;
    }
    this.loading = true;
    this.errorMessage = '';
    try {
      const service: WeiboService = WeiboService.getInstance();
      this.profile = await service.fetchUserProfile(this.userId);
      this.posts = await service.fetchUserTimeline(this.userId, 1);
    } catch (error) {
      this.profile = null;
      this.posts = [];
      this.errorMessage = (error as Error).message ?? '用户资料加载失败，请稍后重试';
    } finally {
      this.loading = false;
    }
  }

  private toThreadCard(post: WeiboPost): ThreadItemData {
    const firstImage: string = post.pictures.length > 0 ? post.pictures[0] : '';
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
      return;
    }
    WeiboService.getInstance().rememberPost(post);
    const param: WeiboPostDetailRouteParam = { postId: post.id };
    this.weiboNavStack.pushPath({ name: 'WeiboPostDetail', param: param });
  }

  private popRoute(): void {
    this.weiboNavStack.pop();
    syncWeiboSplitNavigation(this.weiboNavStack);
  }

  private openImagePreview(urls: string[], index: number): void {
    if (urls.length === 0) {
      return;
    }
    this.getUIContext().getRouter().pushUrl({ url: 'pages/ImagePreview', params: { urls: urls, index: index } });
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
            .fontColor([$r('sys.color.icon_emphasize')])
        }
        .width('100%')
        .height(100)
        .backgroundColor(Theme.brandBg(this.isDark))
        .borderRadius(Radius.postCard)
        .alignContent(Alignment.Center)
      }
      Row({ space: Spacing.md }) {
        if (currentProfile.avatarUrl.length > 0) {
          Image(currentProfile.avatarUrl)
            .width(72)
            .height(72)
            .borderRadius(Radius.full)
            .objectFit(ImageFit.Cover)
        } else {
          Stack() {
            Text(currentProfile.screenName.length > 0 ? currentProfile.screenName.substring(0, 1) : '微')
              .fontSize(fs(26, this.fontScale))
              .fontWeight(FontWeight.Bold)
              .fontColor(Color.White)
          }
          .width(72)
          .height(72)
          .backgroundColor(Theme.brand())
          .borderRadius(Radius.full)
          .alignContent(Alignment.Center)
        }
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
                onComment: (_id: string): void => { this.openPost(post); },
                onAvatarTap: (_id: string, _name: string): void => { this.openPost(post); },
                onImageTap: (urls: string[], index: number): void => { this.openImagePreview(urls, index); },
                skipImageCache: true
              })
            }, (post: WeiboPost): string => post.id)
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
