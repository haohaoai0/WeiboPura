import { CacheManager } from '../cache/CacheManager';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'WeiboDraftManager';
const DRAFT_PREFIX: string = 'weibo_draft_';
const DRAFT_INDEX_PREFIX: string = 'weibo_draft_index_';

export type WeiboDraftType = 'publish' | 'repost' | 'comment' | 'reply';

export interface WeiboDraftItem {
  id: string;
  type: WeiboDraftType;
  accountKey: string;
  text: string;
  images: string[];
  targetPostId?: string;
  targetCommentId?: string;
  replyUserName?: string;
  dualComment?: boolean;
  updatedAt: number;
}

export class WeiboDraftManager {
  private static instance: WeiboDraftManager | null = null;
  private memoryCache: Map<string, WeiboDraftItem> = new Map<string, WeiboDraftItem>();

  static getInstance(): WeiboDraftManager {
    if (WeiboDraftManager.instance === null) {
      WeiboDraftManager.instance = new WeiboDraftManager();
    }
    return WeiboDraftManager.instance;
  }

  private cleanAccount(accountKey: string): string {
    return accountKey.trim().length > 0 ? accountKey.trim() : 'guest';
  }

  private draftKey(accountKey: string, id: string): string {
    return `${DRAFT_PREFIX}${this.cleanAccount(accountKey)}_${id}`;
  }

  private indexKey(accountKey: string): string {
    return `${DRAFT_INDEX_PREFIX}${this.cleanAccount(accountKey)}`;
  }

  async saveDraft(item: WeiboDraftItem): Promise<void> {
    const key: string = this.draftKey(item.accountKey, item.id);
    const snapshot: WeiboDraftItem = {
      id: item.id,
      type: item.type,
      accountKey: item.accountKey,
      text: item.text,
      images: item.images ? item.images.slice() : [],
      targetPostId: item.targetPostId,
      targetCommentId: item.targetCommentId,
      replyUserName: item.replyUserName,
      dualComment: item.dualComment,
      updatedAt: Date.now()
    };

    this.memoryCache.set(key, snapshot);

    try {
      const cache: CacheManager = CacheManager.getInstance();
      await cache.put(key, JSON.stringify(snapshot));

      // Update index
      const idxKey: string = this.indexKey(item.accountKey);
      const rawIdx: string | undefined = await cache.get(idxKey);
      let ids: string[] = [];
      if (rawIdx !== undefined && rawIdx.trim().length > 0) {
        try {
          ids = JSON.parse(rawIdx) as string[];
        } catch (_e) {
          ids = [];
        }
      }
      if (!ids.includes(item.id)) {
        ids.push(item.id);
        await cache.put(idxKey, JSON.stringify(ids));
      }
    } catch (e) {
      hilog.error(0x0000, TAG, 'saveDraft error: %{public}s', JSON.stringify(e));
    }
  }

  async flush(): Promise<void> {
    // Drafts are written synchronously on save; flush hook reserved for lifecycle consistency
    return Promise.resolve();
  }

  async getDraft(accountKey: string, id: string): Promise<WeiboDraftItem | null> {
    const key: string = this.draftKey(accountKey, id);
    if (this.memoryCache.has(key)) {
      return this.memoryCache.get(key)!;
    }

    try {
      const raw: string | undefined = await CacheManager.getInstance().get(key);
      if (raw === undefined || raw.trim().length === 0) {
        return null;
      }
      const item: WeiboDraftItem = JSON.parse(raw) as WeiboDraftItem;
      this.memoryCache.set(key, item);
      return item;
    } catch (e) {
      hilog.error(0x0000, TAG, 'getDraft error: %{public}s', JSON.stringify(e));
      return null;
    }
  }

  async deleteDraft(accountKey: string, id: string): Promise<void> {
    const key: string = this.draftKey(accountKey, id);
    this.memoryCache.delete(key);

    try {
      const cache: CacheManager = CacheManager.getInstance();
      await cache.delete(key);

      const idxKey: string = this.indexKey(accountKey);
      const rawIdx: string | undefined = await cache.get(idxKey);
      if (rawIdx !== undefined && rawIdx.trim().length > 0) {
        try {
          const ids: string[] = JSON.parse(rawIdx) as string[];
          const filtered: string[] = ids.filter((currId: string): boolean => currId !== id);
          await cache.put(idxKey, JSON.stringify(filtered));
        } catch (_e) {
        }
      }
    } catch (e) {
      hilog.error(0x0000, TAG, 'deleteDraft error: %{public}s', JSON.stringify(e));
    }
  }

  async getAllDrafts(accountKey: string): Promise<WeiboDraftItem[]> {
    const results: WeiboDraftItem[] = [];
    try {
      const cache: CacheManager = CacheManager.getInstance();
      const idxKey: string = this.indexKey(accountKey);
      const rawIdx: string | undefined = await cache.get(idxKey);
      if (rawIdx === undefined || rawIdx.trim().length === 0) {
        return results;
      }
      const ids: string[] = JSON.parse(rawIdx) as string[];
      for (const id of ids) {
        const item: WeiboDraftItem | null = await this.getDraft(accountKey, id);
        if (item !== null) {
          results.push(item);
        }
      }
    } catch (e) {
      hilog.error(0x0000, TAG, 'getAllDrafts error: %{public}s', JSON.stringify(e));
    }
    return results;
  }

  async clearAllDrafts(accountKey: string): Promise<void> {
    const drafts: WeiboDraftItem[] = await this.getAllDrafts(accountKey);
    for (const draft of drafts) {
      await this.deleteDraft(accountKey, draft.id);
    }
  }
}
