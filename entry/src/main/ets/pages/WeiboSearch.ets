import { ThreadCard, ThreadItemData, EmptyView, ErrorView, LoadingView } from '../components/CommonComponents';
import { curves } from '@kit.ArkUI';
import { WeiboPost, WeiboSuggestion } from '../model/WeiboModel';
import { WeiboService } from '../service/WeiboService';
import { ImmBlur, ImmMaterial, Radius, Spacing, Theme, fs, isDarkMode } from '../common/Theme';

enum SearchLoadState {
  Idle = 0,
  Loading = 1,
  Success = 2,
  Error = 3,
}

type TabAnimationDirection = 'left' | 'right';

/** Weibo search with live suggestions and posts from the mobile search container. */
@Component
export struct WeiboSearch {
  pageScroller: Scroller = new Scroller();
  @Prop topInset: number = 64;
  @Prop @Watch('onEnter') animationTrigger: number = 0;
  @Prop @Watch('onExit') exitTrigger: number = 0;
  onOpenPost: (post: WeiboPost) => void = () => {};
  onOpenUserProfile: (userId: string, userName: string) => void = () => {};
  @State isDark: boolean = isDarkMode();
  @StorageLink('weiboSearchQuery') keyword: string = '';
  @StorageLink('weiboSearchRequestTick') @Watch('onSearchRequested') searchRequestTick: number = 0;
  @State state: SearchLoadState = SearchLoadState.Idle;
  @State suggestions: WeiboSuggestion[] = [];
  @State posts: WeiboPost[] = [];
  @State errorMessage: string = '';
  @State pageTranslateX: number = 0;
  @State pageOpacity: number = 1;
  @State isAnimating: boolean = false;
  @StorageLink('fontScale') fontScale: number = 1.0;
  @StorageLink('darkTick') @Watch('onDarkTick') darkTick: number = 0;

  private onDarkTick(): void {
    this.isDark = isDarkMode();
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

  private onSearchRequested(): void {
    if (this.keyword.trim().length === 0) {
      this.posts = [];
      this.suggestions = [];
      this.state = SearchLoadState.Idle;
      return;
    }
    this.search();
  }

  private async search(): Promise<void> {
    if (this.keyword.trim().length === 0) {
      return;
    }
    this.state = SearchLoadState.Loading;
    this.errorMessage = '';
    try {
      const service: WeiboService = WeiboService.getInstance();
      this.posts = await service.fetchSearchPosts(this.keyword, 1);
      try {
        this.suggestions = await service.fetchSuggestions(this.keyword, 8);
      } catch (error) {
        this.suggestions = [];
      }
      this.state = SearchLoadState.Success;
    } catch (error) {
      this.suggestions = [];
      this.posts = [];
      this.errorMessage = (error as Error).message ?? '微博搜索加载失败，请稍后重试';
      this.state = SearchLoadState.Error;
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

  @Builder
  SuggestionRow(item: WeiboSuggestion) {
    Row({ space: Spacing.sm }) {
      SymbolGlyph(item.isHot ? $r('sys.symbol.flame_fill') : $r('sys.symbol.magnifyingglass'))
        .fontSize(fs(18, this.fontScale))
        .fontColor([item.isHot ? Theme.brand() : Theme.textSecondary(this.isDark)])
      Text(item.word)
        .fontSize(fs(15, this.fontScale))
        .fontColor(Theme.textPrimary(this.isDark))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Text(`${item.count}`)
        .fontSize(fs(12, this.fontScale))
        .fontColor(Theme.textTertiary(this.isDark))
    }
    .width('100%')
    .height(52)
    .padding({ left: Spacing.lg, right: Spacing.lg })
    .backgroundColor(Theme.sheetGlass(this.isDark))
    .backgroundBlurStyle(BlurStyle.Regular, { scale: 0.85 })
    .border({ width: 0.5, color: Theme.manualGlassBorder() })
    .shadow(Theme.glassShadowStyle())
    .systemMaterial(ImmMaterial.rowItem())
    .borderRadius(Radius.lg)
    .onClick((): void => {
      this.keyword = item.word;
      this.search();
    })
  }

  build() {
    Scroll(this.pageScroller) {
      Column({ space: Spacing.md }) {
        if (this.state === SearchLoadState.Loading) {
          LoadingView({ message: $r('app.string.weibo_loading') })
            .height(360)
        } else if (this.state === SearchLoadState.Error) {
          ErrorView({ message: this.errorMessage, onRetry: (): void => { this.search(); } })
            .height(360)
        } else if (this.state === SearchLoadState.Success && this.posts.length === 0 && this.suggestions.length === 0) {
          EmptyView({ message: $r('app.string.weibo_search_empty'), icon: '⌕' })
            .height(360)
        } else if (this.state === SearchLoadState.Success) {
          Column({ space: Spacing.sm }) {
            ForEach(this.posts, (post: WeiboPost): void => {
              ThreadCard({
                item: this.toThreadCard(post),
                onTap: (_id: string): void => { this.openPost(post); },
                onComment: (_id: string): void => { this.openPost(post); },
                onAvatarTap: (id: string, name: string): void => { this.openUserProfile(id, name); },
                onImageTap: (urls: string[], index: number): void => { this.openImagePreview(urls, index); },
                skipImageCache: true,
              })
            }, (post: WeiboPost): string => post.id)
            ForEach(this.suggestions, (item: WeiboSuggestion): void => {
              this.SuggestionRow(item)
            }, (item: WeiboSuggestion): string => item.word)
          }
          .width('100%')
        } else {
          EmptyView({ message: $r('app.string.weibo_search_empty'), icon: '⌕' })
            .height(360)
        }
      }
      .width('100%')
      .padding({ top: this.topInset, left: Spacing.lg, right: Spacing.lg, bottom: 120 })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .backgroundColor(Theme.bg(this.isDark))
    .translate({ x: this.pageTranslateX })
    .opacity(this.pageOpacity)
  }
}
