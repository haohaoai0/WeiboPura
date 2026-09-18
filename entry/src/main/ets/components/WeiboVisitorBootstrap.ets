import { webview } from '@kit.ArkWeb';
import { WeiboVisitorSession } from '../service/WeiboVisitorSession';

const VISITOR_URL: string = 'https://m.weibo.cn/';
const VISITOR_RETRY_COUNT: number = 15;
const VISITOR_RETRY_DELAY_MS: number = 1000;

/**
 * Mirrors the anonymous-session bootstrap used by established read-only
 * clients. The page is an isolated, incognito Web runtime; its cookie is kept
 * only in WeiboVisitorSession and is not an account login flow.
 */
@Component
export struct WeiboVisitorBootstrap {
  private controller: webview.WebviewController = new webview.WebviewController();
  private checkingCookie: boolean = false;
  private attempts: number = 0;
  private retryTimer: number = -1;

  aboutToAppear(): void {
    try {
      webview.WebCookieManager.setLazyInitializeWebEngine(true);
    } catch (error) {
      // The engine may already be initialized by another in-app Web page.
    }
  }

  aboutToDisappear(): void {
    if (this.retryTimer >= 0) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
  }

  private async readVisitorCookie(): Promise<void> {
    if (this.checkingCookie || WeiboVisitorSession.getInstance().isReady()) {
      return;
    }
    this.checkingCookie = true;
    try {
      const cookie: string = await webview.WebCookieManager.fetchCookie(VISITOR_URL, true);
      WeiboVisitorSession.getInstance().update(cookie);
    } catch (error) {
      // Page load and cookie issuance can race; the bounded retry below handles it.
    } finally {
      this.checkingCookie = false;
    }
    if (!WeiboVisitorSession.getInstance().isReady() && this.attempts < VISITOR_RETRY_COUNT) {
      this.attempts++;
      this.retryTimer = setTimeout(() => {
        this.readVisitorCookie();
      }, VISITOR_RETRY_DELAY_MS);
    }
  }

  build() {
    Web({ src: VISITOR_URL, controller: this.controller, incognitoMode: true })
      .width(1)
      .height(1)
      .opacity(0.01)
      .javaScriptAccess(true)
      .domStorageAccess(true)
      .onControllerAttached(() => {
        const mobileUserAgent: string =
          'Mozilla/5.0 (Linux; HarmonyOS) AppleWebKit/537.36 Chrome/120 Mobile Safari/537.36';
        this.controller.setCustomUserAgent(`${mobileUserAgent} WeiboPura/1.0`);
      })
      .onPageEnd((event) => {
        this.readVisitorCookie();
      })
      .onPageVisible((event) => {
        this.readVisitorCookie();
      })
  }
}
