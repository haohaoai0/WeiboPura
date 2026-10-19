import { WeiboTabTouchTracker } from '../common/WeiboTabSwipe';
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { curves, LengthMetrics, SymbolGlyphModifier } from '@kit.ArkUI';
import {
  HdsAnimationMode,
  HdsNavigation,
  HdsNavigationTitleMode,
  HdsTabs,
  HdsTabsController,
  HdsTabsModifier,
  hdsMaterial,
  BottomBuilderShowType,
  DividerShowType,
  ScrollEffectType,
  TitleBarStyleOptions
} from '@kit.UIDesignKit';
import { CacheManager } from '../cache/CacheManager';
import { ImageCache } from '../cache/ImageCache';
import { ImmBlur, ImmMaterial, MaterialManager, Radius, Spacing, Theme, fs, initDarkMode, isDarkMode } from '../common/Theme';
import { UsageHabitsManager } from '../service/UsageHabitsManager';
import { WeiboAuthManager } from '../service/WeiboAuthManager';
import { AppSettingsStore, DEFAULT_HOME_TAB_MATERIAL_LEVEL } from '../service/AppSettingsStore';
import { createWeiboDockStyle } from '../common/WeiboDockStyle';
import { WeiboService } from '../service/WeiboService';
import { WeiboDetailTab, WeiboHotTopic, WeiboNotification, WeiboPost, WeiboUser } from '../model/WeiboModel';
import { WeiboHomeTab, WeiboTimelineMode } from './WeiboHomeTab';
import { WeiboPostDetailBuilder, WeiboPostDetailRouteParam } from './WeiboPostDetail';
import { WeiboUserProfileBuilder, WeiboUserProfileRouteParam } from './WeiboUserProfile';
import { WeiboSearchResultBuilder, WeiboSearchResultRouteParam } from './WeiboSearchResult';
import { WeiboBrowserBuilder } from './WeiboBrowser';
import { WeiboHotSearch } from './WeiboHotSearch';
import { WeiboSearch } from './WeiboSearch';
import { WeiboComposeDialog } from '../components/WeiboComposeDialog';
import { WeiboVisitorBootstrap } from '../components/WeiboVisitorBootstrap';
import { WeiboRichTextView } from '../components/WeiboRichTextView';
import { WeiboReadingPositionManager } from '../service/WeiboReadingPositionManager';
import { Haptic } from '../common/Haptic';
import {
  syncWeiboSplitNavigation,
  WEIBO_BREAKPOINT_KEY,
  WEIBO_CONTENT_DESTINATION_OPEN_KEY,
  WeiboResponsiveLayout
} from '../common/WeiboNavigationLayout';

const PRIVACY_KEY: string = 'fluo_privacy_agreed_v1';
const LEGACY_PRIVACY_KEY: string = 'weibopura_privacy_agreed_v1';
const HDS_TAB_BAR_HEIGHT: number = 56;
const HOME_TAB_DOUBLE_TAP_WINDOW_MS: number = 360;

/** Fluo four-slot root navigation; every slot is backed by Weibo data. */
enum WeiboTab {
  Home = 0,
  Discover = 1,
  Messages = 2,
  Mine = 3,
  Search = 4,
}

type TabAnimationDirection = 'left' | 'right';

@Entry
@Component
struct Index {
  @State selectedTab: number = WeiboTab.Home;
  @State page1Enter: number = 0;
  @State page1Exit: number = 0;
  @State page2Enter: number = 0;
  @State page2Exit: number = 0;
  @State page3Enter: number = 0;
  @State page3Exit: number = 0;
  @State @Watch('onMessagesEnter') page4Enter: number = 0;
  @State @Watch('onMessagesExit') page4Exit: number = 0;
  @State @Watch('onMineEnter') page5Enter: number = 0;
  @State @Watch('onMineExit') page5Exit: number = 0;
  @State messagesTranslateX: number = 0;
  @State messagesOpacity: number = 1;
  @State messagesAnimating: boolean = false;
  @State messageType: 'all' | 'mention' | 'comment' | 'like' = 'all';
  @State notifications: WeiboNotification[] = [];
  @State messagesLoading: boolean = false;
  @State messagesLoaded: boolean = false;
  @State messagesLoadingMore: boolean = false;
  @State messagesRefreshing: boolean = false;
  @State messagePage: number = 0;
  @State hasMoreMessages: boolean = true;
  @State messageError: string = '';
  @State readNotificationIds: string[] = [];
  private messageEpoch: number = 0;
  @State mineTranslateX: number = 0;
  @State mineOpacity: number = 1;
  @State mineAnimating: boolean = false;
  @State homeMode: WeiboTimelineMode = WeiboTimelineMode.Recommend;
  @State privacyReady: boolean = false;
  @State privacyAccepted: boolean = false;
  @State isDark: boolean = isDarkMode();
  @State weiboReady: boolean = false;
  @State cookieConfigured: boolean = false;
  @State sessionResetting: boolean = false;
  @State logoutRetryRequired: boolean = false;
  private accountEpoch: number = 0;
  @Provide('weiboNavStack') weiboNavStack: NavPathStack = new NavPathStack();
  /** The source/destination layout follows the live window width, like HarmonyX. */
  @StorageLink(WEIBO_BREAKPOINT_KEY) @Watch('onBreakpointChange')
  breakpoint: string = WeiboResponsiveLayout.BREAKPOINT_SM;
  @StorageLink(WEIBO_CONTENT_DESTINATION_OPEN_KEY) @Watch('onContentDestinationChange')
  contentDestinationOpen: boolean = false;
  @State mainNavigationMode: NavigationMode = NavigationMode.Stack;
  @State accountProfile: WeiboUser | null = null;
  @State accountLoading: boolean = false;
  @StorageLink('fontScale') fontScale: number = 1.0;
  @StorageLink('darkTick') @Watch('onDarkTick') darkTick: number = 0;
  @StorageLink('weiboAuthTick') @Watch('onWeiboAuthTick') weiboAuthTick: number = 0;
  @StorageLink('appAccentColor') @Watch('onAccentChanged') accentColor: string = '#4EAA78';
  @StorageLink('appAccentTick') @Watch('onAccentTick') appAccentTick: number = 0;
  @StorageLink('homeTabMaterialLevel') @Watch('onHomeTabMaterialChanged')
  homeTabMaterialLevel: number = DEFAULT_HOME_TAB_MATERIAL_LEVEL;
  @StorageLink('weiboSearchQuery') weiboSearchText: string = '';
  @State searchFocusScale: number = 1;
  @State searchFocusOpacity: number = 0.92;
  @StorageLink('weibo.top_rect_height') topRectHeight: number = 0;
  @StorageLink('weibo.status_bar_height') statusBarHeight: number = 0;
  @StorageLink('weibo.navigation_indicator_height') navigationIndicatorHeight: number = 0;
  private context: common.UIAbilityContext | null = null;
  private hdsTabsController: HdsTabsController = new HdsTabsController();
  /** Changes the keyed home subtree so ArkUI destroys and recreates both feeds. */
  @State homeFeedRebuildVersion: number = 0;
  private lastHomeTabTapAt: number = 0;
  @State hdsTabsModifier: HdsTabsModifier = new HdsTabsModifier();
  private homeRecommendScroller: Scroller = new Scroller();
  private homeFollowingScroller: Scroller = new Scroller();
  @State homeRefreshTrigger: number = 0;
  @State isTabBarHidden: boolean = false;
  private discoverScroller: Scroller = new Scroller();
  private searchScroller: Scroller = new Scroller();
  private messagesScroller: Scroller = new Scroller();
  private mineScroller: Scroller = new Scroller();

  async aboutToAppear(): Promise<void> {
    syncWeiboSplitNavigation(this.weiboNavStack);
    this.updateNavigationMode();
    this.context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    MaterialManager.init();
    await AppSettingsStore.getInstance().init(this.context);
    AppStorage.setOrCreate<string>('weiboSearchQuery', '');
    AppStorage.setOrCreate<number>('weiboSearchRequestTick', 0);
    this.configureHdsTabs();
    this.bindBuiltInTabScrollers();
    const systemDark: boolean = this.context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    this.isDark = systemDark;
    initDarkMode(systemDark);
    const cache: CacheManager = CacheManager.getInstance();
    await cache.init(this.context);
    const agreed = await cache.get(PRIVACY_KEY);
    const legacyAgreed = agreed ? null : await cache.get(LEGACY_PRIVACY_KEY);
    this.privacyAccepted = agreed === '1' || legacyAgreed === '1';
    if (this.privacyAccepted && agreed !== '1') {
      await cache.put(PRIVACY_KEY, '1');
    }
    this.privacyReady = true;
    if (this.privacyAccepted) {
      await this.initAfterPrivacyConsent();
    }
  }

  private async initAfterPrivacyConsent(): Promise<void> {
    if (this.context === null) {
      return;
    }
    await UsageHabitsManager.getInstance().init(this.context);
    const followSystem: boolean = UsageHabitsManager.getInstance().isFollowSystemDark();
    const systemDark: boolean = this.context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    this.isDark = followSystem ? systemDark : UsageHabitsManager.getInstance().isDarkModeManual();
    initDarkMode(this.isDark);
    await WeiboAuthManager.getInstance().init(this.context);
    AppStorage.setOrCreate<number>('weiboAuthTick', AppStorage.get<number>('weiboAuthTick') ?? 0);
    this.refreshWeiboAccount();
    this.weiboReady = true;
  }

