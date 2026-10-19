import { WeiboHotTopic, WeiboSearchSuggestionBundle, WeiboSuggestion, WeiboUser } from '../model/WeiboModel';
import { curves } from '@kit.ArkUI';
import { WeiboService, sanitizeHttpsUrl } from '../service/WeiboService';
import { CacheManager } from '../cache/CacheManager';
import { CACHE_KEY } from '../common/Constants';
import { ImmBlur, ImmMaterial, Radius, Spacing, Theme, fs, isDarkMode } from '../common/Theme';
import { EmptyView, ErrorView, LoadingView } from '../components/CommonComponents';
import { Haptic } from '../common/Haptic';

enum HotLoadState {
  Idle = 0,
  Loading = 1,
  Success = 2,
  Error = 3,
}

interface HighlightSpanPart {
  text: string;
  isMatch: boolean;
}

/** Public Weibo discover board with real-time topics and live search autocomplete. */
@Component
export struct WeiboHotSearch {
  pageScroller: Scroller = new Scroller();
  @Prop topInset: number = 64;
  @StorageLink('weibo.status_bar_height') statusBarHeight: number = 0;
  @Prop @Watch('onEnter') animationTrigger: number = 0;
  @Prop exitTrigger: number = 0;
  onSelectTopic: (topic: WeiboHotTopic) => void = () => {};
  onOpenUserProfile: (userId: string, userName: string) => void = () => {};
  onScrollDirection: (visible: boolean) => void = () => {};
  @State searchKeyword: string = '';
  @State isDark: boolean = isDarkMode();
  @State isRefreshing: boolean = false;
  @State state: HotLoadState = HotLoadState.Idle;
  @State topics: WeiboHotTopic[] = [];
  @State errorMessage: string = '';
  @State suggestUsers: WeiboUser[] = [];
  @State suggestions: WeiboSuggestion[] = [];
  @State isSuggestLoading: boolean = false;
  @StorageLink('weiboSearchHistory') searchHistory: string[] = [];
  @StorageLink('fontScale') fontScale: number = 1.0;
  @StorageLink('darkTick') @Watch('onDarkTick') darkTick: number = 0;
  private debounceTimer: number = -1;

  aboutToAppear(): void {
    this.loadSearchHistory();
    this.loadTopics();
  }

  private async loadSearchHistory(): Promise<void> {
    try {
      const raw: string | undefined = await CacheManager.getInstance().get(CACHE_KEY.WEIBO_SEARCH_HISTORY);
      if (raw && raw.length > 0) {
        const list: string[] = JSON.parse(raw) as string[];
        if (Array.isArray(list)) {
          this.searchHistory = list;
          AppStorage.setOrCreate<string[]>('weiboSearchHistory', list);
        }
      }
    } catch (_) {
      // 容错忽略解析异常
    }
  }

  aboutToDisappear(): void {
    if (this.debounceTimer !== -1) {
      clearTimeout(this.debounceTimer);
      this.debounceTimer = -1;
    }
  }

  private onDarkTick(): void {
    this.isDark = isDarkMode();
  }

  private onEnter(): void {
    if (this.topics.length === 0 || this.state === HotLoadState.Error) {
      this.loadTopics();
    }
  }

  private async loadTopics(isRefresh: boolean = false): Promise<void> {
    if (!isRefresh) {
      this.state = HotLoadState.Loading;
    }
    this.errorMessage = '';
    try {
      const result: WeiboHotTopic[] = await WeiboService.getInstance().fetchHotTopics(30);
      this.topics = result;
      this.state = HotLoadState.Success;
    } catch (error) {
      if (!isRefresh || this.topics.length === 0) {
        this.topics = [];
        this.errorMessage = (error as Error).message ?? '微博热搜加载失败，请稍后重试';
        this.state = HotLoadState.Error;
      }
    } finally {
      this.isRefreshing = false;
      if (isRefresh) {
        setTimeout((): void => {
          try {
            this.pageScroller.scrollEdge(Edge.Top);
          } catch (_e) {}
        }, 100);
      }
    }
  }

  private formatHeat(heat: number): string {
    if (heat <= 0) {
      return '';
    }
    if (heat >= 100000000) {
      return `${(heat / 100000000).toFixed(1)}亿`;
    }
    if (heat >= 10000) {
      return `${(heat / 10000).toFixed(1)}万`;
    }
    return `${heat}`;
  }

  private labelBgColor(label: string): ResourceColor {
    if (label === '爆' || label === '热' || label === '沸') {
      return Theme.brand();
    }
    if (label === '新') {
      return '#FFF58220';
    }
    if (label === '荐' || label === '商') {
      return '#FF2E75B6';
    }
    return Theme.brand();
  }

