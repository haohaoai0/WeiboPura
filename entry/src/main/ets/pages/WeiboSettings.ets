import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { ImmMaterial, Radius, Spacing, Theme, fs, isDarkMode, resetConfigurationToFollowSystem, setDarkMode, syncDarkFromConfig } from '../common/Theme';
import {
  AppSettingsStore,
  APP_LANGUAGE_EN,
  APP_LANGUAGE_ZH_CN,
  DEFAULT_HOME_TAB_MATERIAL_LEVEL
} from '../service/AppSettingsStore';
import { UsageHabitsManager } from '../service/UsageHabitsManager';
import { HdsNavigation, HdsNavigationTitleMode, ScrollEffectType, hdsMaterial } from '@kit.UIDesignKit';

const ACCENT_OPTIONS: string[] = ['#E6162D', '#007DFF', '#7856FF', '#00A870', '#F59E0B'];

@Entry
@Component
export struct WeiboSettings {
  @State isDark: boolean = isDarkMode();
  @StorageLink('fontScale') fontScale: number = 1.0;
  @StorageLink('darkTick') @Watch('onDarkTick') darkTick: number = 0;
  @StorageLink('appAccentColor') accentColor: string = '#E6162D';
  @StorageLink('appLanguage') appLanguage: string = APP_LANGUAGE_ZH_CN;
  @StorageLink('homeTabMaterialLevel') homeTabMaterialLevel: number = DEFAULT_HOME_TAB_MATERIAL_LEVEL;
  @StorageLink('columnMode') columnMode: number = 0;
  @StorageLink('weibo.top_rect_height') topRectHeight: number = 0;
  private settingsScroller: Scroller = new Scroller();

  private contentTopInset(): number {
    return this.getUIContext().px2vp(this.topRectHeight) + 56;
  }

  async aboutToAppear(): Promise<void> {
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    await UsageHabitsManager.getInstance().init(context);
    await AppSettingsStore.getInstance().init(context);
    this.isDark = isDarkMode();
  }

  private onDarkTick(): void {
    this.isDark = isDarkMode();
  }

  private setDisplayMode(mode: number): void {
    const habits: UsageHabitsManager = UsageHabitsManager.getInstance();
    if (mode === 0) {
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const systemDark: boolean = context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
      habits.setFollowSystemDark(true);
      habits.setDarkModeManual(systemDark);
      resetConfigurationToFollowSystem();
      syncDarkFromConfig(systemDark);
      this.isDark = systemDark;
    } else {
      const target: boolean = mode === 2;
      habits.setFollowSystemDark(false);
      habits.setDarkModeManual(target);
      setDarkMode(target);
      this.isDark = target;
    }
    AppStorage.setOrCreate<number>('darkTick', (AppStorage.get<number>('darkTick') ?? 0) + 1);
  }

  private displayMode(): number {
    if (UsageHabitsManager.getInstance().isFollowSystemDark()) {
      return 0;
    }
    return UsageHabitsManager.getInstance().isDarkModeManual() ? 2 : 1;
  }

  private async selectAccent(color: string): Promise<void> {
    await AppSettingsStore.getInstance().setAccent(color);
  }