  private async acceptPrivacy(): Promise<void> {
    await CacheManager.getInstance().put(PRIVACY_KEY, '1');
    this.privacyAccepted = true;
    await this.initAfterPrivacyConsent();
  }

  private onDarkTick(): void {
    this.isDark = isDarkMode();
  }

  private onAccentChanged(): void {
    this.configureHdsTabs();
  }

  private onAccentTick(): void {
    this.configureHdsTabs();
  }

  private onBreakpointChange(): void {
    this.updateNavigationMode();
  }

  private onContentDestinationChange(): void {
    this.updateNavigationMode();
  }

  /** Keep the root content and its routed destination side by side only when both fit. */
  private updateNavigationMode(): void {
    this.mainNavigationMode = WeiboResponsiveLayout.isWide(this.breakpoint) && this.contentDestinationOpen
      ? NavigationMode.Split : NavigationMode.Stack;
  }

  /** HarmonyX routing order: prepare the root split before adding a child destination. */
  private openContentDestination(): void {
    this.contentDestinationOpen = true;
    AppStorage.setOrCreate<boolean>(WEIBO_CONTENT_DESTINATION_OPEN_KEY, true);
    this.updateNavigationMode();
  }

  private openPostDetail(post: WeiboPost, tab?: WeiboDetailTab, autoFocusComment?: boolean, targetCommentId?: string): void {
    WeiboReadingPositionManager.getInstance().flush().catch((): void => {});
    WeiboService.getInstance().rememberPost(post);
    WeiboService.getInstance().prefetchComments(post.id);
    const param: WeiboPostDetailRouteParam = {
      postId: post.id,
      post: post,
      initialTab: tab,
      autoFocusComment: autoFocusComment,
      targetCommentId: targetCommentId
    };
    this.openContentDestination();
    this.weiboNavStack.pushPath({ name: 'WeiboPostDetail', param: param });
  }

  private openUserProfile(userId: string, userName: string): void {
    const param: WeiboUserProfileRouteParam = { userId: userId, userName: userName };
    this.openContentDestination();
    this.weiboNavStack.pushPath({ name: 'WeiboUserProfile', param: param });
  }

  private openSearchTopic(keyword: string): void {
    const trimmed: string = keyword.trim();
    if (trimmed.length === 0) {
      return;
    }
    this.weiboSearchText = trimmed;
    AppStorage.setOrCreate<string>('weiboSearchQuery', trimmed);
    const param: WeiboSearchResultRouteParam = { query: trimmed };
    this.openContentDestination();
    this.weiboNavStack.pushPath({ name: 'WeiboSearchResult', param: param });
  }

  private onHomeTabMaterialChanged(): void {
    this.configureHdsTabs();
  }

  aboutToDisappear(): void {
    this.hdsTabsController.unbindScroller(this.homeRecommendScroller);
    this.hdsTabsController.unbindScroller(this.homeFollowingScroller);
    this.hdsTabsController.unbindScroller(this.discoverScroller);
    this.hdsTabsController.unbindScroller(this.searchScroller);
    this.hdsTabsController.unbindScroller(this.messagesScroller);
    this.hdsTabsController.unbindScroller(this.mineScroller);
  }

  private onWeiboAuthTick(): void {
    this.accountEpoch++;
    this.accountProfile = null;
    this.accountLoading = false;
    this.messageEpoch++;
    this.notifications = [];
    this.messagesLoaded = false;
    this.messagesLoading = false;
    this.messagesLoadingMore = false;
    this.messagesRefreshing = false;
    this.messagePage = 0;
    this.messageError = '';
    this.refreshWeiboAccount();
    if (this.selectedTab === WeiboTab.Messages && this.cookieConfigured) { this.loadNotifications(true); }
    if (this.selectedTab === WeiboTab.Mine) {
      this.loadAccountProfile();
    }
  }

  private refreshWeiboAccount(): void {
    this.cookieConfigured = WeiboAuthManager.getInstance().hasCookie();
  }

  /** Loads the account represented by the saved Cookie; public feeds remain usable when it fails. */
  private async loadAccountProfile(): Promise<void> {
    if (!this.cookieConfigured || this.accountLoading) {
      if (!this.cookieConfigured) {
        this.accountProfile = null;
      }
      return;
    }
    const epoch: number = ++this.accountEpoch;
    const revision: number = WeiboAuthManager.getInstance().getSessionRevision();
    this.accountLoading = true;
    try {
      const profile: WeiboUser = await WeiboService.getInstance().fetchCurrentUserProfile();
      if (epoch === this.accountEpoch && revision === WeiboAuthManager.getInstance().getSessionRevision()) {
        this.accountProfile = profile;
      }
    } catch (error) {
      if (epoch === this.accountEpoch) { this.accountProfile = null; }
    } finally {
      if (epoch === this.accountEpoch) { this.accountLoading = false; }
    }
  }

  private setTabBarVisible(visible: boolean): void {
    if (this.isTabBarHidden === !visible) {
      return;
    }
    this.isTabBarHidden = !visible;
    const mode: HdsAnimationMode = HdsAnimationMode.SCROLL_ANIMATION;
    if (visible) {
      this.hdsTabsController.applyShowAnimation(mode);
    } else {
      this.hdsTabsController.applyHideAnimation(mode);
    }
  }

  private switchHomeMode(mode: WeiboTimelineMode): void {
    if (this.homeMode === mode) {
      return;
    }
    WeiboReadingPositionManager.getInstance().flush().catch((): void => {});
    this.homeMode = mode;
    this.hdsTabsController.unbindScroller(this.homeRecommendScroller);
    this.hdsTabsController.unbindScroller(this.homeFollowingScroller);
    const activeScroller: Scroller = mode === WeiboTimelineMode.Following
      ? this.homeFollowingScroller : this.homeRecommendScroller;
    this.hdsTabsController.bindScroller(WeiboTab.Home, activeScroller);
    if (this.isTabBarHidden) {
      this.setTabBarVisible(true);
    }
  }

  @State tabDragOffset: number = 0;
  @State tabDragging: boolean = false;
  private tabTouchTracker: WeiboTabTouchTracker = new WeiboTabTouchTracker('home');
  private titleTouchTracker: WeiboTabTouchTracker = new WeiboTabTouchTracker('home-title');

  private resetTabDrag(): void {
    this.tabDragging = false;
    this.tabDragOffset = 0;
  }

  private onHomeTabPanEnd(event: GestureEvent, tracker: WeiboTabTouchTracker): void {
    const direction: number = tracker.finish(event);
    this.resetTabDrag();
    if (this.selectedTab !== WeiboTab.Home || direction === 0) { return; }
    if (direction === 1 && this.homeMode === WeiboTimelineMode.Following) {
      Haptic.light();
      this.switchHomeMode(WeiboTimelineMode.Recommend);
    } else if (direction === -1 && this.homeMode === WeiboTimelineMode.Recommend) {
      Haptic.light();
      this.switchHomeMode(WeiboTimelineMode.Following);
    }
  }

  /** Programmatic selection is shared by the title-bar search shortcut and HdsTabs. */
  private switchTab(index: number): void {
    if (this.isTabBarHidden) {
      this.setTabBarVisible(true);
    }
    if (index === this.selectedTab) {
      return;
    }
    if (this.selectedTab === WeiboTab.Home) {
      WeiboReadingPositionManager.getInstance().flush().catch((): void => {});
    }
    this.selectedTab = index;
    try {
      this.hdsTabsController.changeIndex(index);
    } catch (_e) {}
    if (index === WeiboTab.Discover) {
      this.page2Enter++;
    } else if (index === WeiboTab.Messages) {
      this.refreshWeiboAccount();
      if (this.cookieConfigured && (!this.messagesLoaded || this.notifications.length === 0)) {
        this.loadNotifications(true);
      }
    } else if (index === WeiboTab.Mine) {
      this.refreshWeiboAccount();
      this.loadAccountProfile();
    }
  }

  /** HdsTabs reports the current and destination indices before its content transition begins. */
  private onTabAnimationStart(currentIndex: number, targetIndex: number, _event: TabsAnimationEvent): void {
    if (currentIndex === targetIndex) {
      return;
    }
    const direction: TabAnimationDirection = targetIndex > currentIndex ? 'left' : 'right';
    AppStorage.setOrCreate<string>('animationDirection', direction);
    this.triggerExit(currentIndex);
    setTimeout((): void => {
      this.triggerEnter(targetIndex);
    }, 1);
  }

  private triggerEnter(index: number): void {
    if (index === WeiboTab.Home) {
      this.page1Enter++;
    } else if (index === WeiboTab.Discover) {
      this.page2Enter++;
    } else if (index === WeiboTab.Messages) {
      this.page4Enter++;
    } else if (index === WeiboTab.Mine) {
      this.page5Enter++;
    } else if (index === WeiboTab.Search) {
      this.page3Enter++;
    }
  }

  private triggerExit(index: number): void {
    if (index === WeiboTab.Home) {
      this.page1Exit++;
    } else if (index === WeiboTab.Discover) {
      this.page2Exit++;
    } else if (index === WeiboTab.Messages) {
      this.page4Exit++;
    } else if (index === WeiboTab.Mine) {
      this.page5Exit++;
    } else if (index === WeiboTab.Search) {
      this.page3Exit++;
    }
  }

  private animationDirection(): TabAnimationDirection {
    const storedDirection: string | undefined = AppStorage.get<string>('animationDirection');
    return storedDirection === 'right' ? 'right' : 'left';
  }

