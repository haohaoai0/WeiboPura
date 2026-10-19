import { rcp } from '@kit.RemoteCommunicationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { WeiboAuthManager } from '../service/WeiboAuthManager';

const WEIBO_REFERER: string = 'https://m.weibo.cn/';
const WEIBO_USER_AGENT: string =
  'Mozilla/5.0 (Linux; HarmonyOS) AppleWebKit/537.36 Chrome/120 Mobile Safari/537.36';
const WEIBO_DESKTOP_REFERER: string = 'https://weibo.com/';
const WEIBO_DESKTOP_USER_AGENT: string =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/124.0.0.0 Safari/537.36';
const MIN_REQUEST_INTERVAL_MS: number = 800;
const MOBILE_PRECONNECT_COOLDOWN_MS: number = 180000;

interface WeiboWriteConfigData {
  st?: string;
  login?: boolean;
}
interface WeiboWriteConfig {
  data?: WeiboWriteConfigData;
}

/** A lightweight client for Weibo network communication. */
export class WeiboHttpClient {
  private static session: rcp.Session | null = null;
  private static lastRequestAt: number = 0;
  /** API 24+: keep the one mobile-origin handshake warm for the feed's first request. */
  private static mobilePreconnectTask: Promise<void> | null = null;
  private static lastMobilePreconnectAt: number = 0;

  private static getSession(): rcp.Session {
    if (WeiboHttpClient.session === null) {
      WeiboHttpClient.session = rcp.createSession({
        requestConfiguration: {
          transfer: {
            autoRedirect: true,
            maxAutoRedirects: 5,
            timeout: { connectMs: 15000, transferMs: 30000 },
          },
        },
      });
    }
    return WeiboHttpClient.session;
  }

  static async get(url: string, cookie: string, referer?: string): Promise<string> {
    const headers: Record<string, string> = WeiboHttpClient.buildMobileHeaders(cookie);
    if (referer !== undefined && referer.length > 0) {
      headers['Referer'] = referer;
    }
    return WeiboHttpClient.request(url, headers);
  }

  /** Desktop APIs can read public data anonymously or the account's own feed with its Cookie. */
  static async getDesktop(url: string, cookie: string = ''): Promise<string> {
    return WeiboHttpClient.request(url, WeiboHttpClient.buildDesktopHeaders(cookie));
  }

  /**
   * Starts, but never blocks on, an API 24 `connectOnly` request. The later
   * timeline request uses the same long-lived Session and `m.weibo.cn` origin,
   * so it can reuse the TCP/TLS connection when it remains available.
   */
  static preconnectMobile(): void {
    const now: number = Date.now();
    if (WeiboHttpClient.mobilePreconnectTask !== null
      || now - WeiboHttpClient.lastMobilePreconnectAt < MOBILE_PRECONNECT_COOLDOWN_MS) {
      return;
    }
    WeiboHttpClient.lastMobilePreconnectAt = now;
    WeiboHttpClient.mobilePreconnectTask = WeiboHttpClient.connectMobileOnly();
  }

