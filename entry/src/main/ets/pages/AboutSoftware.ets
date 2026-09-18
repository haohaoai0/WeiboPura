import { HdsNavigation, HdsNavigationTitleMode, ScrollEffectType, hdsMaterial } from '@kit.UIDesignKit';
import { ImmMaterial, Radius, Spacing, Theme, fs, isDarkMode } from '../common/Theme';

@Component
struct DonationQrCard {
  @Prop title: Resource = $r('app.string.weibo_software_about_wechat');
  @Prop image: Resource = $r('app.media.support_wechat');
  @Prop imageHeight: number = 360;
  @Prop isDark: boolean = false;
  @Prop fontScale: number = 1.0;

  build() {
    Column({ space: Spacing.sm }) {
      Text(this.title)
        .width('100%')
        .fontSize(fs(16, this.fontScale))
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.textPrimary(this.isDark))
      Image(this.image)
        .width('100%')
        .height(this.imageHeight)
        .objectFit(ImageFit.Contain)
        .borderRadius(Radius.md)
        .clip(true)
    }
    .width('100%')
    .padding(Spacing.lg)
    .backgroundColor(Theme.bgCard(this.isDark))
    .borderRadius(Radius.lg)
  }
}

@Entry
@Component
export struct AboutSoftware {
  @State isDark: boolean = isDarkMode();
  @StorageLink('fontScale') fontScale: number = 1.0;
  @StorageLink('darkTick') @Watch('onDarkTick') darkTick: number = 0;
  @StorageLink('weibo.top_rect_height') topRectHeight: number = 0;
  private aboutScroller: Scroller = new Scroller();

  private onDarkTick(): void {
    this.isDark = isDarkMode();
  }

  private contentTopInset(): number {
    return this.getUIContext().px2vp(this.topRectHeight) + 56;
  }

  @Builder
  private InfoCard(icon: Resource, title: Resource, description: Resource): void {
    Row({ space: Spacing.md }) {
      SymbolGlyph(icon)
        .fontSize(fs(23, this.fontScale))
        .fontColor([Theme.brand()])
        .width(28)
      Column({ space: 4 }) {
        Text(title)
          .fontSize(fs(16, this.fontScale))
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textPrimary(this.isDark))
        Text(description)
          .fontSize(fs(13, this.fontScale))
          .lineHeight(fs(19, this.fontScale))
          .fontColor(Theme.textSecondary(this.isDark))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding(Spacing.lg)
    .backgroundColor(Theme.bgCard(this.isDark))
    .borderRadius(Radius.lg)
  }

  build() {
    HdsNavigation() {
      Scroll(this.aboutScroller) {
        Column({ space: Spacing.md }) {
          Column({ space: Spacing.sm }) {
            SymbolGlyph($r('sys.symbol.info_circle_fill'))
              .fontSize(fs(36, this.fontScale))
              .fontColor([Theme.brand()])
            Text($r('app.string.weibo_software_about_title'))
              .fontSize(fs(24, this.fontScale))
              .fontWeight(FontWeight.Bold)
              .fontColor(Theme.textPrimary(this.isDark))
            Text($r('app.string.weibo_software_about_description'))
              .fontSize(fs(14, this.fontScale))
              .lineHeight(fs(21, this.fontScale))
              .fontColor(Theme.textSecondary(this.isDark))
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding(Spacing.lg)
          .backgroundColor(Theme.bgCard(this.isDark))
          .borderRadius(Radius.lg)

          this.InfoCard(
            $r('sys.symbol.lock_fill'),
            $r('app.string.weibo_software_about_privacy_title'),
            $r('app.string.weibo_software_about_privacy_description')
          )
          this.InfoCard(
            $r('sys.symbol.hand_thumbsup_fill'),
            $r('app.string.weibo_software_about_interaction_title'),
            $r('app.string.weibo_software_about_interaction_description')
          )

          Column({ space: Spacing.sm }) {
            Row({ space: Spacing.sm }) {
              SymbolGlyph($r('sys.symbol.heart_fill'))
                .fontSize(fs(23, this.fontScale))
                .fontColor([Theme.danger()])
              Text($r('app.string.weibo_software_about_support_title'))
                .fontSize(fs(19, this.fontScale))
                .fontWeight(FontWeight.Bold)
                .fontColor(Theme.textPrimary(this.isDark))
            }
            Text($r('app.string.weibo_software_about_support_description'))
              .width('100%')
              .fontSize(fs(14, this.fontScale))
              .lineHeight(fs(21, this.fontScale))
              .fontColor(Theme.textSecondary(this.isDark))
            Text($r('app.string.weibo_software_about_support_scan'))
              .width('100%')
              .fontSize(fs(13, this.fontScale))
              .fontColor(Theme.textSecondary(this.isDark))
          }
          .width('100%')
          .padding(Spacing.lg)
          .backgroundColor(Theme.bgCard(this.isDark))
          .borderRadius(Radius.lg)

          DonationQrCard({
            title: $r('app.string.weibo_software_about_wechat'),
            image: $r('app.media.support_wechat'),
            imageHeight: 360,
            isDark: this.isDark,
            fontScale: this.fontScale
          })
          DonationQrCard({
            title: $r('app.string.weibo_software_about_alipay'),
            image: $r('app.media.support_alipay'),
            imageHeight: 440,
            isDark: this.isDark,
            fontScale: this.fontScale
          })
        }
        .width('100%')
        .padding({ left: Spacing.lg, right: Spacing.lg, top: this.contentTopInset(), bottom: 100 })
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    }
    .titleBar({
      avoidLayoutSafeArea: true,
      content: { title: { mainTitle: $r('app.string.weibo_software_about_title') } },
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
    .mode(NavigationMode.Stack)
    .titleMode(HdsNavigationTitleMode.MINI)
    .hideBackButton(false)
    .bindToScrollable([this.aboutScroller])
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg(this.isDark))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