  private onMessagesEnter(): void {
    if (this.page4Enter > 0) {
      this.messagesAnimating = false;
      this.playMessagesEnterAnimation(this.animationDirection());
      if (this.cookieConfigured && !this.messagesLoaded) {
        this.loadNotifications();
      }
    }
  }

  private onMessagesExit(): void {
    if (this.page4Exit > 0) {
      this.playMessagesExitAnimation(this.animationDirection());
    }
  }

  private playMessagesExitAnimation(direction: TabAnimationDirection): void {
    if (this.messagesAnimating) {
      return;
    }
    this.messagesAnimating = true;
    const endX: number = direction === 'left' ? -350 : 350;
    this.getUIContext().animateTo({
      duration: 250,
      curve: Curve.EaseIn,
      onFinish: (): void => { this.messagesAnimating = false; }
    }, (): void => {
      this.messagesTranslateX = endX;
      this.messagesOpacity = 0;
    });
  }

  private playMessagesEnterAnimation(direction: TabAnimationDirection): void {
    if (this.messagesAnimating) {
      return;
    }
    this.messagesAnimating = true;
    const startX: number = direction === 'left' ? 350 : -350;
    this.messagesTranslateX = startX;
    this.messagesOpacity = 0;
    setTimeout((): void => {
      this.getUIContext().animateTo({ duration: 300, curve: curves.springMotion() }, (): void => {
        this.messagesTranslateX = 0;
        this.messagesOpacity = 1;
      });
    }, 0);
    setTimeout((): void => { this.messagesAnimating = false; }, 600);
  }

  private onMineEnter(): void {
    if (this.page5Enter > 0) {
      this.mineAnimating = false;
      this.playMineEnterAnimation(this.animationDirection());
    }
  }

  private onMineExit(): void {
    if (this.page5Exit > 0) {
      this.playMineExitAnimation(this.animationDirection());
    }
  }

  private playMineExitAnimation(direction: TabAnimationDirection): void {
    if (this.mineAnimating) {
      return;
    }
    this.mineAnimating = true;
    const endX: number = direction === 'left' ? -350 : 350;
    this.getUIContext().animateTo({
      duration: 250,
      curve: Curve.EaseIn,
      onFinish: (): void => { this.mineAnimating = false; }
    }, (): void => {
      this.mineTranslateX = endX;
      this.mineOpacity = 0;
    });
  }

  private playMineEnterAnimation(direction: TabAnimationDirection): void {
    if (this.mineAnimating) {
      return;
    }
    this.mineAnimating = true;
    const startX: number = direction === 'left' ? 350 : -350;
    this.mineTranslateX = startX;
    this.mineOpacity = 0;
    setTimeout((): void => {
      this.getUIContext().animateTo({ duration: 300, curve: curves.springMotion() }, (): void => {
        this.mineTranslateX = 0;
        this.mineOpacity = 1;
      });
    }, 0);
    setTimeout((): void => { this.mineAnimating = false; }, 600);
  }

  /** Tap on already-selected Home tab smoothly refreshes the feed without white screen. */
  private onTabBarClick(index: number): void {
    if (index !== WeiboTab.Home) {
      if (this.isTabBarHidden) {
        this.setTabBarVisible(true);
      }
      return;
    }
    if (this.isTabBarHidden) {
      this.setTabBarVisible(true);
    }
    if (this.selectedTab === WeiboTab.Home) {
      this.homeRefreshTrigger++;
    }
  }

  private configureHdsTabs(): void {
    const modifier: HdsTabsModifier = new HdsTabsModifier();
    modifier
      .vertical(false)
      .barPosition(BarPosition.End)
      .barHeight(HDS_TAB_BAR_HEIGHT)
      .barFloatingStyle(createWeiboDockStyle(this.homeTabMaterialLevel, this.accentColor));
    this.hdsTabsModifier = modifier;
  }

  /** Match PaperTalk: convert the current window's raw top avoid area at layout time. */
  private topAvoidAreaVp(): number {
    return this.getUIContext().px2vp(this.topRectHeight);
  }

  /** The content inset is based on the actual system status-bar avoid area. */
  private contentTopInset(): number {
    return this.topAvoidAreaVp() + 56;
  }

  /** HarmonyX uses a second title-bar row for Search, so results begin below both rows. */
  private searchContentTopInset(): number {
    return this.topAvoidAreaVp() + 112;
  }

  private submitWeiboSearch(value: string): void {
    const query: string = value.trim();
    this.weiboSearchText = query;
    AppStorage.setOrCreate<number>('weiboSearchRequestTick',
      (AppStorage.get<number>('weiboSearchRequestTick') ?? 0) + 1);
  }

  private setSearchFocused(focused: boolean): void {
    this.getUIContext().animateTo({ curve: curves.interpolatingSpring(0, 1, 240, 26) }, (): void => {
      this.searchFocusScale = focused ? 1.015 : 1;
      this.searchFocusOpacity = focused ? 1 : 0.92;
    });
  }

  /** Native HDS title content lets the framework place text against the real safe area. */
  private currentHdsTitle(): Resource {
    if (this.selectedTab === WeiboTab.Discover) {
      return $r('app.string.weibo_tab_discover');
    }
    if (this.selectedTab === WeiboTab.Search) {
      return $r('app.string.weibo_search_title');
    }
    if (this.selectedTab === WeiboTab.Messages) {
      return $r('app.string.weibo_tab_messages');
    }
    if (this.selectedTab === WeiboTab.Mine) {
      return $r('app.string.weibo_mine_title');
    }
    return $r('app.string.weibo_tab_home');
  }

  /** Mirrors HarmonyX's immersive title material rather than drawing a header in each page. */
  private titleBarStyle(): TitleBarStyleOptions {
    return {
      scrollEffectOpts: {
        enableScrollEffect: true,
        scrollEffectType: ScrollEffectType.IMMERSIVE_GRADIENT_BLUR,
        blurEffectiveStartOffset: LengthMetrics.vp(0),
        blurEffectiveEndOffset: LengthMetrics.vp(16)
      },
      originalStyle: {
        backgroundStyle: { backgroundColor: $r('sys.color.ohos_id_color_background_transparent') },
        contentStyle: {
          titleStyle: {
            mainTitleColor: $r('sys.color.font_primary'),
            subTitleColor: $r('sys.color.font_secondary')
          },
          backIconStyle: { iconColor: $r('sys.color.icon_primary') },
          subIconStyle: { iconColor: $r('sys.color.icon_primary') },
          menuStyle: { iconColor: $r('sys.color.icon_primary') }
        }
      },
      scrollEffectStyle: {
        // 悬浮顶栏必须是【透明浮层】——滚动态背景与 originalStyle 一致用透明系统色，
        // 观感交给 systemMaterialEffect 的 IMMERSIVE 材质 + IMMERSIVE_GRADIENT_BLUR。
        // 原先是实色 Theme.bg(isDark)：一滚动就在顶部盖出约 topInset(108vp) 的实心色块。
        backgroundStyle: { backgroundColor: $r('sys.color.ohos_id_color_background_transparent') },
        contentStyle: {
          titleStyle: {
            mainTitleColor: $r('sys.color.font_primary'),
            subTitleColor: $r('sys.color.font_secondary')
          },
          backIconStyle: { iconColor: $r('sys.color.icon_primary') },
          subIconStyle: { iconColor: $r('sys.color.icon_primary') },
          menuStyle: { iconColor: $r('sys.color.icon_primary') }
        }
      },
      systemMaterialEffect: {
        materialType: hdsMaterial.MaterialType.IMMERSIVE,
        materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
      }
    };
  }

  private bindBuiltInTabScrollers(): void {
    const homeScroller: Scroller = this.homeMode === WeiboTimelineMode.Following
      ? this.homeFollowingScroller : this.homeRecommendScroller;
    this.hdsTabsController.bindScroller(WeiboTab.Home, homeScroller);
    this.hdsTabsController.bindScroller(WeiboTab.Discover, this.discoverScroller);
    this.hdsTabsController.bindScroller(WeiboTab.Messages, this.messagesScroller);
    this.hdsTabsController.bindScroller(WeiboTab.Mine, this.mineScroller);
  }

  @Builder
  PrivacyGate() {
    Column({ space: Spacing.lg }) {
      SymbolGlyph($r('sys.symbol.lock_shield'))
        .fontSize(48)
        .fontColor([Theme.brand()])
      Text($r('app.string.weibo_privacy_title'))
        .fontSize(fs(22, this.fontScale))
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.textPrimary(this.isDark))
      Text($r('app.string.weibo_privacy_body'))
        .fontSize(fs(14, this.fontScale))
        .fontColor(Theme.textSecondary(this.isDark))
        .textAlign(TextAlign.Center)
        .lineHeight(fs(22, this.fontScale))
        .padding({ left: Spacing.xl, right: Spacing.xl })
      Button($r('app.string.weibo_privacy_agree'))
        .width('78%')
        .height(48)
        .fontSize(fs(16, this.fontScale))
        .backgroundColor(Theme.manualGlass(this.isDark, true))
        .fontColor(Color.White)
        .border({ width: 0.5, color: Theme.manualGlassBorder() })
        .shadow(Theme.glassShadowStyle())
        .backgroundEffect(ImmBlur.accent())
        .systemMaterial(ImmMaterial.accent(this.isDark))
        .borderRadius(Radius.full)
        .onClick(() => { this.acceptPrivacy(); })
      Button($r('app.string.weibo_privacy_exit'))
        .fontSize(fs(14, this.fontScale))
        .backgroundColor(Color.Transparent)
        .fontColor(Theme.textSecondary(this.isDark))
        .onClick(() => {
          if (this.context !== null) {
            this.context.terminateSelf().catch(() => {});
          }
        })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(Theme.bg(this.isDark))
  }