  /**
   * Write requests are deliberately explicit: callers create the form only
   * after a direct user gesture, and must pass the user-provided Cookie.
   */
  static async postForm(url: string, cookie: string, form: rcp.Form | rcp.MultipartForm): Promise<string> {
    const auth: WeiboAuthManager = WeiboAuthManager.getInstance();
    const revision: number = auth.getSessionRevision();
    auth.assertSession(revision);
    if (cookie !== auth.getCookie()) { throw new Error('账号会话已变更，请重新操作'); }
    try {
      let writeToken: string = '';
      const isDesktop: boolean = url.startsWith('https://weibo.com/');
      if (!isDesktop) {
        const rawConfig: string = await WeiboHttpClient.get('https://m.weibo.cn/api/config', cookie);
        const config: WeiboWriteConfig = JSON.parse(rawConfig) as WeiboWriteConfig;
        if (config.data?.login === false || !config.data?.st) {
          throw new WeiboRequestError(401, '登录已失效，请重新登录后操作');
        }
        writeToken = config.data.st;
        form.fields['st'] = writeToken;
        const keys: string[] = form.keys ?? Object.keys(form.fields);
        if (!keys.includes('st')) { form.keys = keys.concat(['st']); }
      }
      await WeiboHttpClient.waitForRequestSlot();
      auth.assertSession(revision);
      const request: rcp.Request = new rcp.Request(url, 'POST');
      request.headers = isDesktop ? WeiboHttpClient.buildDesktopHeaders(cookie) : WeiboHttpClient.buildMobileHeaders(cookie);
      if (writeToken.length > 0) { request.headers['X-XSRF-TOKEN'] = writeToken; }
      request.content = form;
      if (form instanceof rcp.MultipartForm) {
        request.configuration = { transfer: { timeout: { connectMs: 15000, transferMs: 120000 } } };
      }
      const response: rcp.Response = await WeiboHttpClient.getSession().fetch(request);
      auth.assertSession(revision);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        const body: string = await response.toString() ?? '';
        auth.assertSession(revision);
        return body;
      }
      throw new WeiboRequestError(response.statusCode, WeiboHttpClient.messageForStatus(response.statusCode));
    } catch (error) {
      if (error instanceof WeiboRequestError) {
        throw error;
      }
      const businessError: BusinessError = error as BusinessError;
      throw new WeiboRequestError(businessError.code ?? -1, businessError.message ?? '微博写入请求失败');
    }
  }

  private static async request(url: string, headers: Record<string, string>): Promise<string> {
    const auth: WeiboAuthManager = WeiboAuthManager.getInstance();
    const revision: number = auth.getSessionRevision();
    try {
      await WeiboHttpClient.waitForRequestSlot();
      auth.assertSession(revision);
      const request: rcp.Request = new rcp.Request(url, 'GET');
      request.headers = headers;
      const response = await WeiboHttpClient.getSession().fetch(request);
      auth.assertSession(revision);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        const body: string = await response.toString() ?? '';
        auth.assertSession(revision);
        return body;
      }
      throw new WeiboRequestError(response.statusCode, WeiboHttpClient.messageForStatus(response.statusCode));
    } catch (error) {
      if (error instanceof WeiboRequestError) {
        throw error;
      }
      const businessError: BusinessError = error as BusinessError;
      const message: string = businessError.message ?? '微博网络请求失败，请检查网络连接';
      if (message.toLowerCase().includes('timeout')) {
        throw new WeiboRequestError(31002, '微博请求超时，请稍后重试');
      }
      throw new WeiboRequestError(businessError.code ?? -1, message);
    }
  }

  private static async connectMobileOnly(): Promise<void> {
    try {
      const request: rcp.Request = new rcp.Request(WEIBO_REFERER, 'GET');
      request.connectOnly = true;
      await WeiboHttpClient.getSession().fetch(request);
    } catch (error) {
      // Connection warming is best-effort. The real user-visible request keeps
      // the existing error mapping and retries on a fresh connection as usual.
    } finally {
      WeiboHttpClient.mobilePreconnectTask = null;
    }
  }

  /** Fixed pacing avoids aggressive parallel polling against an undocumented endpoint. */
  private static async waitForRequestSlot(): Promise<void> {
    const now: number = Date.now();
    const elapsed: number = now - WeiboHttpClient.lastRequestAt;
    const waitMs: number = MIN_REQUEST_INTERVAL_MS - elapsed;
    if (waitMs > 0) {
      await new Promise<void>((resolve) => {
        setTimeout(resolve, waitMs);
      });
    }
    WeiboHttpClient.lastRequestAt = Date.now();
  }

  private static buildMobileHeaders(cookie: string): Record<string, string> {
    const headers: Record<string, string> = {
      'User-Agent': WEIBO_USER_AGENT,
      'Accept': 'application/json, text/plain, */*',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      'Referer': WEIBO_REFERER,
      'MWeibo-Pwa': '1',
      'X-Requested-With': 'XMLHttpRequest',
    };
    if (cookie.length > 0) {
      headers['Cookie'] = cookie;
      const match: RegExpExecArray | null = /(?:^|;\s*)XSRF-TOKEN=([^;]+)/.exec(cookie);
      if (match !== null && match[1].length > 0) {
        headers['X-XSRF-TOKEN'] = match[1];
      }
    }
    return headers;
  }

  private static buildDesktopHeaders(cookie: string): Record<string, string> {
    const headers: Record<string, string> = {
      'User-Agent': WEIBO_DESKTOP_USER_AGENT,
      'Accept': 'application/json, text/plain, */*',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      'Referer': WEIBO_DESKTOP_REFERER,
      'X-Requested-With': 'XMLHttpRequest',
    };
    if (cookie.length > 0) {
      headers['Cookie'] = cookie;
      const match: RegExpExecArray | null = /(?:^|;\s*)XSRF-TOKEN=([^;]+)/.exec(cookie);
      if (match !== null && match[1].length > 0) {
        headers['X-XSRF-TOKEN'] = match[1];
      }
    }
    return headers;
  }

  private static messageForStatus(status: number): string {
    if (status === 401) {
      return '微博要求登录，请检查 Cookie';
    }
    if (status === 403) {
      return '微博拒绝了本次访问，请更新 Cookie 或稍后重试';
    }
    if (status === 429 || status === 432) {
      return '微博限制了访问频率，请稍后重试或更新 Cookie';
    }
    return `微博请求失败，状态码 ${status}`;
  }
}

export class WeiboRequestError extends Error {
  code: number;

  constructor(code: number, message: string) {
    super(message);
    this.code = code;
    this.name = 'WeiboRequestError';
  }
}
