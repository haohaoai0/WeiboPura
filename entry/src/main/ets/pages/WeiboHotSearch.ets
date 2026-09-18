import { WeiboHotTopic } from '../model/WeiboModel';
import { curves } from '@kit.ArkUI';
import { WeiboService } from '../service/WeiboService';
import { ImmBlur, ImmMaterial, Radius, Spacing, Theme, fs, isDarkMode } from '../common/Theme';
import { EmptyView, ErrorView, LoadingView } from '../components/CommonComponents';

enum HotLoadState {
  Idle = 0,
  Loading = 1,
  Success = 2,
  Error = 3,
}

type TabAnimationDirection = 'left' | 'right';

/** Public Weibo hot-search board; no account cookie or visitor-session creation is needed. */
@Component
export struct WeiboHotSearch {
  pageScroller: Scroller = new Scroller();
  @Prop topInset: number = 64;
  @Prop @Watch('onEnter') animationTrigger: number = 0;
  @Prop @Watch('onExit') exitTrigger: number = 0;
  @State isDark: boolean = isDarkMode();
  @State state: HotLoadState = HotLoadState.Idle;
  @State topics: WeiboHotTopic[] = [];
  @State errorMessage: string = '';
  @State pageTranslateX: number = 0;
  @State pageOpacity: number = 1;
  @State isAnimating: boolean = false;
  @StorageLink('fontScale') fontScale: number = 1.0;
  @StorageLink('darkTick') @Watch('onDarkTick') darkTick: number = 0;

  aboutToAppear(): void {
    this.loadTopics();
  }

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

  private async loadTopics(): Promise<void> {
    this.state = HotLoadState.Loading;
    this.errorMessage = '';
    try {
      const result: WeiboHotTopic[] = await WeiboService.getInstance().fetchHotTopics(30);
      this.topics = result;
      this.state = HotLoadState.Success;
    } catch (error) {
      this.topics = [];
      this.errorMessage = (error as Error).message ?? '微博热搜加载失败，请稍后重试';
      this.state = HotLoadState.Error;
    }
  }

  @Builder
  TopicRow(topic: WeiboHotTopic) {
    Row({ space: Spacing.md }) {
      Text(`${topic.rank}`)
        .width(26)
        .fontSize(fs(14, this.fontScale))
        .fontWeight(topic.rank <= 3 ? FontWeight.Bold : FontWeight.Regular)
        .fontColor(topic.rank <= 3 ? Theme.brand() : Theme.textSecondary(this.isDark))
        .textAlign(TextAlign.Center)
      Column({ space: 4 }) {
        Row({ space: Spacing.sm }) {
          Text(topic.word)
            .fontSize(fs(15, this.fontScale))
            .fontColor(Theme.textPrimary(this.isDark))
            .fontWeight(FontWeight.Medium)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          if (topic.label.length > 0) {
            Text(topic.label)
              .fontSize(fs(11, this.fontScale))
              .fontColor(Theme.brand())
          }
        }
        .width('100%')
        Text(`${topic.heat}`)
          .fontSize(fs(11, this.fontScale))
          .fontColor(Theme.textTertiary(this.isDark))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
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

  build() {
    Scroll(this.pageScroller) {
      Column({ space: Spacing.md }) {
        Text($r('app.string.weibo_hot_hint'))
          .fontSize(fs(12, this.fontScale))
          .fontColor(Theme.textSecondary(this.isDark))
          .width('100%')
        if (this.state === HotLoadState.Loading) {
          LoadingView({ message: $r('app.string.weibo_loading') })
            .height(360)
        } else if (this.state === HotLoadState.Error) {
          ErrorView({ message: this.errorMessage, onRetry: (): void => { this.loadTopics(); } })
            .height(360)
        } else if (this.state === HotLoadState.Success && this.topics.length === 0) {
          EmptyView({ message: $r('app.string.weibo_hot_empty'), icon: '○' })
            .height(360)
        } else if (this.state === HotLoadState.Success) {
          Column({ space: Spacing.sm }) {
            ForEach(this.topics, (topic: WeiboHotTopic): void => {
              this.TopicRow(topic)
            }, (topic: WeiboHotTopic): string => `${topic.rank}_${topic.word}`)
          }
          .width('100%')
        } else {
          EmptyView({ message: $r('app.string.weibo_hot_empty'), icon: '○' })
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