  private onKeywordChanged(val: string): void {
    this.searchKeyword = val;
    const clean: string = val.trim();
    if (this.debounceTimer !== -1) {
      clearTimeout(this.debounceTimer);
      this.debounceTimer = -1;
    }
    if (clean.length === 0) {
      this.suggestUsers = [];
      this.suggestions = [];
      this.isSuggestLoading = false;
      return;
    }
    this.isSuggestLoading = true;
    this.debounceTimer = setTimeout((): void => {
      this.loadSuggestions(clean);
    }, 220);
  }

  private async loadSuggestions(query: string): Promise<void> {
    try {
      const bundle: WeiboSearchSuggestionBundle = await WeiboService.getInstance().fetchSearchSuggestions(query, 10);
      if (this.searchKeyword.trim() === query) {
        this.suggestUsers = bundle.users;
        this.suggestions = bundle.suggestions;
      }
    } catch (_e) {
      if (this.searchKeyword.trim() === query) {
        this.suggestUsers = [];
        this.suggestions = [];
      }
    } finally {
      if (this.searchKeyword.trim() === query) {
        this.isSuggestLoading = false;
      }
    }
  }

  private executeSearch(keyword: string): void {
    const trimmed: string = keyword.trim();
    if (trimmed.length === 0) {
      return;
    }
    const existing: string[] = this.searchHistory.filter((k: string): boolean => k !== trimmed);
    const updated: string[] = [trimmed].concat(existing).slice(0, 10);
    this.searchHistory = updated;
    AppStorage.setOrCreate<string[]>('weiboSearchHistory', updated);
    CacheManager.getInstance().put(CACHE_KEY.WEIBO_SEARCH_HISTORY, JSON.stringify(updated)).catch((): void => {});

    const customTopic: WeiboHotTopic = {
      rank: 0,
      word: trimmed,
      heat: 0,
      label: '',
      query: trimmed
    };
    this.onSelectTopic(customTopic);
  }