  private async selectLanguage(language: string): Promise<void> {
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      const updated: boolean = await AppSettingsStore.getInstance().setLanguage(context, language);
      this.getUIContext().getPromptAction().showToast({ message: updated ? '应用语言已更新' : '应用语言更新失败' });
    } catch (error) {
      this.getUIContext().getPromptAction().showToast({ message: '应用语言更新失败' });
    }
  }

  private homeTabMaterialIndex(): number {
    if (this.homeTabMaterialLevel === 0) {
      return 0;
    }
    if (this.homeTabMaterialLevel === 1) {
      return 1;
    }
    if (this.homeTabMaterialLevel === 2) {
      return 2;
    }
    return 3;
  }

  private homeTabMaterialLabel(): Resource {
    if (this.homeTabMaterialLevel === 0) {
      return $r('app.string.weibo_home_tab_material_exquisite');
    }
    if (this.homeTabMaterialLevel === 1) {
      return $r('app.string.weibo_home_tab_material_gentle');
    }
    if (this.homeTabMaterialLevel === 2) {
      return $r('app.string.weibo_home_tab_material_smooth');
    }
    return $r('app.string.weibo_home_tab_material_adaptive');
  }

  private async selectHomeTabMaterial(index: number): Promise<void> {
    let level: number = DEFAULT_HOME_TAB_MATERIAL_LEVEL;
    if (index === 0) {
      level = 0;
    } else if (index === 1) {
      level = 1;
    } else if (index === 2) {
      level = 2;
    }
    await AppSettingsStore.getInstance().setHomeTabMaterialLevel(level);
  }

  private columnModeIndex(): number {
    return this.columnMode === 1 || this.columnMode === 2 ? this.columnMode : 0;
  }

  private columnModeLabel(): Resource {
    if (this.columnMode === 1) {
      return $r('app.string.weibo_waterfall_columns_balanced');
    }
    if (this.columnMode === 2) {
      return $r('app.string.weibo_waterfall_columns_dense');
    }
    return $r('app.string.weibo_waterfall_columns_adaptive');
  }

  private async selectColumnMode(index: number): Promise<void> {
    await UsageHabitsManager.getInstance().setColumnMode(index);
  }

  @Builder
  private HomeTabMaterialTitle(): void {
    Column({ space: 3 }) {
      Text($r('app.string.weibo_home_tab_material_title'))
        .fontSize(fs(17, this.fontScale))
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.textPrimary(this.isDark))
      Text($r('app.string.weibo_home_tab_material_note'))
        .fontSize(fs(12, this.fontScale))
        .fontColor(Theme.textSecondary(this.isDark))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private WaterfallColumnsTitle(): void {
    Column({ space: 3 }) {
      Text($r('app.string.weibo_waterfall_columns_title'))
        .fontSize(fs(17, this.fontScale))
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.textPrimary(this.isDark))
      Text($r('app.string.weibo_waterfall_columns_note'))
        .fontSize(fs(12, this.fontScale))
        .fontColor(Theme.textSecondary(this.isDark))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private BackBar(): void {
    Row({ space: Spacing.sm }) {
      Button() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(fs(28, this.fontScale))
          .fontColor([Theme.iconPrimary(this.isDark)])
      }
      .width(44)
      .height(44)
      .backgroundColor(Color.Transparent)
      .systemMaterial(ImmMaterial.control())
      .borderRadius(Radius.full)
      .onClick(() => { this.getUIContext().getRouter().back(); })
      Text('软件设置')
        .fontSize(fs(20, this.fontScale))
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.textPrimary(this.isDark))
    }
    .width('100%')
    .padding({ left: Spacing.lg, right: Spacing.lg, top: 44, bottom: Spacing.sm })
  }

  @Builder
  private ModeOption(mode: number, icon: Resource, title: string): void {
    Column({ space: Spacing.sm }) {
      SymbolGlyph(icon)
        .fontSize(fs(26, this.fontScale))
        .fontColor([this.displayMode() === mode ? Theme.brand() : Theme.iconPrimary(this.isDark)])
      Text(title)
        .fontSize(fs(13, this.fontScale))
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.textPrimary(this.isDark))
    }
    .width(96)
    .height(88)
    .justifyContent(FlexAlign.Center)
    .borderRadius(Radius.lg)
    .backgroundColor(this.displayMode() === mode ? Theme.brandBg(this.isDark) : Theme.bgCard(this.isDark))
    .border({ width: this.displayMode() === mode ? 2 : 0.5,
      color: this.displayMode() === mode ? Theme.brand() : Theme.divider(this.isDark) })
    .onClick(() => { this.setDisplayMode(mode); })
  }

  @Builder
  private SectionTitle(title: string, note: string): void {
    Column({ space: 3 }) {
      Text(title)
        .fontSize(fs(17, this.fontScale))
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.textPrimary(this.isDark))
      Text(note)
        .fontSize(fs(12, this.fontScale))
        .fontColor(Theme.textSecondary(this.isDark))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private LanguageOption(language: string, title: string, note: string): void {
    Row({ space: Spacing.md }) {
      Column({ space: 3 }) {
        Text(title).fontSize(fs(16, this.fontScale)).fontColor(Theme.textPrimary(this.isDark))
        Text(note).fontSize(fs(12, this.fontScale)).fontColor(Theme.textSecondary(this.isDark))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      if (this.appLanguage === language) {
        SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
          .fontSize(fs(22, this.fontScale))
          .fontColor([Theme.brand()])
      }
    }
    .width('100%')
    .padding(Spacing.lg)
    .backgroundColor(Theme.bgCard(this.isDark))
    .borderRadius(Radius.lg)
    .onClick(() => { this.selectLanguage(language); })
  }

  build() {
    HdsNavigation() {
      Scroll(this.settingsScroller) {
        Column({ space: Spacing.md }) {
          this.SectionTitle('外观', '选择跟随系统、浅色或深色显示模式')
          Row({ space: Spacing.sm }) {
            this.ModeOption(0, $r('sys.symbol.phone'), '跟随系统')
            this.ModeOption(1, $r('sys.symbol.sun_max'), '浅色')
            this.ModeOption(2, $r('sys.symbol.moon_fill'), '深色')
          }
          .width('100%')
          .justifyContent(FlexAlign.SpaceBetween)
          .padding(Spacing.lg)
          .backgroundColor(Theme.bgCard(this.isDark))
          .borderRadius(Radius.lg)

          this.SectionTitle('应用主题色', '会立即应用到微博红色强调元素')
          Row({ space: Spacing.md }) {
            ForEach(ACCENT_OPTIONS, (color: string): void => {
              Stack({ alignContent: Alignment.Center }) {
                Circle({ width: 30, height: 30 }).fill(color)
                if (this.accentColor === color) {
                  SymbolGlyph($r('sys.symbol.checkmark'))
                    .fontSize(fs(16, this.fontScale))
                    .fontColor([Color.White])
                }
              }
              .width(40)
              .height(40)
              .borderRadius(Radius.full)
              .border({ width: this.accentColor === color ? 2 : 0, color: Theme.textPrimary(this.isDark) })
              .onClick(() => { this.selectAccent(color); })
            }, (color: string): string => color)
          }
          .width('100%')
          .justifyContent(FlexAlign.SpaceBetween)
          .padding(Spacing.lg)
          .backgroundColor(Theme.bgCard(this.isDark))
          .borderRadius(Radius.lg)

          this.HomeTabMaterialTitle()
          Row({ space: Spacing.md }) {
            Text($r('app.string.weibo_home_tab_material_label'))
              .layoutWeight(1)
              .fontSize(fs(16, this.fontScale))
              .fontColor(Theme.textPrimary(this.isDark))
            Select([
              { value: $r('app.string.weibo_home_tab_material_exquisite') },
              { value: $r('app.string.weibo_home_tab_material_gentle') },
              { value: $r('app.string.weibo_home_tab_material_smooth') },
              { value: $r('app.string.weibo_home_tab_material_adaptive') }
            ])
              .selected(this.homeTabMaterialIndex())
              .value(this.homeTabMaterialLabel())
              .fontColor(Theme.textPrimary(this.isDark))
              .selectedOptionFontColor(Theme.brand())
              .selectedOptionBgColor(Theme.brandBg(this.isDark))
              .onSelect((index: number): void => {
                this.selectHomeTabMaterial(index);
              })
          }
          .width('100%')
          .padding(Spacing.lg)
          .backgroundColor(Theme.bgCard(this.isDark))
          .borderRadius(Radius.lg)

          this.WaterfallColumnsTitle()
          Row({ space: Spacing.md }) {
            Text($r('app.string.weibo_waterfall_columns_label'))
              .layoutWeight(1)
              .fontSize(fs(16, this.fontScale))
              .fontColor(Theme.textPrimary(this.isDark))
            Select([
              { value: $r('app.string.weibo_waterfall_columns_adaptive') },
              { value: $r('app.string.weibo_waterfall_columns_balanced') },
              { value: $r('app.string.weibo_waterfall_columns_dense') }
            ])
              .selected(this.columnModeIndex())
              .value(this.columnModeLabel())
              .fontColor(Theme.textPrimary(this.isDark))
              .selectedOptionFontColor(Theme.brand())
              .selectedOptionBgColor(Theme.brandBg(this.isDark))
              .onSelect((index: number): void => {
                this.selectColumnMode(index);
              })
          }
          .width('100%')
          .padding(Spacing.lg)
          .backgroundColor(Theme.bgCard(this.isDark))
          .borderRadius(Radius.lg)

          this.SectionTitle('应用语言', '已适配的界面会立即按所选语言显示')
          this.LanguageOption(APP_LANGUAGE_ZH_CN, '简体中文', '使用中文界面')
          this.LanguageOption(APP_LANGUAGE_EN, 'English', 'Use English resources where available')
        }
        .width('100%')
        .padding({ left: Spacing.lg, right: Spacing.lg, top: this.contentTopInset(), bottom: 100 })
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    }
    .titleBar({
      avoidLayoutSafeArea: true,
      content: { title: { mainTitle: '软件设置' } },
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
    // Settings is intentionally a full-page route on every form factor.
    .mode(NavigationMode.Stack)
    .titleMode(HdsNavigationTitleMode.MINI)
    .hideBackButton(false)
    .bindToScrollable([this.settingsScroller])
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg(this.isDark))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
