/*
 * TiebaPura - HarmonyOS 原生 ArkTS 实现的第三方百度贴吧客户端
 * Copyright (C) 2026 a307608689-afk
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'CacheManager';
export const STORE_NAME: string = 'tieba_cache';

interface TtlWrapper<T> {
  data: T;
  expireAt: number;
}

/** getWithTtlAllowStale 的返回：data 为缓存数据，expired 标记是否已过期 */
interface StaleCacheEntry<T> {
  data: T;
  expired: boolean;
}

/** pruneByPrefix 内部的待清理条目 */
interface PruneEntry {
  key: string;
  expireAt: number;
}

/**
 * 基于 Preferences 的轻量缓存层，带 TTL 过期。
 */
export class CacheManager {
  private static instance: CacheManager | null = null;
  private store: preferences.Preferences | null = null;

  static getInstance(): CacheManager {
    if (CacheManager.instance === null) {
      CacheManager.instance = new CacheManager();
    }
    return CacheManager.instance;
  }

  /**
   * 初始化，需传入 UIAbilityContext
   */
  async init(context: common.UIAbilityContext): Promise<void> {
    if (this.store !== null) {
      return;
    }
    try {
      this.store = await preferences.getPreferences(context, STORE_NAME);
    } catch (e) {
      hilog.error(0x0000, TAG, 'init error: %{public}s', JSON.stringify(e));
    }
  }

  /**
   * 写入字符串
   */
  async appendJsonItem<T>(key: string, value: T, maxItems: number = 50): Promise<void> {
    const raw = await this.get(key);
    let items: T[] = [];
    if (raw !== undefined) {
      try {
        items = JSON.parse(raw) as T[];
      } catch (e) {
        items = [];
      }
    }
    const next: T[] = [value, ...items].slice(0, maxItems);
    await this.put(key, JSON.stringify(next));
  }

  async put(key: string, value: string): Promise<void> {
    if (this.store === null) {
      return;
    }
    try {
      await this.store.put(key, value);
      await this.store.flush();
    } catch (e) {
      hilog.error(0x0000, TAG, 'put error: %{public}s', JSON.stringify(e));
    }
  }

  /** Authentication must not report success when durable storage failed. */
  async putManyStrict(values: Record<string, string>): Promise<void> {
    if (this.store === null) { throw new Error('登录存储未初始化，请重试'); }
    for (const key of Object.keys(values)) {
      await this.store.put(key, values[key]);
    }
    await this.store.flush();
  }

  /**
   * 读取字符串
   */
  async get(key: string): Promise<string | undefined> {
    if (this.store === null) {
      return undefined;
    }
    try {
      const v = await this.store.get(key, '');
      return v === '' ? undefined : (v as string);
    } catch (e) {
      hilog.error(0x0000, TAG, 'get error: %{public}s', JSON.stringify(e));
      return undefined;
    }
  }

  /**
   * 按 key 前缀读取全部字符串条目（如签到状态这类「前缀 + 账号/吧名」隔离的批量读取，
   * 一次 getAll 避免逐 key 读盘）。返回 key → value 的映射。
   */
  async getAllByPrefix(prefix: string): Promise<Map<string, string>> {
    const result: Map<string, string> = new Map<string, string>();
    if (this.store === null) {
      return result;
    }
    try {
      const all = await this.store.getAll() as Map<string, preferences.ValueType>;
      all.forEach((value: preferences.ValueType, key: string) => {
        if (key.startsWith(prefix) && typeof value === 'string') {
          result.set(key, value as string);
        }
      });
    } catch (e) {
      hilog.error(0x0000, TAG, 'getAllByPrefix error: %{public}s', JSON.stringify(e));
    }
    return result;
  }

  /**
   * 带 TTL 的对象缓存
   */
  async putWithTtl<T>(key: string, value: T, ttlMs: number): Promise<void> {
    const wrapper: TtlWrapper<T> = {
      data: value,
      expireAt: Date.now() + ttlMs,
    };
    await this.put(key, JSON.stringify(wrapper));
  }

  /**
   * 按 key 前缀清理缓存条目：超上限时按 expireAt 删除最旧（含过期清理），
   * 防止详情等高频写入的磁盘缓存无限膨胀。失败不抛错。
   */
  async pruneByPrefix(prefix: string, maxCount: number): Promise<void> {
    if (this.store === null || maxCount <= 0) {
      return;
    }
    try {
      const all = await this.store.getAll() as Map<string, preferences.ValueType>;
      const entries: PruneEntry[] = [];
      all.forEach((value: preferences.ValueType, key: string) => {
        if (key.startsWith(prefix) && typeof value === 'string' && value.length > 0) {
          try {
            const wrapper = JSON.parse(value) as TtlWrapper<object>;
            const entry: PruneEntry = { key: key, expireAt: wrapper.expireAt };
            entries.push(entry);
          } catch (_) {
          }
        }
      });
      if (entries.length <= maxCount) {
        // 未超上限：只清理已过期的条目
        const now = Date.now();
        const expired = entries.filter((e) => e.expireAt < now);
        for (const e of expired) {
          this.store.delete(e.key);
        }
        if (expired.length > 0) {
          await this.store.flush();
        }
        return;
      }
      entries.sort((a, b) => a.expireAt - b.expireAt);
      const toRemove = entries.slice(0, entries.length - maxCount);
      for (const e of toRemove) {
        this.store.delete(e.key);
      }
      await this.store.flush();
    } catch (e) {
      hilog.error(0x0000, TAG, 'pruneByPrefix error: %{public}s', JSON.stringify(e));
    }
  }

  /**
   * 读取带 TTL 的对象缓存，过期返回 undefined
   */
  async getWithTtl<T>(key: string): Promise<T | undefined> {
    const raw = await this.get(key);
    if (raw === undefined) {
      return undefined;
    }
    try {
      const wrapper = JSON.parse(raw) as TtlWrapper<T>;
      if (wrapper.expireAt < Date.now()) {
        return undefined;
      }
      return wrapper.data;
    } catch (e) {
      return undefined;
    }
  }

  /**
   * 读取带 TTL 的对象缓存：过期数据也返回（stale-while-revalidate），
   * expired 标记是否已过期，调用方据此决定是否后台刷新，保证冷启动秒开。
   */
  async getWithTtlAllowStale<T>(key: string): Promise<StaleCacheEntry<T> | undefined> {
    const raw = await this.get(key);
    if (raw === undefined) {
      return undefined;
    }
    try {
      const wrapper = JSON.parse(raw) as TtlWrapper<T>;
      const entry: StaleCacheEntry<T> = { data: wrapper.data, expired: wrapper.expireAt < Date.now() };
      return entry;
    } catch (e) {
      return undefined;
    }
  }

  /**
   * 删除键
   */
  async delete(key: string): Promise<void> {
    if (this.store === null) {
      return;
    }
    try {
      await this.store.delete(key);
      await this.store.flush();
    } catch (e) {
      hilog.error(0x0000, TAG, 'delete error: %{public}s', JSON.stringify(e));
    }
  }
}
