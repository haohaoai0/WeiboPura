import { CacheManager } from '../cache/CacheManager';
import { WeiboPost } from '../model/WeiboModel';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'WeiboHistoryManager';
const HISTORY_PREFIX: string = 'weibo_history_';
const HISTORY_ENABLED_PREFIX: string = 'weibo_history_enabled_';
const MAX_HISTORY_ITEMS: number = 500;

export interface WeiboHistoryItem {
  id: string;
  userId: string;
  userName: string;
  userAvatar: string;
  text: string;
  pictures: string[];
  readAt: number;
}

export class WeiboHistoryManager {
  private static instance: WeiboHistoryManager | null = null;
  private memoryCache: Map<string, WeiboHistoryItem[]> = new Map<string, WeiboHistoryItem[]>();

  static getInstance(): WeiboHistoryManager {
    if (WeiboHistoryManager.instance === null) {
      WeiboHistoryManager.instance = new WeiboHistoryManager();
    }
    return WeiboHistoryManager.instance;
  }

  private cleanAccount(accountKey: string): string {
    return accountKey.trim().length > 0 ? accountKey.trim() : 'guest';
  }

  private historyKey(accountKey: string): string {
    return `${HISTORY_PREFIX}${this.cleanAccount(accountKey)}`;
  }

  private enabledKey(accountKey: string): string {
    return `${HISTORY_ENABLED_PREFIX}${this.cleanAccount(accountKey)}`;
  }

  async isHistoryEnabled(accountKey: string): Promise<boolean> {
    const raw: string | undefined = await CacheManager.getInstance().get(this.enabledKey(accountKey));
    if (raw === undefined || raw === '') {
      return true; // Default enabled
    }
    return raw === 'true' || raw === '1';
  }

  async setHistoryEnabled(accountKey: string, enabled: boolean): Promise<void> {
    await CacheManager.getInstance().put(this.enabledKey(accountKey), enabled ? 'true' : 'false');
  }

  async recordHistory(post: WeiboPost, accountKey: string): Promise<void> {
    if (!post || !post.id || post.id.trim().length === 0) {
      return;
    }

    const enabled: boolean = await this.isHistoryEnabled(accountKey);
    if (!enabled) {
      return;
    }

    const key: string = this.historyKey(accountKey);
    let items: WeiboHistoryItem[] = await this.getHistory(accountKey);

    // Filter out existing item for deduplication
    items = items.filter((item: WeiboHistoryItem): boolean => item.id !== post.id);

    const newItem: WeiboHistoryItem = {
      id: post.id,
      userId: post.userId ?? '',
      userName: post.userName ?? '微博用户',
      userAvatar: post.userAvatar ?? '',
      text: (post.text ?? '').substring(0, 280),
      pictures: post.pictures ? post.pictures.slice(0, 3) : [],
      readAt: Date.now()
    };

    items.unshift(newItem);

    // Limit to 500 items max
    if (items.length > MAX_HISTORY_ITEMS) {
      items = items.slice(0, MAX_HISTORY_ITEMS);
    }

    this.memoryCache.set(key, items);

    try {
      await CacheManager.getInstance().put(key, JSON.stringify(items));
    } catch (e) {
      hilog.error(0x0000, TAG, 'recordHistory error: %{public}s', JSON.stringify(e));
    }
  }

  async getHistory(accountKey: string): Promise<WeiboHistoryItem[]> {
    const key: string = this.historyKey(accountKey);
    if (this.memoryCache.has(key)) {
      return this.memoryCache.get(key)!.slice();
    }

    try {
      const raw: string | undefined = await CacheManager.getInstance().get(key);
      if (raw === undefined || raw.trim().length === 0) {
        return [];
      }
      const items: WeiboHistoryItem[] = JSON.parse(raw) as WeiboHistoryItem[];
      if (Array.isArray(items)) {
        this.memoryCache.set(key, items);
        return items.slice();
      }
      return [];
    } catch (e) {
      hilog.error(0x0000, TAG, 'getHistory error: %{public}s', JSON.stringify(e));
      return [];
    }
  }

  async deleteHistoryItem(accountKey: string, postId: string): Promise<void> {
    const key: string = this.historyKey(accountKey);
    let items: WeiboHistoryItem[] = await this.getHistory(accountKey);
    items = items.filter((item: WeiboHistoryItem): boolean => item.id !== postId);
    this.memoryCache.set(key, items);

    try {
      await CacheManager.getInstance().put(key, JSON.stringify(items));
    } catch (e) {
      hilog.error(0x0000, TAG, 'deleteHistoryItem error: %{public}s', JSON.stringify(e));
    }
  }

  async clearHistory(accountKey: string): Promise<void> {
    const key: string = this.historyKey(accountKey);
    this.memoryCache.delete(key);
    try {
      await CacheManager.getInstance().delete(key);
    } catch (e) {
      hilog.error(0x0000, TAG, 'clearHistory error: %{public}s', JSON.stringify(e));
    }
  }
}
