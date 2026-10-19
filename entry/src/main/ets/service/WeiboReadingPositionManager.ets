import { CacheManager } from '../cache/CacheManager';
import { WeiboPost } from '../model/WeiboModel';
import { WeiboAuthManager } from './WeiboAuthManager';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'WeiboReadingPosition';
const POSITION_KEY_PREFIX: string = 'weibo_timeline_pos_';
const MAX_PERSISTED_POSTS: number = 60;
const MAX_POSITION_AGE_MS: number = 48 * 3600 * 1000; // 48 hours

export interface WeiboTimelinePosition {
  mode: number;
  accountKey: string;
  topPostId: string;
  topIndex: number;
  yOffset: number;
  updatedAt: number;
  posts: WeiboPost[];
  currentPage: number;
  hasMore: boolean;
  followingMaxId?: string;
}

export class WeiboReadingPositionManager {
  private static instance: WeiboReadingPositionManager | null = null;
  private pendingSaves: Map<string, WeiboTimelinePosition> = new Map<string, WeiboTimelinePosition>();
  private debounceTimers: Map<string, number> = new Map<string, number>();

  static getInstance(): WeiboReadingPositionManager {
    if (WeiboReadingPositionManager.instance === null) {
      WeiboReadingPositionManager.instance = new WeiboReadingPositionManager();
    }
    return WeiboReadingPositionManager.instance;
  }

  private buildKey(accountKey: string, mode: number): string {
    const cleanAccount: string = accountKey.trim().length > 0 ? accountKey.trim() : 'guest';
    return `${POSITION_KEY_PREFIX}${cleanAccount}_${mode}`;
  }

  /**
   * Schedule a position save with 400ms debounce.
   */
  savePosition(pos: WeiboTimelinePosition, immediate: boolean = false): void {
    const key: string = this.buildKey(pos.accountKey, pos.mode);
    let boundedPosts: WeiboPost[] = pos.posts;
    let targetIndex: number = pos.topIndex;

    if (pos.posts.length > MAX_PERSISTED_POSTS) {
      if (pos.topIndex < MAX_PERSISTED_POSTS) {
        boundedPosts = pos.posts.slice(0, MAX_PERSISTED_POSTS);
      } else {
        const start: number = Math.max(0, pos.topIndex - 10);
        boundedPosts = pos.posts.slice(start, start + MAX_PERSISTED_POSTS);
        targetIndex = Math.max(0, pos.topIndex - start);
      }
    }

    const snapshot: WeiboTimelinePosition = {
      mode: pos.mode,
      accountKey: pos.accountKey,
      topPostId: pos.topPostId,
      topIndex: Math.min(targetIndex, Math.max(0, boundedPosts.length - 1)),
      yOffset: pos.yOffset,
      updatedAt: Date.now(),
      posts: boundedPosts,
      currentPage: pos.currentPage,
      hasMore: pos.hasMore,
      followingMaxId: pos.followingMaxId
    };

    this.pendingSaves.set(key, snapshot);
    if (pos.accountKey !== 'guest' && pos.accountKey !== 'logged_in') {
      const fallbackKey: string = this.buildKey('logged_in', pos.mode);
      this.pendingSaves.set(fallbackKey, snapshot);
    }

    if (immediate) {
      this.flushKey(key);
      if (pos.accountKey !== 'guest' && pos.accountKey !== 'logged_in') {
        this.flushKey(this.buildKey('logged_in', pos.mode));
      }
      return;
    }

    const existingTimer: number | undefined = this.debounceTimers.get(key);
    if (existingTimer !== undefined && typeof clearTimeout !== 'undefined') {
      clearTimeout(existingTimer);
    }

    if (typeof setTimeout !== 'undefined') {
      const timerId: number = setTimeout((): void => {
        this.flushKey(key);
        if (pos.accountKey !== 'guest' && pos.accountKey !== 'logged_in') {
          this.flushKey(this.buildKey('logged_in', pos.mode));
        }
      }, 300);
      this.debounceTimers.set(key, timerId);
    } else {
      this.flushKey(key);
      if (pos.accountKey !== 'guest' && pos.accountKey !== 'logged_in') {
        this.flushKey(this.buildKey('logged_in', pos.mode));
      }
    }
  }

  /**
   * Flush all pending saves immediately to disk.
   */
  async flush(): Promise<void> {
    const keys: string[] = Array.from(this.pendingSaves.keys());
    for (const key of keys) {
      await this.flushKey(key);
    }
  }

  private async flushKey(key: string): Promise<void> {
    const timer: number | undefined = this.debounceTimers.get(key);
    if (timer !== undefined && typeof clearTimeout !== 'undefined') {
      clearTimeout(timer);
      this.debounceTimers.delete(key);
    }

    const data: WeiboTimelinePosition | undefined = this.pendingSaves.get(key);
    if (data === undefined) {
      return;
    }
    this.pendingSaves.delete(key);

    try {
      const serialized: string = JSON.stringify(data);
      await CacheManager.getInstance().put(key, serialized);
    } catch (e) {
      hilog.error(0x0000, TAG, 'flushKey error: %{public}s', JSON.stringify(e));
    }
  }

  /**
   * Retrieve saved reading position if valid and unexpired.
   */
  async getPosition(accountKey: string, mode: number): Promise<WeiboTimelinePosition | null> {
    const key: string = this.buildKey(accountKey, mode);
    let result: WeiboTimelinePosition | null = await this.readPositionFromKey(key);
    if (result !== null) {
      return result;
    }

    // Fallback checks for logged-in accounts
    if (accountKey !== 'guest' && accountKey !== 'logged_in') {
      const fallbackKey: string = this.buildKey('logged_in', mode);
      result = await this.readPositionFromKey(fallbackKey);
      if (result !== null) {
        return result;
      }
    } else if (accountKey === 'logged_in') {
      const knownUid: string = WeiboAuthManager.getInstance().getCurrentUserId();
      if (knownUid.length > 0) {
        const uidKey: string = this.buildKey(knownUid, mode);
        result = await this.readPositionFromKey(uidKey);
        if (result !== null) {
          return result;
        }
      }
    }

    return null;
  }

  private async readPositionFromKey(key: string): Promise<WeiboTimelinePosition | null> {
    if (this.pendingSaves.has(key)) {
      return this.pendingSaves.get(key)!;
    }

    try {
      const raw: string | undefined = await CacheManager.getInstance().get(key);
      if (raw === undefined || raw.trim().length === 0) {
        return null;
      }
      const parsed: WeiboTimelinePosition = JSON.parse(raw) as WeiboTimelinePosition;
      if (!parsed || !Array.isArray(parsed.posts) || parsed.posts.length === 0) {
        return null;
      }
      if (Date.now() - parsed.updatedAt > MAX_POSITION_AGE_MS) {
        return null;
      }
      return parsed;
    } catch (e) {
      hilog.error(0x0000, TAG, 'readPositionFromKey error: %{public}s', JSON.stringify(e));
      return null;
    }
  }

  /**
   * Clear saved reading position for specific account and mode.
   */
  async clearPosition(accountKey: string, mode: number): Promise<void> {
    const key: string = this.buildKey(accountKey, mode);
    this.pendingSaves.delete(key);
    const timer: number | undefined = this.debounceTimers.get(key);
    if (timer !== undefined && typeof clearTimeout !== 'undefined') {
      clearTimeout(timer);
      this.debounceTimers.delete(key);
    }
    try {
      await CacheManager.getInstance().delete(key);
    } catch (e) {
      hilog.error(0x0000, TAG, 'clearPosition error: %{public}s', JSON.stringify(e));
    }
  }
}
