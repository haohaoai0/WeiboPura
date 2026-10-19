import { common } from '@kit.AbilityKit';
import { CacheManager } from '../cache/CacheManager';
import { webview } from '@kit.ArkWeb';

const COOKIE_KEY: string = 'weibo_readonly_cookie';
const TARGET_USER_ID_KEY: string = 'weibo_target_user_id';
const CURRENT_USER_ID_KEY: string = 'weibo_current_user_id';

/** Stores the session returned after the user finishes the visible in-app Weibo login. */
export class WeiboAuthManager {
  private static instance: WeiboAuthManager | null = null;
  private initialized: boolean = false;
  private initializationTask: Promise<void> | null = null;
  private cookie: string = '';
  private targetUserId: string = '';
  private currentUserId: string = '';
  private sessionRevision: number = 0;
  private clearing: boolean = false;
  private cleanupRequired: boolean = false;
  private persistenceTask: Promise<void> = Promise.resolve();

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
    if (this.initializationTask === null) { this.initializationTask = this.loadStoredSession(context); }
    await this.initializationTask;
  }

  private async loadStoredSession(context: common.UIAbilityContext): Promise<void> {
    const revision: number = this.sessionRevision;
    const cache: CacheManager = CacheManager.getInstance();
    await cache.init(context);
    const cookie: string = (await cache.get(COOKIE_KEY)) ?? '';
    const target: string = (await cache.get(TARGET_USER_ID_KEY)) ?? '';
    const currentUid: string = (await cache.get(CURRENT_USER_ID_KEY)) ?? '';
    if (revision === this.sessionRevision && !this.isSessionChanging()) {
      this.cookie = cookie;
      this.targetUserId = target;
      this.currentUserId = currentUid;
    }
    this.initialized = true;
  }

  getCookie(): string {
    return this.cookie;
  }

  hasCookie(): boolean {
    return /(?:^|;\s*)SUB=[^;]+/.test(this.cookie);
  }

  getSessionRevision(): number { return this.sessionRevision; }

  isSessionChanging(): boolean { return this.clearing || this.cleanupRequired; }

  assertSession(revision: number): void {
    if (this.isSessionChanging() || revision !== this.sessionRevision) {
      throw new Error('账号会话已变更，请重新操作');
    }
  }

  async setCookie(value: string, expectedRevision: number = this.sessionRevision): Promise<void> {
    this.assertSession(expectedRevision);
    const clean: string = value.trim();
    if (!/(?:^|;\s*)SUB=[^;]+/.test(clean)) { throw new Error('未检测到有效微博登录 Cookie'); }
    const task: Promise<void> = this.persistenceTask.catch((): void => {}).then(async (): Promise<void> => {
      this.assertSession(expectedRevision);
      await CacheManager.getInstance().putManyStrict({
        'weibo_readonly_cookie': clean, 'weibo_target_user_id': ''
      });
      this.assertSession(expectedRevision);
      this.cookie = clean;
      this.targetUserId = '';
      this.sessionRevision++;
    });
    this.persistenceTask = task;
    await task;
  }

  getCurrentUserId(): string {
    return this.currentUserId;
  }

  async setCurrentUserId(value: string): Promise<void> {
    const clean: string = value.trim();
    if (clean === this.currentUserId) {
      return;
    }
    this.currentUserId = clean;
    try {
      await CacheManager.getInstance().put(CURRENT_USER_ID_KEY, clean);
    } catch (_e) {}
  }

  getTargetUserId(): string {
    return this.targetUserId;
  }

  async setTargetUserId(value: string): Promise<void> {
    const revision: number = this.sessionRevision;
    const clean: string = value.trim();
    const task: Promise<void> = this.persistenceTask.catch((): void => {}).then(async (): Promise<void> => {
      this.assertSession(revision);
      await CacheManager.getInstance().putManyStrict({ 'weibo_target_user_id': clean });
      this.assertSession(revision);
      this.targetUserId = clean;
    });
    this.persistenceTask = task;
    await task;
  }

  async clearCookie(): Promise<void> {
    // Revoke immediately, even if disk/Web cleanup fails. Serialize durable
    // writes so an older login capture cannot persist after this logout.
    this.cookie = '';
    this.targetUserId = '';
    this.currentUserId = '';
    this.sessionRevision++;
    const revision: number = this.sessionRevision;
    this.clearing = true;
    this.cleanupRequired = true;
    const task: Promise<void> = this.persistenceTask.catch((): void => {}).then(async (): Promise<void> => {
      const failures: string[] = [];
      try {
        await CacheManager.getInstance().putManyStrict({
          'weibo_readonly_cookie': '', 'weibo_target_user_id': '', 'weibo_current_user_id': ''
        });
      } catch (_error) { failures.push('本地登录存储清理失败'); }
      try { await webview.WebCookieManager.clearAllCookies(); }
      catch (_error) { failures.push('Web 登录 Cookie 清理失败'); }
      try { webview.WebStorage.deleteAllData(); }
      catch (_error) { failures.push('Web 登录存储清理失败'); }
      if (failures.length > 0) { throw new Error(`${failures.join('；')}，请重试退出后再登录`); }
    });
    this.persistenceTask = task;
    try {
      await task;
      if (revision === this.sessionRevision) { this.cleanupRequired = false; }
    } finally { if (revision === this.sessionRevision) { this.clearing = false; } }
  }
}
