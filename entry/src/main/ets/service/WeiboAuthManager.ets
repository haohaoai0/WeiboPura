import { common } from '@kit.AbilityKit';
import { CacheManager } from '../cache/CacheManager';

const COOKIE_KEY: string = 'weibo_readonly_cookie';
const TARGET_USER_ID_KEY: string = 'weibo_target_user_id';

/** Stores the session returned after the user finishes the visible in-app Weibo login. */
export class WeiboAuthManager {
  private static instance: WeiboAuthManager | null = null;
  private initialized: boolean = false;
  private cookie: string = '';
  private targetUserId: string = '';

  static getInstance(): WeiboAuthManager {
    if (WeiboAuthManager.instance === null) {
      WeiboAuthManager.instance = new WeiboAuthManager();
    }
    return WeiboAuthManager.instance;
  }

  async init(context: common.UIAbilityContext): Promise<void> {
    if (this.initialized) {
      return;
    }
    const cache: CacheManager = CacheManager.getInstance();
    await cache.init(context);
    this.cookie = (await cache.get(COOKIE_KEY)) ?? '';
    this.targetUserId = (await cache.get(TARGET_USER_ID_KEY)) ?? '';
    this.initialized = true;
  }

  getCookie(): string {
    return this.cookie;
  }

  hasCookie(): boolean {
    return this.cookie.includes('SUB=');
  }

  async setCookie(value: string): Promise<void> {
    this.cookie = value.trim();
    await CacheManager.getInstance().put(COOKIE_KEY, this.cookie);
  }

  getTargetUserId(): string {
    return this.targetUserId;
  }

  async setTargetUserId(value: string): Promise<void> {
    this.targetUserId = value.trim();
    await CacheManager.getInstance().put(TARGET_USER_ID_KEY, this.targetUserId);
  }
}