  /** The source HomeTab's two-pill header, kept inside Home rather than the bottom navigation. */
  @Builder
  HomeHeaderOverlay() {
    Row({ space: 16 }) {
      Text($r('app.string.weibo_recommend_title'))
        .fontSize(fs(16, this.fontScale))
        .fontWeight(this.homeMode === WeiboTimelineMode.Recommend ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(this.homeMode === WeiboTimelineMode.Recommend ? this.accentColor : $r('sys.color.font_primary'))
        .backgroundColor(Theme.segGlass(this.isDark, this.homeMode === WeiboTimelineMode.Recommend))
        .border({ width: 0.5, color: Theme.manualGlassBorder() })
        .backgroundBlurStyle(this.homeMode === WeiboTimelineMode.Recommend ? BlurStyle.Regular : BlurStyle.Thin,
          { scale: this.homeMode === WeiboTimelineMode.Recommend ? 0.8 : 0.85 })
        .shadow(Theme.segGlassShadow(this.isDark, this.homeMode === WeiboTimelineMode.Recommend))
        .borderRadius(Radius.full)
        .padding({ left: 22, right: 22, top: 9, bottom: 9 })
        .onClick(() => { this.switchHomeMode(WeiboTimelineMode.Recommend); })
      Text($r('app.string.weibo_following_title'))
        .fontSize(fs(16, this.fontScale))
        .fontWeight(this.homeMode === WeiboTimelineMode.Following ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(this.homeMode === WeiboTimelineMode.Following ? this.accentColor : $r('sys.color.font_primary'))
        .backgroundColor(Theme.segGlass(this.isDark, this.homeMode === WeiboTimelineMode.Following))
        .border({ width: 0.5, color: Theme.manualGlassBorder() })
        .backgroundBlurStyle(this.homeMode === WeiboTimelineMode.Following ? BlurStyle.Regular : BlurStyle.Thin,
          { scale: this.homeMode === WeiboTimelineMode.Following ? 0.8 : 0.85 })
        .shadow(Theme.segGlassShadow(this.isDark, this.homeMode === WeiboTimelineMode.Following))
        .borderRadius(Radius.full)
        .padding({ left: 22, right: 22, top: 9, bottom: 9 })
        .onClick(() => { this.switchHomeMode(WeiboTimelineMode.Following); })
      Blank()
      Button() {
        SymbolGlyph($r('sys.symbol.magnifyingglass'))
          .fontColor([$r('sys.color.icon_primary')])
          .fontSize(fs(22, this.fontScale))
          .fontWeight(FontWeight.Bold)
      }
      .width(44)
      .height(44)
      .backgroundColor(Theme.segGlass(this.isDark, false))
      .border({ width: 0.5, color: Theme.manualGlassBorder() })
      .backgroundBlurStyle(BlurStyle.Thin, { scale: 0.85 })
      .shadow(Theme.segGlassShadow(this.isDark, false))
      .borderRadius(Radius.full)
      .accessibilityText($r('app.string.weibo_tab_search'))
      .onClick(() => { this.switchTab(WeiboTab.Search); })
    }
    .width('100%')
    .padding({ left: Spacing.lg, right: Spacing.lg, top: this.topAvoidAreaVp() })
    .backgroundColor(Color.Transparent)
    .zIndex(15)
  }

  @Builder
  HomeFeedContent() {
    Stack({ alignContent: Alignment.TopStart }) {
      Stack() {
        WeiboHomeTab({
          mode: WeiboTimelineMode.Recommend,
          showHeader: false,
          pageScroller: this.homeRecommendScroller,
          refreshTrigger: this.homeRefreshTrigger,
          topInset: 108,
          bottomInset: 128,
          animationTrigger: this.page1Enter,
          exitTrigger: this.page1Exit,
          onScrollDirection: (visible: boolean): void => this.setTabBarVisible(visible),
          onOpenPost: (post: WeiboPost, tab?: WeiboDetailTab, autoFocusComment?: boolean, targetCommentId?: string): void => this.openPostDetail(post, tab, autoFocusComment, targetCommentId),
          onOpenUserProfile: (userId: string, userName: string): void => this.openUserProfile(userId, userName)
        })
      }
      .width('100%')
      .height('100%')
      .visibility(this.homeMode === WeiboTimelineMode.Recommend ? Visibility.Visible : Visibility.Hidden)
      .translate({ x: this.tabDragOffset })
      .animation({ duration: this.tabDragging ? 0 : 180, curve: Curve.EaseOut })
      Stack() {
        WeiboHomeTab({
          mode: WeiboTimelineMode.Following,
          showHeader: false,
          pageScroller: this.homeFollowingScroller,
          refreshTrigger: this.homeRefreshTrigger,
          topInset: 108,
          bottomInset: 128,
          animationTrigger: this.page1Enter,
          exitTrigger: this.page1Exit,
          onScrollDirection: (visible: boolean): void => this.setTabBarVisible(visible),
          onOpenPost: (post: WeiboPost, tab?: WeiboDetailTab, autoFocusComment?: boolean, targetCommentId?: string): void => this.openPostDetail(post, tab, autoFocusComment, targetCommentId),
          onOpenUserProfile: (userId: string, userName: string): void => this.openUserProfile(userId, userName)
        })
      }
      .width('100%')
      .height('100%')
      .visibility(this.homeMode === WeiboTimelineMode.Following ? Visibility.Visible : Visibility.Hidden)
      .translate({ x: this.tabDragOffset })
      .animation({ duration: this.tabDragging ? 0 : 180, curve: Curve.EaseOut })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg(this.isDark))
    .clip(true)
    .onTouch((event: TouchEvent): void => {
      this.tabTouchTracker.track(event);
      if (event.type === TouchType.Cancel) { this.resetTabDrag(); }
    })
    .gesture(
      PanGesture({ fingers: 1, direction: PanDirection.Horizontal, distance: 12 })
        .tag('weibo-tab-swipe')
        .onActionStart((): void => {
          this.tabTouchTracker.claim();
          this.tabDragging = true;
        })
        .onActionUpdate((event: GestureEvent): void => {
          this.tabDragOffset = this.tabTouchTracker.update(event, this.homeMode === WeiboTimelineMode.Recommend, this.homeMode === WeiboTimelineMode.Following);
        })
        .onActionEnd((event: GestureEvent): void => { this.onHomeTabPanEnd(event, this.tabTouchTracker); })
        .onActionCancel((): void => {
          this.tabTouchTracker.cancel();
          this.resetTabDrag();
        })
    )
    .onGestureJudgeBegin((info: GestureInfo, event: BaseGestureEvent): GestureJudgeResult => {
      return this.tabTouchTracker.judge(info, event, this.selectedTab === WeiboTab.Home);
    })
  }

  private composeController: CustomDialogController | null = null;

  private openComposeDialog(): void {
    if (!WeiboAuthManager.getInstance().hasCookie()) {
      this.getUIContext().getPromptAction().showToast({ message: '请先在“我的”页面登录微博' });
      return;
    }
    this.composeController = new CustomDialogController({
      builder: WeiboComposeDialog({
        mode: 'publish',
        onSuccess: (): void => {
          this.homeRefreshTrigger++;
        }
      }),
      alignment: DialogAlignment.Bottom,
      customStyle: true,
      autoCancel: false,
      offset: { dx: 0, dy: -20 }
    });
    this.composeController.open();
  }

  /** Reference project's official Navigation title slot: interactive material provides press glow. */
  @Builder
  HomeTitleBar() {
    Row() {
      // 1. 左侧头像 (36vp 圆形)
      Stack() {
        if (this.accountProfile !== null && this.accountProfile.avatarUrl.length > 0) {
          Image(this.accountProfile.avatarUrl)
            .width(36)
            .height(36)
            .borderRadius(18)
            .objectFit(ImageFit.Cover)
        } else {
          SymbolGlyph($r('sys.symbol.person'))
            .fontSize(fs(24, this.fontScale))
            .fontColor([this.accentColor])
        }
      }
      .width(36)
      .height(36)
      .alignContent(Alignment.Center)
      .borderRadius(18)
      .backgroundColor(this.isDark ? 'rgba(255, 255, 255, 0.08)' : 'rgba(0, 0, 0, 0.04)')
      .onClick(() => {
        this.switchTab(WeiboTab.Mine);
      })

      Blank()

      // 2. 中间胶囊分段 (关注 / 推荐)
      Row({ space: 4 }) {
        // 关注
        Text($r('app.string.weibo_following_title'))
          .fontSize(fs(13, this.fontScale))
          .fontWeight(this.homeMode === WeiboTimelineMode.Following && this.selectedTab === WeiboTab.Home
            ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(this.homeMode === WeiboTimelineMode.Following && this.selectedTab === WeiboTab.Home
            ? Color.White : Theme.textSecondary(this.isDark))
          .backgroundColor(this.homeMode === WeiboTimelineMode.Following && this.selectedTab === WeiboTab.Home
            ? this.accentColor : Color.Transparent)
          .borderRadius(16)
          .padding({ left: 14, right: 14, top: 6, bottom: 6 })
          .shadow(this.homeMode === WeiboTimelineMode.Following && this.selectedTab === WeiboTab.Home
            ? { radius: 8, color: 'rgba(78, 170, 120, 0.35)', offsetY: 2 } : { radius: 0, color: '#00000000' })
          .onClick(() => {
            if (this.selectedTab !== WeiboTab.Home) {
              this.switchTab(WeiboTab.Home);
            }
            this.switchHomeMode(WeiboTimelineMode.Following);
          })

        // 推荐
        Text($r('app.string.weibo_recommend_title'))
          .fontSize(fs(13, this.fontScale))
          .fontWeight(this.homeMode === WeiboTimelineMode.Recommend && this.selectedTab === WeiboTab.Home
            ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(this.homeMode === WeiboTimelineMode.Recommend && this.selectedTab === WeiboTab.Home
            ? Color.White : Theme.textSecondary(this.isDark))
          .backgroundColor(this.homeMode === WeiboTimelineMode.Recommend && this.selectedTab === WeiboTab.Home
            ? this.accentColor : Color.Transparent)
          .borderRadius(16)
          .padding({ left: 14, right: 14, top: 6, bottom: 6 })
          .shadow(this.homeMode === WeiboTimelineMode.Recommend && this.selectedTab === WeiboTab.Home
            ? { radius: 8, color: 'rgba(78, 170, 120, 0.35)', offsetY: 2 } : { radius: 0, color: '#00000000' })
          .onClick(() => {
            if (this.selectedTab !== WeiboTab.Home) {
              this.switchTab(WeiboTab.Home);
            }
            this.switchHomeMode(WeiboTimelineMode.Recommend);
          })
      }
      .padding(3)
      .borderRadius(20)
      .backgroundColor(this.isDark ? 'rgba(255, 255, 255, 0.08)' : 'rgba(0, 0, 0, 0.05)')

      Blank()

      // 3. 右侧圆形微型发博按钮 (+)
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
      .onClick(() => {
        this.openComposeDialog();
      })
    }
    .width('100%')
    .padding({ left: Spacing.md, right: Spacing.md })
    .alignItems(VerticalAlign.Center)
    .backgroundColor(Color.Transparent)
    .onTouch((event: TouchEvent): void => {
      this.titleTouchTracker.track(event);
      if (event.type === TouchType.Cancel) { this.resetTabDrag(); }
    })
    .gesture(
      PanGesture({ fingers: 1, direction: PanDirection.Horizontal, distance: 12 })
        .tag('weibo-tab-swipe')
        .onActionStart((): void => {
          this.titleTouchTracker.claim();
          this.tabDragging = true;
        })
        .onActionUpdate((event: GestureEvent): void => {
          this.tabDragOffset = this.titleTouchTracker.update(event, this.homeMode === WeiboTimelineMode.Recommend, this.homeMode === WeiboTimelineMode.Following);
        })
        .onActionEnd((event: GestureEvent): void => { this.onHomeTabPanEnd(event, this.titleTouchTracker); })
        .onActionCancel((): void => {
          this.titleTouchTracker.cancel();
          this.resetTabDrag();
        })
    )
    .onGestureJudgeBegin((info: GestureInfo, event: BaseGestureEvent): GestureJudgeResult => {
      return this.titleTouchTracker.judge(info, event, this.selectedTab === WeiboTab.Home);
    })
  }

  /** HarmonyX-style title-bar bottom region: a material search field below the native title. */
  @Builder
  WeiboSearchBottomBuilder(): void {
    if (this.selectedTab === WeiboTab.Search) {
      Row() {
        Stack() {
        Search({
          value: this.weiboSearchText,
          placeholder: $r('app.string.weibo_search_placeholder')
        })
          .width('100%')
          .height(38)
          .backgroundColor(Color.Transparent)
          .fontColor(Theme.textPrimary(this.isDark))
          .onChange((value: string): void => {
            this.weiboSearchText = value;
          })
          .onFocus((): void => { this.setSearchFocused(true); })
          .onBlur((): void => { this.setSearchFocused(false); })
          .onSubmit((value: string): void => this.submitWeiboSearch(value))
      }
      .width('88%')
      .height(38)
      .scale({ x: this.searchFocusScale, y: this.searchFocusScale })
      .opacity(this.searchFocusOpacity)
      .renderGroup(true)
      .borderRadius(Radius.full)
      .clip(true)
      .systemMaterial(ImmMaterial.seg(false))
      }
      .width('100%')
      .height(56)
      .justifyContent(FlexAlign.Center)
    }
  }

  @Builder
  HomePage() {
    this.HomeFeedContent()
  }

  private async loadNotifications(refresh: boolean = false, more: boolean = false): Promise<void> {
    if (!this.cookieConfigured) { this.notifications = []; this.messagesRefreshing = false; return; }
    if (!refresh && (this.messagesLoading || this.messagesLoadingMore)) { return; }
    if (more && (!this.hasMoreMessages || this.messagePage === 0)) { return; }
    if (refresh) { this.messageEpoch++; }
    const epoch: number = this.messageEpoch;
    const type: 'all' | 'mention' | 'comment' | 'like' = this.messageType;
    const page: number = more ? this.messagePage + 1 : 1;
    this.messagesLoading = !more;
    this.messagesLoadingMore = more;
    this.messageError = '';
    try {
      const items: WeiboNotification[] = await WeiboService.getInstance().fetchNotifications(type, page);
      if (epoch !== this.messageEpoch || type !== this.messageType) { return; }
      const next: WeiboNotification[] = more ? items.filter((item: WeiboNotification): boolean =>
        !this.notifications.some((old: WeiboNotification): boolean => old.id === item.id)) : items;
      this.notifications = more ? this.notifications.concat(next) : next;
      this.messagePage = page;
      this.hasMoreMessages = items.length > 0 && next.length > 0;
      this.messagesLoaded = true;
    } catch (error) {
      if (epoch === this.messageEpoch) { this.messageError = (error as Error).message ?? '消息加载失败，请重试'; }
    } finally {
      if (epoch === this.messageEpoch) {
        this.messagesLoading = false;
        this.messagesLoadingMore = false;
        this.messagesRefreshing = false;
        if (refresh) {
          setTimeout((): void => {
            try {
              this.messagesScroller.scrollEdge(Edge.Top);
            } catch (_e) {}
          }, 100);
        }
      }
    }
  }

  private markNotificationRead(id: string): void {
    if (!this.readNotificationIds.includes(id)) {
      this.readNotificationIds.push(id);
    }
  }

  private openNotificationDetail(item: WeiboNotification): void {
    this.markNotificationRead(item.id);
    if (item.targetPostId.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: '原微博暂不可用或已被删除' });
      return;
    }
    const initialTab: WeiboDetailTab = item.type === 'like' ? WeiboDetailTab.Likes : WeiboDetailTab.Comments;
    const param: WeiboPostDetailRouteParam = {
      postId: item.targetPostId,
      initialTab: initialTab,
      targetCommentId: item.targetCommentId
    };
    this.weiboNavStack.pushPath({ name: 'WeiboPostDetail', param: param });
  }

  private switchMessageType(type: 'all' | 'mention' | 'comment' | 'like'): void {
    if (this.messageType === type) {
      return;
    }
    this.messageType = type;
    this.notifications = [];
    this.messagePage = 0;
    this.messagesLoaded = false;
    this.loadNotifications(true);
  }

  @Builder
  MessageSegmentCapsule(label: string, type: 'all' | 'mention' | 'comment' | 'like') {
    Button({ type: ButtonType.Capsule, stateEffect: true }) {
      Text(label)
        .fontSize(fs(13, this.fontScale))
        .fontWeight(this.messageType === type ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(this.messageType === type ? Color.White : Theme.textSecondary(this.isDark))
    }
    .layoutWeight(1)
    .height(36)
    .backgroundColor(this.messageType === type ? Theme.brand() : Theme.bgCard(this.isDark))
    .border({
      width: this.messageType === type ? 0 : 0.5,
      color: Theme.cardBorder(this.isDark)
    })
    .shadow(this.messageType === type ? {
      radius: 8,
      color: this.isDark ? '#404EAA78' : '#334EAA78',
      offsetY: 2
    } : undefined)
    .onClick((): void => {
      this.switchMessageType(type);
    })
  }

  @Builder
  MessagesPage() {
    Refresh({ refreshing: this.messagesRefreshing }) {
    Scroll(this.messagesScroller) {
      Column({ space: Spacing.md }) {
        if (!this.cookieConfigured) {
          Column({ space: Spacing.sm }) {
            SymbolGlyph($r('sys.symbol.bell'))
              .fontSize(44)
              .fontColor([Theme.brand()])
              .margin({ top: 40 })
            Text('登录后查看互动消息')
              .fontSize(fs(17, this.fontScale))
              .fontWeight(FontWeight.Bold)
              .fontColor(Theme.textPrimary(this.isDark))
            Text('登录你的微博账号，随时掌握收到的评论、赞以及被@提醒')
              .fontSize(fs(13, this.fontScale))
              .fontColor(Theme.textSecondary(this.isDark))
              .textAlign(TextAlign.Center)
              .padding({ left: 24, right: 24 })
            Button('去登录')
              .width(140)
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
        } else {
          // 方案 A: 极简胶囊分段导航 (全宽均匀分布，对齐原型)
          Row({ space: Spacing.sm }) {
            this.MessageSegmentCapsule('全部', 'all')
            this.MessageSegmentCapsule('@我的', 'mention')
            this.MessageSegmentCapsule('评论', 'comment')
            this.MessageSegmentCapsule('赞', 'like')
          }
          .width('100%')
          .padding({ bottom: 4 })

          if (this.messagesLoading) {
            Row({ space: Spacing.sm }) {
              LoadingProgress().width(20).height(20)
              Text('正在拉取消息…')
                .fontSize(fs(13, this.fontScale))
                .fontColor(Theme.textSecondary(this.isDark))
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
            .padding({ top: 60, bottom: 60 })
          } else if (this.messageError.length > 0 && this.notifications.length === 0) {
            Text(this.messageError).fontSize(fs(14, this.fontScale)).fontColor(Theme.danger()).padding(16)
            Button('重新加载').height(44).onClick((): void => { this.loadNotifications(true); })
          } else if (this.notifications.length === 0) {
            Column({ space: Spacing.sm }) {
              Stack() {
                SymbolGlyph($r('sys.symbol.envelope'))
                  .fontSize(36)
                  .fontColor([Theme.brand()])
              }
              .width(68)
              .height(68)
              .borderRadius(34)
              .backgroundColor(this.isDark ? 'rgba(78, 170, 120, 0.15)' : 'rgba(78, 170, 120, 0.10)')
              .alignContent(Alignment.Center)
              .margin({ top: 32, bottom: 4 })

              Text('暂无新互动消息')
                .fontSize(fs(16, this.fontScale))
                .fontWeight(FontWeight.Bold)
                .fontColor(Theme.textPrimary(this.isDark))

              Text('当有人评论、点赞或提到你时，会在这里显示')
                .fontSize(fs(13, this.fontScale))
                .fontColor(Theme.textTertiary(this.isDark))
                .textAlign(TextAlign.Center)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Center)
            .padding({ top: 20, bottom: 60 })
          } else {
            ForEach(this.notifications, (item: WeiboNotification): void => {
              Row({ space: Spacing.md }) {
                // 头像及右下角动作微徽标
                Stack({ alignContent: Alignment.BottomEnd }) {
                  if (item.senderAvatar.length > 0) {
                    Image(item.senderAvatar)
                      .width(42)
                      .height(42)
                      .borderRadius(21)
                      .objectFit(ImageFit.Cover)
                      .onClick(() => {
                        if (item.senderId.length > 0) {
                          const param: WeiboUserProfileRouteParam = { userId: item.senderId, userName: item.senderName };
                          this.weiboNavStack.pushPath({ name: 'WeiboUserProfile', param: param });
                        }
                      })
                  } else {
                    Stack() {
                      Text(item.senderName.substring(0, 1))
                        .fontSize(fs(16, this.fontScale))
                        .fontColor(Color.White)
                        .fontWeight(FontWeight.Bold)
                    }
                    .width(42)
                    .height(42)
                    .borderRadius(21)
                    .backgroundColor(Theme.brand())
                    .alignContent(Alignment.Center)
                  }

                  // 动作微标
                  Stack() {
                    SymbolGlyph(item.type === 'like' ? $r('sys.symbol.heart_fill') :
                      (item.type === 'comment' ? $r('sys.symbol.ellipsis_message') : $r('sys.symbol.at')))
                      .fontSize(10)
                      .fontColor([item.type === 'like' ? '#E05252' : Theme.brand()])
                  }
                  .width(18)
                  .height(18)
                  .borderRadius(9)
                  .backgroundColor(Theme.bgCard(this.isDark))
                  .border({ width: 1.5, color: Theme.bg(this.isDark) })
                  .alignContent(Alignment.Center)
                  .offset({ x: 2, y: 2 })
                }
                .width(44)
                .height(44)
                .alignSelf(ItemAlign.Start)

                Column({ space: 5 }) {
                  Row() {
                    Text(item.senderName)
                      .fontSize(fs(14, this.fontScale))
                      .fontWeight(FontWeight.Bold)
                      .fontColor(Theme.textPrimary(this.isDark))
                      .layoutWeight(1)
                      .onClick(() => {
                        if (item.senderId.length > 0) {
                          const param: WeiboUserProfileRouteParam = { userId: item.senderId, userName: item.senderName };
                          this.weiboNavStack.pushPath({ name: 'WeiboUserProfile', param: param });
                        }
                      })
                    if (!this.readNotificationIds.includes(item.id)) {
                      Circle({ width: 6, height: 6 })
                        .fill(Theme.brand())
                        .margin({ right: 6 })
                    }
                    Text(item.createdAt)
                      .fontSize(fs(11, this.fontScale))
                      .fontColor(Theme.textTertiary(this.isDark))
                  }
                  .width('100%')

                  Text(item.title)
                    .fontSize(fs(12, this.fontScale))
                    .fontColor(item.type === 'like' ? '#E05252' : Theme.brand())

                  if (item.content.length > 0) {
                    WeiboRichTextView({
                      text: item.content, fontSize: fs(14, this.fontScale), lineHeight: fs(20, this.fontScale),
                      fontColor: Theme.textPrimary(this.isDark),
                      onTopicClick: (topic: string): void => {
                        const param: WeiboSearchResultRouteParam = { query: topic };
                        this.weiboNavStack.pushPath({ name: 'WeiboSearchResult', param: param });
                      },
                      onMentionClick: (name: string): void => {
                        const param: WeiboUserProfileRouteParam = { userId: '', userName: name };
                        this.weiboNavStack.pushPath({ name: 'WeiboUserProfile', param: param });
                      }
                    }).width('100%')
                  }

                  if (item.targetSnippet.length > 0) {
                    Row({ space: 6 }) {
                      Text('原贴')
                        .fontSize(fs(10, this.fontScale))
                        .fontColor(Theme.brand())
                        .backgroundColor(this.isDark ? '#264EAA78' : '#144EAA78')
                        .padding({ left: 5, right: 5, top: 1, bottom: 1 })
                        .borderRadius(4)
                      Text(item.targetSnippet)
                        .fontSize(fs(12, this.fontScale))
                        .fontColor(Theme.textSecondary(this.isDark))
                        .maxLines(2)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .layoutWeight(1)
                    }
                    .padding(9)
                    .width('100%')
                    .backgroundColor(this.isDark ? '#14FFFFFF' : '#08000000')
                    .borderRadius(Radius.md)
                    .border({ width: 0.5, color: Theme.cardBorder(this.isDark) })
                    .onClick(() => {
                      if (item.targetPostId.length > 0) {
                        const param: WeiboPostDetailRouteParam = { postId: item.targetPostId };
                        this.weiboNavStack.pushPath({ name: 'WeiboPostDetail', param: param });
                      }
                    })
                  }
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
              }
              .width('100%')
              .padding(Spacing.lg)
              .backgroundColor(Theme.bgCard(this.isDark))
              .borderRadius(Radius.postCard)
              .shadow(Theme.glassShadowStyle())
              .border({ width: 0.5, color: Theme.cardBorder(this.isDark) })
              .onClick(() => {
                this.openNotificationDetail(item);
              })
            }, (item: WeiboNotification): string => item.id)
            if (this.messagesLoadingMore) {
              LoadingProgress().width(24).height(44)
            } else if (this.hasMoreMessages || this.messageError.length > 0) {
              Button(this.messageError.length > 0 ? `${this.messageError} · 重试` : '加载更多消息')
                .height(44).onClick((): void => { this.loadNotifications(false, true); })
            } else {
              Text('已显示全部消息').fontSize(fs(13, this.fontScale)).fontColor(Theme.textSecondary(this.isDark)).padding(12)
            }
          }
        }
      }
      .width('100%')
      .padding({ top: Spacing.md, left: Spacing.lg, right: Spacing.lg, bottom: 120 })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
    .backgroundColor(Theme.bg(this.isDark))
    .onDidScroll((xOffset: number, yOffset: number, scrollState: ScrollState): void => {
      if (scrollState !== ScrollState.Scroll) { return; }
      if (this.messagesScroller.currentOffset().yOffset <= 0) {
        this.setTabBarVisible(true);
        return;
      }
      if (yOffset > 8) { this.setTabBarVisible(false); }
      else if (yOffset < -8) { this.setTabBarVisible(true); }
    })
    .onScrollEdge((edge: Edge): void => {
      if (edge === Edge.Bottom && this.messageError.length === 0) { this.loadNotifications(false, true); }
    })
    }
    .onRefreshing((): void => {
      this.messagesRefreshing = true;
      Haptic.light();
      this.loadNotifications(true);
    })
  }

  @Builder
  MineEntry(icon: Resource, title: ResourceStr, note: ResourceStr, onTap: () => void, isLast: boolean = false): void {
    Row({ space: Spacing.md }) {
      SymbolGlyph(icon)
        .fontSize(fs(20, this.fontScale))
        .fontColor([Theme.brand()])
        .width(28)
      Column({ space: 3 }) {
        Text(title)
          .fontSize(fs(15, this.fontScale))
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textPrimary(this.isDark))
        Text(note)
          .fontSize(fs(12, this.fontScale))
          .fontColor(Theme.textSecondary(this.isDark))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(fs(16, this.fontScale))
        .fontColor([Theme.textTertiary(this.isDark)])
    }
    .width('100%')
    .padding({ left: Spacing.lg, right: Spacing.lg, top: 14, bottom: 14 })
    .border(isLast ? { width: 0 } : { width: { bottom: 0.5 }, color: Theme.manualGlassBorder() })
    .onClick(() => { onTap(); })
  }

  private async openMyPosts(): Promise<void> {
    if (!this.cookieConfigured) {
      this.getUIContext().getPromptAction().showToast({ message: '请先登录微博账号' });
      this.openLogin();
      return;
    }
    let userId: string = this.accountProfile === null ? '' : this.accountProfile.id;
    if (userId.length === 0) {
      try {
        const account: WeiboUser = await WeiboService.getInstance().fetchCurrentUserProfile();
        this.accountProfile = account;
        userId = account.id;
      } catch (_error) {
      }
    }
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/WeiboFeed',
      params: { userId: userId, ownProfile: 'true', mode: 'user' }
    }).catch(() => {
      this.getUIContext().getPromptAction().showToast({ message: '我的微博打开失败，请稍后重试' });
    });
  }

  private openFollowing(): void {
    if (!this.cookieConfigured) {
      this.getUIContext().getPromptAction().showToast({ message: '请先登录微博后查看关注动态' });
      this.openLogin();
      return;
    }
    this.switchHomeMode(WeiboTimelineMode.Following);
    this.switchTab(WeiboTab.Home);
  }

  private openFavorites(): void {
    if (!this.cookieConfigured) {
      this.getUIContext().getPromptAction().showToast({ message: '请先登录微博后查看我的收藏' });
      this.openLogin();
      return;
    }
    const uid: string = this.accountProfile?.id ?? '';
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/WeiboFeed',
      params: { mode: 'favorites', userId: uid }
    }).catch(() => {
      this.getUIContext().getPromptAction().showToast({ message: '收藏页面打开失败，请稍后重试' });
    });
  }

  private openLikes(): void {
    if (!this.cookieConfigured) {
      this.getUIContext().getPromptAction().showToast({ message: '请先登录微博后查看我的点赞' });
      this.openLogin();
      return;
    }
    const uid: string = this.accountProfile?.id ?? '';
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/WeiboFeed',
      params: { mode: 'likes', userId: uid }
    }).catch(() => {
      this.getUIContext().getPromptAction().showToast({ message: '点赞页面打开失败，请稍后重试' });
    });
  }

  private openHistory(): void {
    const uid: string = this.accountProfile?.id ?? '';
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/WeiboFeed',
      params: { mode: 'history', userId: uid }
    }).catch(() => {
      this.getUIContext().getPromptAction().showToast({ message: '浏览历史打开失败，请稍后重试' });
    });
  }

  private async logout(switchAccount: boolean = false): Promise<void> {
    if (this.sessionResetting) { return; }
    this.sessionResetting = true;
    const cleanup: Promise<void> = WeiboAuthManager.getInstance().clearCookie();
    this.accountProfile = null;
    this.cookieConfigured = false;
    AppStorage.setOrCreate<number>('weiboAuthTick', (AppStorage.get<number>('weiboAuthTick') ?? 0) + 1);
    try {
      await cleanup;
      AppStorage.setOrCreate<number>('weiboAuthTick', (AppStorage.get<number>('weiboAuthTick') ?? 0) + 1);
      this.logoutRetryRequired = false;
      this.getUIContext().getPromptAction().showToast({ message: switchAccount ? '旧账号会话已清除，请登录其他账号' : '已退出登录' });
      if (switchAccount) { this.openLogin(); }
    } catch (error) {
      this.logoutRetryRequired = true;
      this.getUIContext().getPromptAction().showToast({ message: (error as Error).message ?? '退出清理失败，请重试' });
    } finally { this.sessionResetting = false; }
  }

  private openLogin(): void {
    if (this.logoutRetryRequired) {
      this.getUIContext().getPromptAction().showToast({ message: '请先重试退出清理，避免重新使用旧账号' });
      return;
    }
    this.getUIContext().getRouter().pushUrl({ url: 'pages/WeiboLogin' }).catch(() => {
      this.getUIContext().getPromptAction().showToast({ message: '登录页打开失败，请稍后重试' });
    });
  }

  private clearImageCache(): void {
    try {
      const result = ImageCache.clearAllCache();
      const size: string = result.deletedBytes < 1024 * 1024
        ? `${(result.deletedBytes / 1024).toFixed(1)} KB` : `${(result.deletedBytes / (1024 * 1024)).toFixed(1)} MB`;
      const message: string = result.failedFiles > 0
        ? `已清理 ${size}，${result.failedFiles} 个缓存文件清理失败，请重试`
        : `已清理 ${size} 本地图片缓存`;
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (_error) {
      this.getUIContext().getPromptAction().showToast({ message: '读取或清理图片缓存失败，请稍后重试' });
    }
  }

  private openSettings(): void {
    this.getUIContext().getRouter().pushUrl({ url: 'pages/WeiboSettings' }).catch(() => {
      this.getUIContext().getPromptAction().showToast({ message: '设置页打开失败，请稍后重试' });
    });
  }

  private openAboutSoftware(): void {
    this.getUIContext().getRouter().pushUrl({ url: 'pages/AboutSoftware' }).catch(() => {
      this.getUIContext().getPromptAction().showToast({ message: '关于软件页面打开失败，请稍后重试' });
    });
  }

  @Builder
  MinePage() {
    Scroll(this.mineScroller) {
      Column({ space: Spacing.md }) {
        if (this.cookieConfigured && this.accountProfile !== null) {
          Column({ space: Spacing.md }) {
            Row({ space: Spacing.md }) {
              if (this.accountProfile.avatarUrl.length > 0) {
                Image(this.accountProfile.avatarUrl)
                  .width(58)
                  .height(58)
                  .borderRadius(Radius.full)
                  .objectFit(ImageFit.Cover)
              } else {
                Stack() {
                  Text(this.accountProfile.screenName.substring(0, 1))
                    .fontSize(fs(22, this.fontScale))
                    .fontWeight(FontWeight.Bold)
                    .fontColor(Color.White)
                }
                .width(58)
                .height(58)
                .borderRadius(Radius.full)
                .backgroundColor(Theme.brand())
                .alignContent(Alignment.Center)
              }
              Column({ space: 4 }) {
                Text(this.accountProfile.screenName)
                  .fontSize(fs(18, this.fontScale))
                  .fontWeight(FontWeight.Bold)
                  .fontColor(Theme.textPrimary(this.isDark))
                Text(this.accountProfile.description.length > 0 ? this.accountProfile.description : '已登录微博')
                  .fontSize(fs(12, this.fontScale))
                  .fontColor(Theme.textSecondary(this.isDark))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')

            Row() {
              Column({ space: 3 }) {
                Text(`${this.accountProfile.followingCount}`).fontSize(fs(17, this.fontScale)).fontWeight(FontWeight.Bold)
                  .fontColor(Theme.textPrimary(this.isDark))
                Text('关注').fontSize(fs(11, this.fontScale)).fontColor(Theme.textSecondary(this.isDark))
              }.layoutWeight(1).alignItems(HorizontalAlign.Center)
              Column({ space: 3 }) {
                Text(this.accountProfile.followersCount).fontSize(fs(17, this.fontScale)).fontWeight(FontWeight.Bold)
                  .fontColor(Theme.textPrimary(this.isDark))
                Text('粉丝').fontSize(fs(11, this.fontScale)).fontColor(Theme.textSecondary(this.isDark))
              }.layoutWeight(1).alignItems(HorizontalAlign.Center)
              Column({ space: 3 }) {
                Text(`${this.accountProfile.statusesCount}`).fontSize(fs(17, this.fontScale)).fontWeight(FontWeight.Bold)
                  .fontColor(Theme.textPrimary(this.isDark))
                Text('微博').fontSize(fs(11, this.fontScale)).fontColor(Theme.textSecondary(this.isDark))
              }.layoutWeight(1).alignItems(HorizontalAlign.Center)
            }
            .width('100%')
            .padding({ top: Spacing.sm })
            .border({ width: { top: 0.5 }, color: Theme.manualGlassBorder() })
          }
          .width('100%')
          .padding(Spacing.lg)
          .backgroundColor(Theme.bgCard(this.isDark))
          .borderRadius(Radius.postCard)
          .shadow(Theme.glassShadowStyle())
        } else {
          Column({ space: Spacing.sm }) {
            Text(this.accountLoading ? '正在读取微博账号…' :
              (this.cookieConfigured ? '微博账号资料暂不可用' : $r('app.string.weibo_mine_cookie_missing')))
              .fontSize(fs(16, this.fontScale))
              .fontWeight(FontWeight.Medium)
              .fontColor(Theme.textPrimary(this.isDark))
            Text($r('app.string.weibo_mine_cookie_note'))
              .fontSize(fs(13, this.fontScale))
              .fontColor(Theme.textSecondary(this.isDark))
              .lineHeight(fs(19, this.fontScale))
          }
          .width('100%')
          .padding(Spacing.lg)
          .backgroundColor(Theme.bgCard(this.isDark))
          .borderRadius(Radius.postCard)
        }

        Column() {
          this.MineEntry($r('sys.symbol.doc'), '我的微博', '读取当前登录账号发布的微博', () => { this.openMyPosts(); })
          this.MineEntry($r('sys.symbol.star'), '我的收藏', '查看已收藏的微博', () => { this.openFavorites(); })
          this.MineEntry($r('sys.symbol.heart'), '我的点赞', '查看点赞过的微博历史', () => { this.openLikes(); })
          this.MineEntry($r('sys.symbol.clock'), '浏览历史', '找回最近看过的微博', () => { this.openHistory(); }, true)
        }
        .width('100%')
        .backgroundColor(Theme.bgCard(this.isDark))
        .borderRadius(Radius.postCard)
        .shadow(Theme.glassShadowStyle())

        Column() {
          if (this.cookieConfigured) {
            this.MineEntry($r('sys.symbol.person_2'), '切换账号', '清除旧账号网页会话后重新登录', () => { this.logout(true); })
          }
          if (this.logoutRetryRequired) {
            this.MineEntry($r('sys.symbol.arrow_clockwise'), '重试退出清理', '上次清理失败，完成后才能重新登录', () => { this.logout(); })
          }
          this.MineEntry($r('sys.symbol.arrow_clockwise'), '刷新账号资料', '重新读取昵称、头像和统计数据', () => { this.loadAccountProfile(); })
          this.MineEntry($r('sys.symbol.trash'), '清理图片缓存', '释放本地已下载的微博配图缓存', () => { this.clearImageCache(); }, true)
        }
        .width('100%')
        .backgroundColor(Theme.bgCard(this.isDark))
        .borderRadius(Radius.postCard)
        .shadow(Theme.glassShadowStyle())

        Row({ space: Spacing.sm }) {
          Button(this.cookieConfigured ? $r('app.string.weibo_login_reauth') : $r('app.string.weibo_login_title'))
            .layoutWeight(1)
            .height(48)
            .fontSize(fs(15, this.fontScale))
            .backgroundColor(Theme.manualGlass(this.isDark, true))
            .fontColor(Color.White)
            .border({ width: 0.5, color: Theme.manualGlassBorder() })
            .shadow(Theme.glassShadowStyle())
            .backgroundEffect(ImmBlur.accent())
            .systemMaterial(ImmMaterial.accent(this.isDark))
            .borderRadius(Radius.full)
            .enabled(!this.sessionResetting)
            .onClick(() => { this.openLogin(); })

          if (this.cookieConfigured) {
            Button('退出登录')
              .width(100)
              .height(48)
              .fontSize(fs(15, this.fontScale))
              .backgroundColor(this.isDark ? '#26FF3B30' : '#14FF3B30')
              .fontColor(Theme.danger())
              .border({ width: 0.5, color: Theme.danger() })
              .borderRadius(Radius.full)
              .enabled(!this.sessionResetting)
              .onClick(() => { this.logout(); })
          }
        }
        .width('100%')
      }
      .width('100%')
      .padding({ top: this.contentTopInset(), left: Spacing.lg, right: Spacing.lg, bottom: 120 })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    .backgroundColor(Theme.bg(this.isDark))
    .onDidScroll((xOffset: number, yOffset: number, scrollState: ScrollState): void => {
      if (scrollState !== ScrollState.Scroll) { return; }
      if (this.mineScroller.currentOffset().yOffset <= 0) {
        this.setTabBarVisible(true);
        return;
      }
      if (yOffset > 8) { this.setTabBarVisible(false); }
      else if (yOffset < -8) { this.setTabBarVisible(true); }
    })
  }

  private symbolFor(index: number): Resource {
    if (index === WeiboTab.Discover) {
      return $r('sys.symbol.compass');
    }
    if (index === WeiboTab.Search) {
      return $r('sys.symbol.magnifyingglass');
    }
    if (index === WeiboTab.Messages) {
      return $r('sys.symbol.bell_fill');
    }
    if (index === WeiboTab.Mine) {
      return $r('sys.symbol.person_fill');
    }
    return $r('sys.symbol.house_fill');
  }

  private hdsTabBar(icon: Resource, label: Resource): BottomTabBarStyle {
    const normalGlyph: SymbolGlyphModifier = new SymbolGlyphModifier(icon)
      .renderingStrategy(SymbolRenderingStrategy.SINGLE);
    normalGlyph.fontColor([$r('sys.color.icon_primary')]);
    const selectedGlyph: SymbolGlyphModifier = new SymbolGlyphModifier(icon)
      .renderingStrategy(SymbolRenderingStrategy.SINGLE);
    selectedGlyph.fontColor([this.accentColor]);
    return BottomTabBarStyle.of({ normal: normalGlyph, selected: selectedGlyph }, label)
      .labelStyle({
        unselectedColor: $r('sys.color.font_primary'),
        selectedColor: this.accentColor
      })
      .padding({ bottom: 0 });
  }

  @Builder
  HdsTabContents() {
    TabContent() {
      this.HomePage()
    }
    .tabBar(this.hdsTabBar(this.symbolFor(WeiboTab.Home), $r('app.string.weibo_tab_home')))

    TabContent() {
      WeiboHotSearch({
        pageScroller: this.discoverScroller,
        topInset: this.topAvoidAreaVp() + 10,
        animationTrigger: this.page2Enter,
        exitTrigger: this.page2Exit,
        onScrollDirection: (visible: boolean): void => this.setTabBarVisible(visible),
        onSelectTopic: (topic: WeiboHotTopic): void => {
          this.openSearchTopic(topic.word);
        },
        onOpenUserProfile: (userId: string, userName: string): void => {
          this.openUserProfile(userId, userName);
        }
      })
    }
    .tabBar(this.hdsTabBar(this.symbolFor(WeiboTab.Discover), $r('app.string.weibo_tab_discover')))

    TabContent() {
      this.MessagesPage()
    }
    .tabBar(this.hdsTabBar(this.symbolFor(WeiboTab.Messages), $r('app.string.weibo_tab_messages')))

    TabContent() {
      this.MinePage()
    }
    .tabBar(this.hdsTabBar(this.symbolFor(WeiboTab.Mine), $r('app.string.weibo_tab_mine')))
  }

  /** One native title slot for the tab shell; individual pages only own scrollable content. */
  @Builder
  HdsPageTitle(title: Resource): void {
    Text(title)
      .fontSize(fs(20, this.fontScale))
      .fontWeight(FontWeight.Bold)
      .fontColor(Theme.textPrimary(this.isDark))
  }

  /** One native title slot for the tab shell; individual pages only own scrollable content. */
  @Builder
  HdsTitleBarContent(): void {
    if (this.privacyReady && this.privacyAccepted && this.selectedTab === WeiboTab.Home) {
      this.HomeTitleBar()
    } else {
      Column().width('100%').height(0)
    }
  }

  @Builder
  HdsTabsShell() {
    HdsTabs({ controller: this.hdsTabsController, index: this.selectedTab }) {
      this.HdsTabContents()
    }
    .width('100%')
    .height('100%')
    .barPosition(BarPosition.End)
    .barOverlap(true)
    .scrollable(this.selectedTab !== WeiboTab.Home)
    .animationDuration(0)
    .attributeModifier(this.hdsTabsModifier)
    .backgroundColor(Theme.bg(this.isDark))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .onChange((index: number): void => {
      this.switchTab(index);
    })
    .onTabBarClick((index: number): void => {
      this.onTabBarClick(index);
    })
    .onAnimationStart((currentIndex: number, targetIndex: number, event: TabsAnimationEvent): void => {
      this.onTabAnimationStart(currentIndex, targetIndex, event);
    })
  }

  /** Accent material instances are immutable, so remount the tab shell after a theme-color change. */
  @Builder
  AccentResponsiveTabs(): void {
    if (this.appAccentTick % 2 === 0) {
      this.HdsTabsShell()
    } else {
      this.HdsTabsShell()
    }
  }

  /** HDS route dispatcher: child destinations own their title material and scroll linkage. */
  @Builder
  WeiboNavigationBuilder(name: string): void {
    if (name === 'WeiboPostDetail') {
      WeiboPostDetailBuilder()
    } else if (name === 'WeiboUserProfile') {
      WeiboUserProfileBuilder()
    } else if (name === 'WeiboBrowser') {
      WeiboBrowserBuilder()
    } else if (name === 'WeiboSearchResult') {
      WeiboSearchResultBuilder()
    }
  }

  build() {
    HdsNavigation(this.weiboNavStack) {
      Stack({ alignContent: Alignment.Bottom }) {
        if (!this.privacyReady || !this.privacyAccepted) {
          this.PrivacyGate()
        } else {
          this.AccentResponsiveTabs()
        }
        if (this.weiboReady && !this.cookieConfigured) {
          WeiboVisitorBootstrap()
            .position({ x: -1, y: -1 })
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.bg(this.isDark))
    }
    .titleBar({
      style: this.titleBarStyle(),
      avoidLayoutSafeArea: true,
      content: {
        title: {
          mainTitle: this.privacyReady && this.privacyAccepted &&
            this.selectedTab !== WeiboTab.Home && this.selectedTab !== WeiboTab.Discover
            ? this.currentHdsTitle() : ''
        },
        stackBuilder: (): void => this.HdsTitleBarContent(),
        bottomBuilder: {
          builder: (): void => this.WeiboSearchBottomBuilder(),
          height: this.selectedTab === WeiboTab.Search ? 56 : 0,
          showType: BottomBuilderShowType.DIRECTLY_SHOW
        },
        divider: { showType: DividerShowType.OFF }
      }
    })
    .navDestination(this.WeiboNavigationBuilder)
    .mode(this.mainNavigationMode)
    .navBarWidth(480)
    .minContentWidth(360)
    .titleMode(HdsNavigationTitleMode.MINI)
    // Discover owns its search field; an empty native title bar still intercepts its taps.
    .hideTitleBar(this.privacyReady && this.privacyAccepted && this.selectedTab === WeiboTab.Discover)
    .hideBackButton(true)
    .bindToScrollable([
      this.homeRecommendScroller,
      this.homeFollowingScroller,
      this.discoverScroller,
      this.searchScroller,
      this.messagesScroller,
      this.mineScroller
    ])
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg(this.isDark))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