  private insertSuggestion(word: string): void {
    const cleanWord: string = word.replace(/^#|#$/g, '').trim();
    this.searchKeyword = cleanWord;
    this.onKeywordChanged(cleanWord);
  }

  private clearSearch(): void {
    this.searchKeyword = '';
    this.suggestUsers = [];
    this.suggestions = [];
    this.isSuggestLoading = false;
    if (this.debounceTimer !== -1) {
      clearTimeout(this.debounceTimer);
      this.debounceTimer = -1;
    }
  }

  private splitByQuery(fullText: string, query: string): HighlightSpanPart[] {
    const q: string = query.trim().replace(/^#|#$/g, '');
    if (q.length === 0 || fullText.length === 0) {
      return [{ text: fullText, isMatch: false }];
    }
    const parts: HighlightSpanPart[] = [];
    const lowerText: string = fullText.toLowerCase();
    const lowerQuery: string = q.toLowerCase();
    let startIdx: number = 0;
    let matchIdx: number = lowerText.indexOf(lowerQuery, startIdx);
    while (matchIdx !== -1) {
      if (matchIdx > startIdx) {
        parts.push({ text: fullText.substring(startIdx, matchIdx), isMatch: false });
      }
      parts.push({ text: fullText.substring(matchIdx, matchIdx + q.length), isMatch: true });
      startIdx = matchIdx + q.length;
      matchIdx = lowerText.indexOf(lowerQuery, startIdx);
    }
    if (startIdx < fullText.length) {
      parts.push({ text: fullText.substring(startIdx), isMatch: false });
    }
    return parts;
  }

  @Builder
  HighlightText(fullText: string, query: string, fontSizeVp: number = 14) {
    Text() {
      ForEach(this.splitByQuery(fullText, query), (part: HighlightSpanPart, idx: number): void => {
        if (part.isMatch) {
          Span(part.text)
            .fontSize(fs(fontSizeVp, this.fontScale))
            .fontColor(Theme.brand())
            .fontWeight(FontWeight.Bold)
        } else {
          Span(part.text)
            .fontSize(fs(fontSizeVp, this.fontScale))
            .fontColor(Theme.textPrimary(this.isDark))
        }
      }, (_part: HighlightSpanPart, idx: number): string => `${idx}`)
    }
  }

  @Builder
  UserDirectCard(user: WeiboUser) {
    Row({ space: Spacing.md }) {
      Stack() {
        SymbolGlyph($r('sys.symbol.person'))
          .fontSize(22)
          .fontColor([Color.White])
        if (user.avatarUrl.length > 0) {
          Image(sanitizeHttpsUrl(user.avatarUrl))
            .width(42)
            .height(42)
            .borderRadius(21)
            .objectFit(ImageFit.Cover)
        }
      }
      .width(42)
      .height(42)
      .borderRadius(21)
      .backgroundColor(Theme.brand())
      .alignContent(Alignment.Center)

      Column({ space: 4 }) {
        Row({ space: 4 }) {
          this.HighlightText(user.screenName, this.searchKeyword, 15)
          if (user.verified) {
            SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
              .fontSize(13)
              .fontColor([Theme.brand()])
          }
        }
        if (user.description.length > 0) {
          Text(user.description)
            .fontSize(fs(12, this.fontScale))
            .fontColor(Theme.textSecondary(this.isDark))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        } else if (user.followersCount.length > 0) {
          Text(`粉丝 ${user.followersCount}`)
            .fontSize(fs(12, this.fontScale))
            .fontColor(Theme.textSecondary(this.isDark))
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Button('主页 ↗')
        .height(30)
        .fontSize(fs(12, this.fontScale))
        .fontColor(Theme.brand())
        .backgroundColor(Theme.brandBg(this.isDark))
        .borderRadius(Radius.full)
        .padding({ left: 10, right: 10 })
        .onClick((): void => {
          this.onOpenUserProfile(user.id, user.screenName);
        })
    }
    .width('100%')
    .padding({ left: Spacing.lg, right: Spacing.lg, top: 12, bottom: 12 })
    .backgroundColor(Theme.bgCard(this.isDark))
    .borderRadius(Radius.postCard)
    .border({ width: 0.5, color: Theme.cardBorder(this.isDark) })
    .shadow(Theme.feedCardShadow(this.isDark))
    .onClick((): void => {
      this.onOpenUserProfile(user.id, user.screenName);
    })
  }

  @Builder
  SuggestionRow(item: WeiboSuggestion, isLast: boolean = false) {
    Row({ space: Spacing.md }) {
      if (item.isTopic) {
        Text('#')
          .fontSize(fs(16, this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.brand())
          .width(20)
          .textAlign(TextAlign.Center)
      } else {
        SymbolGlyph($r('sys.symbol.magnifyingglass'))
          .fontSize(fs(16, this.fontScale))
          .fontColor([Theme.textTertiary(this.isDark)])
          .width(20)
      }

      Row({ space: 6 }) {
        this.HighlightText(item.word, this.searchKeyword, 14)
        if (item.isTopic) {
          Text('话题')
            .fontSize(fs(10, this.fontScale))
            .fontColor(Theme.brand())
            .backgroundColor(Theme.brandBg(this.isDark))
            .borderRadius(4)
            .padding({ left: 4, right: 4, top: 1, bottom: 1 })
        } else if (item.isHot) {
          Text('热')
            .fontSize(fs(10, this.fontScale))
            .fontColor(Color.White)
            .backgroundColor(Theme.brand())
            .borderRadius(4)
            .padding({ left: 4, right: 4, top: 1, bottom: 1 })
        }
      }
      .layoutWeight(1)

      Button() {
        Text('↖')
          .fontSize(fs(16, this.fontScale))
          .fontColor(Theme.textTertiary(this.isDark))
      }
      .width(36)
      .height(36)
      .backgroundColor(Color.Transparent)
      .borderRadius(Radius.full)
      .accessibilityText(`填入 ${item.word}`)
      .onClick((): void => {
        this.insertSuggestion(item.word);
      })
    }
    .width('100%')
    .padding({ left: Spacing.lg, right: Spacing.md, top: 12, bottom: 12 })
    .border(isLast ? { width: 0 } : { width: { bottom: 0.5 }, color: Theme.manualGlassBorder() })
    .onClick((): void => {
      this.executeSearch(item.word.replace(/^#|#$/g, ''));
    })
  }

  @Builder
  SearchHistorySection() {
    if (this.searchHistory.length > 0) {
      Column({ space: Spacing.sm }) {
        Row() {
          Text('最近搜索')
            .fontSize(fs(13, this.fontScale))
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.textSecondary(this.isDark))
          Blank().layoutWeight(1)
          Button() {
            SymbolGlyph($r('sys.symbol.trash'))
              .fontSize(fs(14, this.fontScale))
              .fontColor([Theme.textTertiary(this.isDark)])
          }
          .width(28)
          .height(28)
          .backgroundColor(Color.Transparent)
          .accessibilityText('清空搜索历史')
          .onClick((): void => {
            this.searchHistory = [];
            AppStorage.setOrCreate<string[]>('weiboSearchHistory', []);
            CacheManager.getInstance().put(CACHE_KEY.WEIBO_SEARCH_HISTORY, '[]').catch((): void => {});
          })
        }
        .width('100%')
        .padding({ left: Spacing.lg, right: Spacing.lg })

        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.searchHistory, (keyword: string): void => {
            Button(keyword)
              .height(30)
              .fontSize(fs(12, this.fontScale))
              .fontColor(Theme.textPrimary(this.isDark))
              .backgroundColor(Theme.segGlass(this.isDark, false))
              .borderRadius(Radius.full)
              .padding({ left: 12, right: 12 })
              .margin({ right: Spacing.sm, bottom: Spacing.sm })
              .onClick((): void => {
                this.executeSearch(keyword);
              })
          }, (keyword: string): string => keyword)
        }
        .width('100%')
        .padding({ left: Spacing.lg, right: Spacing.lg, bottom: Spacing.xs })
      }
      .width('100%')
    }
  }

  @Builder
  TopicRow(topic: WeiboHotTopic, isLast: boolean = false) {
    Row({ space: Spacing.md }) {
      Text(`${topic.rank}`)
        .width(26)
        .fontSize(fs(15, this.fontScale))
        .fontWeight(topic.rank <= 3 ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(topic.rank === 1 ? Theme.brand() : (topic.rank === 2 ? '#FFF58220' : (topic.rank === 3 ? '#FFEDB322' : Theme.textSecondary(this.isDark))))
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
              .fontSize(fs(10, this.fontScale))
              .fontColor(Color.White)
              .fontWeight(FontWeight.Bold)
              .backgroundColor(this.labelBgColor(topic.label))
              .borderRadius(4)
              .padding({ left: 5, right: 5, top: 1, bottom: 1 })
          }
        }
        .width('100%')
        if (topic.heat > 0) {
          Row({ space: 4 }) {
            SymbolGlyph($r('sys.symbol.flame'))
              .fontSize(fs(11, this.fontScale))
              .fontColor([Theme.textTertiary(this.isDark)])
            Text(this.formatHeat(topic.heat))
              .fontSize(fs(11, this.fontScale))
              .fontColor(Theme.textTertiary(this.isDark))
          }
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(fs(14, this.fontScale))
        .fontColor([Theme.textTertiary(this.isDark)])
    }
    .width('100%')
    .padding({ left: Spacing.lg, right: Spacing.lg, top: 12, bottom: 12 })
    .border(isLast ? { width: 0 } : { width: { bottom: 0.5 }, color: Theme.manualGlassBorder() })
    .onClick((): void => {
      this.executeSearch(topic.word);
    })
  }

  build() {
    Refresh({ refreshing: $$this.isRefreshing, promptText: '正在刷新…' }) {
      Scroll(this.pageScroller) {
        Column({ space: Spacing.md }) {
          // 顶部快捷搜索栏
          Row({ space: Spacing.sm }) {
            SymbolGlyph($r('sys.symbol.magnifyingglass'))
              .fontSize(fs(18, this.fontScale))
              .fontColor([Theme.textTertiary(this.isDark)])
            TextInput({ placeholder: '搜索微博、话题、用户', text: this.searchKeyword })
              .layoutWeight(1)
              .height(40)
              .backgroundColor(Color.Transparent)
              .fontSize(fs(14, this.fontScale))
              .fontColor(Theme.textPrimary(this.isDark))
              .placeholderColor(Theme.textTertiary(this.isDark))
              .onChange((val: string): void => { this.onKeywordChanged(val); })
              .onSubmit((): void => {
                this.executeSearch(this.searchKeyword);
              })
            if (this.searchKeyword.length > 0) {
              Button() {
                SymbolGlyph($r('sys.symbol.xmark_circle_fill'))
                  .fontSize(fs(16, this.fontScale))
                  .fontColor([Theme.textTertiary(this.isDark)])
              }
              .width(28)
              .height(28)
              .backgroundColor(Color.Transparent)
              .onClick((): void => { this.clearSearch(); })
            }
          }
          .width('calc(100% - 32vp)')
          .height(46)
          .margin({ left: Spacing.lg, right: Spacing.lg })
          .padding({ left: Spacing.md, right: Spacing.md })
          .backgroundColor(Theme.bgCard(this.isDark))
          .borderRadius(Radius.full)
          .border({ width: 0.5, color: Theme.cardBorder(this.isDark) })
          .shadow(Theme.feedCardShadow(this.isDark))

          if (this.searchKeyword.trim().length > 0) {
            // 搜索建议与直达用户卡片
            if (this.isSuggestLoading && this.suggestions.length === 0 && this.suggestUsers.length === 0) {
              LoadingView({ message: '正在获取搜索建议…' })
                .height(200)
            } else if (this.suggestions.length === 0 && this.suggestUsers.length === 0 && !this.isSuggestLoading) {
              EmptyView({ message: '未找到相关建议，按回车直接搜索', icon: '⌕' })
                .height(200)
            } else {
              Column({ space: Spacing.md }) {
                if (this.suggestUsers.length > 0) {
                  Column({ space: Spacing.xs }) {
                    ForEach(this.suggestUsers, (user: WeiboUser): void => {
                      this.UserDirectCard(user)
                    }, (user: WeiboUser): string => user.id)
                  }
                  .width('100%')
                }

                if (this.suggestions.length > 0) {
                  Column() {
                    ForEach(this.suggestions, (suggestion: WeiboSuggestion, index: number): void => {
                      this.SuggestionRow(suggestion, index === this.suggestions.length - 1)
                    }, (suggestion: WeiboSuggestion): string => `${suggestion.word}_${suggestion.isTopic}_${suggestion.isHot}`)
                  }
                  .width('100%')
                  .backgroundColor(Theme.bgCard(this.isDark))
                  .borderRadius(Radius.postCard)
                  .shadow(Theme.glassShadowStyle())
                }
              }
              .width('calc(100% - 32vp)')
              .margin({ left: Spacing.lg, right: Spacing.lg })
            }
          } else {
            // 搜索历史（当输入为空且存在历史记录时呈现）
            this.SearchHistorySection()

            if (this.state === HotLoadState.Loading) {
              LoadingView({ message: $r('app.string.weibo_loading') })
                .height(360)
            } else if (this.state === HotLoadState.Error) {
              ErrorView({ message: this.errorMessage, onRetry: (): void => { this.loadTopics(false); } })
                .height(360)
            } else if (this.state === HotLoadState.Success && this.topics.length === 0) {
              EmptyView({ message: $r('app.string.weibo_hot_empty'), icon: '○' })
                .height(360)
            } else if (this.state === HotLoadState.Success) {
              Column() {
                Row() {
                  Row({ space: 6 }) {
                    SymbolGlyph($r('sys.symbol.flame_fill'))
                      .fontSize(fs(16, this.fontScale))
                      .fontColor([Theme.brand()])
                    Text('实时热搜榜')
                      .fontSize(fs(15, this.fontScale))
                      .fontWeight(FontWeight.Bold)
                      .fontColor(Theme.textPrimary(this.isDark))
                    Text('实时')
                      .fontSize(fs(10, this.fontScale))
                      .fontWeight(FontWeight.Bold)
                      .fontColor(Color.White)
                      .backgroundColor(Theme.brand())
                      .borderRadius(Radius.full)
                      .padding({ left: 6, right: 6, top: 1, bottom: 1 })
                  }
                }
                .width('100%')
                .padding({ left: Spacing.lg, right: Spacing.lg, top: Spacing.md, bottom: Spacing.sm })
                .border({ width: { bottom: 0.5 }, color: Theme.manualGlassBorder() })

                ForEach(this.topics, (topic: WeiboHotTopic, index: number): void => {
                  this.TopicRow(topic, index === this.topics.length - 1)
                }, (topic: WeiboHotTopic): string => `${topic.rank}_${topic.word}`)
              }
              .width('100%')
              .backgroundColor(Theme.bgCard(this.isDark))
              .borderRadius({ topLeft: Radius.postCard, topRight: Radius.postCard })
              .shadow(Theme.glassShadowStyle())
            } else {
              EmptyView({ message: $r('app.string.weibo_hot_empty'), icon: '○' })
                .height(360)
            }
          }
        }
        .width('100%')
        .padding({ top: Math.max(this.topInset, this.statusBarHeight + 10), bottom: 120 })
      }
      .width('100%')
      .height('100%')
      .scrollable(ScrollDirection.Vertical)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .onDidScroll((xOffset: number, yOffset: number, scrollState: ScrollState): void => {
        if (scrollState !== ScrollState.Scroll) { return; }
        if (this.pageScroller.currentOffset().yOffset <= 0) {
          this.onScrollDirection(true);
          return;
        }
        if (yOffset > 8) { this.onScrollDirection(false); }
        else if (yOffset < -8) { this.onScrollDirection(true); }
      })
    }
    .onRefreshing((): void => {
      Haptic.light();
      this.loadTopics(true);
    })
    .width('100%')
    .height('100%')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .backgroundColor(Theme.bg(this.isDark))
  }
}
