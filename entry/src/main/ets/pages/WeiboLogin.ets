import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import { ImmBlur, ImmMaterial, Radius, Spacing, Theme, fs, isDarkMode } from '../common/Theme';
import { WeiboAuthManager } from '../service/WeiboAuthManager';

const LOGIN_URL: string = 'https://passport.weibo.com/';
// Feed requests target m.weibo.cn. Reading cookies for that exact URL keeps
// host-only mobile cookies in addition to the shared .weibo.com login cookie.
const COOKIE_URL: string = 'https://m.weibo.cn/';

/** Visible first-party Web login. The app only reads the resulting session cookie after a successful login. */
@Entry
@Component
struct WeiboLogin {
  private controller: webview.WebviewController = new webview.WebviewController();
  @State isDark: boolean = isDarkMode();
  @State checking: boolean = false;
  @State statusText: string = '请在下方页面登录微博';
  @StorageLink('fontScale') fontScale: number = 1.0;

  async aboutToAppear(): Promise<void> {
    try {
      webview.WebCookieManager.setLazyInitializeWebEngine(true);
    } catch (error) {
    }
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    await WeiboAuthManager.getInstance().init(context);
  }

  private async captureLoginCookie(): Promise<void> {
    if (this.checking) {
      return;
    }
    this.checking = true;
    try {
      const cookie: string = await webview.WebCookieManager.fetchCookie(COOKIE_URL, false);
      if (!cookie.includes('SUB=')) {
        this.statusText = '尚未检测到登录态，请完成登录后重试';
        return;
      }
      await WeiboAuthManager.getInstance().setCookie(cookie);
      AppStorage.setOrCreate<number>('weiboAuthTick', (AppStorage.get<number>('weiboAuthTick') ?? 0) + 1);
      this.statusText = '登录态已保存';
      this.getUIContext().getPromptAction().showToast({ message: '微博登录成功' });
      this.getUIContext().getRouter().back();
    } catch (error) {
      this.statusText = '读取登录态失败，请稍后重试';
    } finally {
      this.checking = false;
    }
  }

  build() {
    Column({ space: Spacing.sm }) {
      Row({ space: Spacing.sm }) {
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
        .onClick(() => { this.getUIContext().getRouter().back(); })
        Column({ space: 2 }) {
          Text($r('app.string.weibo_login_title'))
            .fontSize(fs(18, this.fontScale))
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.textPrimary(this.isDark))
          Text(this.statusText)
            .fontSize(fs(12, this.fontScale))
            .fontColor(Theme.textSecondary(this.isDark))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Button($r('app.string.weibo_login_done'))
          .height(36)
          .fontSize(fs(13, this.fontScale))
          .backgroundColor(Theme.manualGlass(this.isDark, true))
          .fontColor(Color.White)
          .border({ width: 0.5, color: Theme.manualGlassBorder() })
          .shadow(Theme.glassShadowStyle())
          .backgroundEffect(ImmBlur.accent())
          .systemMaterial(ImmMaterial.accent(this.isDark))
          .borderRadius(Radius.full)
          .onClick(() => { this.captureLoginCookie(); })
      }
      .width('100%')
      .padding({ left: Spacing.lg, right: Spacing.lg, top: 44 })
      Web({ src: LOGIN_URL, controller: this.controller, incognitoMode: false })
        .layoutWeight(1)
        .width('100%')
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .onControllerAttached(() => {
          this.controller.setCustomUserAgent('Mozilla/5.0 (Linux; HarmonyOS) AppleWebKit/537.36 Chrome/120 Mobile Safari/537.36 WeiboPura/1.0');
        })
        .onPageEnd(() => { this.captureLoginCookie(); })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg(this.isDark))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
