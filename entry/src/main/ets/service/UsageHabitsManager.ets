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

import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { CacheManager } from '../cache/CacheManager';
import { CACHE_KEY } from '../common/Constants';
import { isWideBarFlatDevice } from '../common/Theme';

const TAG: string = 'UsageHabitsManager';

/**
 * 全局使用习惯开关管理器（单例）。
 * - 管理「首页推荐仅显示关注吧的帖子」开关
 * - 持久化到本地缓存
 * - 通过 AppStorage 通知所有页面刷新（键：homeOnlyFollow）
 */
export class UsageHabitsManager {
  private static instance: UsageHabitsManager | null = null;
  private inited: boolean = false;
  private context: common.UIAbilityContext | null = null;

  static getInstance(): UsageHabitsManager {
    if (UsageHabitsManager.instance === null) {
      UsageHabitsManager.instance = new UsageHabitsManager();
    }
    return UsageHabitsManager.instance;
  }

  /**
   * 初始化：从缓存恢复开关状态
   */
  async init(context: common.UIAbilityContext): Promise<void> {
    if (this.inited) {
      return;
    }
    this.inited = true;
    this.context = context;
    try {
      const cache = CacheManager.getInstance();
      await cache.init(context);
      const saved = await cache.get(CACHE_KEY.HOME_ONLY_FOLLOW);
      AppStorage.setOrCreate('homeOnlyFollow', saved === '1');
      // 深色模式设置：跟随系统（默认 true）与手动深色（默认 false）一并恢复；
      // 旧版本未写过这两个 key 时，cache.get 返回 null，按默认值落地、保持原「跟随系统」行为。
      const savedFollowSys = await cache.get(CACHE_KEY.FOLLOW_SYSTEM_DARK);
      AppStorage.setOrCreate('appFollowSystemDark', savedFollowSys !== '0');
      const savedDark = await cache.get(CACHE_KEY.DARK_MODE);
      AppStorage.setOrCreate('appDarkMode', savedDark === '1');
      // 「关闭自动旋转」（仅阔直屏直板显示/生效）：缺省 null → 不关（允许旋转），老用户升级零回归
      const savedAutoRotate = await cache.get(CACHE_KEY.AUTO_ROTATE);
      AppStorage.setOrCreate('autoRotateOff', savedAutoRotate === '1');
      // 「列数调整」档位：缺省 null → 0（默认自动适配），老用户升级逐像素零回归
      const savedColumnMode = await cache.get(CACHE_KEY.COLUMN_MODE);
      const cm: number = Number.parseInt(savedColumnMode ?? '0', 10);
      AppStorage.setOrCreate('columnMode', (cm === 1 || cm === 2) ? cm : 0);
      // 冷启动可能早于各列表页构造：bump 一次 tick，让已构造的页面重读档位（未构造页 aboutToAppear 自会读）
      AppStorage.setOrCreate('columnModeTick', (AppStorage.get<number>('columnModeTick') ?? 0) + 1);
    } catch (e) {
      // 忽略缓存错误，使用默认值（关闭 / 跟随系统 / 允许旋转 / 列数默认档）
      AppStorage.setOrCreate('homeOnlyFollow', false);
      AppStorage.setOrCreate('appFollowSystemDark', true);
      AppStorage.setOrCreate('appDarkMode', false);
      AppStorage.setOrCreate('autoRotateOff', false);
      AppStorage.setOrCreate('columnMode', 0);
    }
  }

  /**
   * 当前是否开启「仅推荐关注的吧」
   */
  isOnlyFollow(): boolean {
    return AppStorage.get<boolean>('homeOnlyFollow') ?? false;
  }

  /**
   * 设置开关状态：立即更新 AppStorage，持久化到本地，
   * 并清除首页推荐缓存，避免下次读到旧的未过滤内容。
   */
  async setOnlyFollow(enabled: boolean): Promise<void> {
    AppStorage.setOrCreate('homeOnlyFollow', enabled);
    try {
      if (this.context) {
        const cache = CacheManager.getInstance();
        await cache.init(this.context);
        await cache.put(CACHE_KEY.HOME_ONLY_FOLLOW, enabled ? '1' : '0');
        // 开关状态变化后旧缓存（可能未过滤/已过滤）不再可信，直接清除
        await cache.delete(CACHE_KEY.THREAD_LIST);
      }
    } catch (e) {
      // 忽略持久化错误
    }
  }

  /**
   * 当前手动深色模式设置（仅当 followSystemDark=false 时生效）。
   * 默认 false：旧版本用户未设置时，按 v1.x 「浅色」语义落地。
   */
  isDarkModeManual(): boolean {
    return AppStorage.get<boolean>('appDarkMode') ?? false;
  }

  /**
   * 设置手动深色模式：立即更新 AppStorage 并落盘。
   * 注意：本方法只改持久化值，**不**触发 Configuration 重切；UI 需自行调 Theme.setDarkMode 让系统档位与状态栏跟随。
   */
  async setDarkModeManual(enabled: boolean): Promise<void> {
    AppStorage.setOrCreate('appDarkMode', enabled);
    this.persistDarkMode(enabled).catch(() => {
    });
  }

  /**
   * 当前是否「跟随系统深色模式」。默认 true，保持 v1.x 「跟随系统」行为。
   */
  isFollowSystemDark(): boolean {
    return AppStorage.get<boolean>('appFollowSystemDark') ?? true;
  }

  /**
   * 设置「跟随系统深色模式」开关。开启时只翻档位，调用方需另行调 Theme.setDarkMode 把当前系统态应用一遍；
   * 关闭时只翻档位不切色，调用方需自行决定「以手动深色重新应用一遍」。
   */
  async setFollowSystemDark(enabled: boolean): Promise<void> {
    AppStorage.setOrCreate('appFollowSystemDark', enabled);
    this.persistFollowSystemDark(enabled).catch(() => {
    });
  }

  /**
   * 「列数调整」当前档位：0 = 默认（按机型自动适配横竖屏）/ 1 = 竖二横三 / 2 = 竖三横四。
   * 仅在大屏形态生效（判定见 Theme.isLargeScreenForm），手机档 / 窄窗一律不覆盖。
   */
  getColumnMode(): number {
    const v: number = AppStorage.get<number>('columnMode') ?? 0;
    return (v === 1 || v === 2) ? v : 0;
  }

  /**
   * 设置「列数调整」档位：写 AppStorage 并落盘，同时递增 columnModeTick 广播。
   * 各列表页以 @StorageLink('columnModeTick') @Watch 回写本地档位 → 重算分桶 + 强制回到列表顶部
   * （离屏缓存页 @StorageLink 同步不重绘，tick + 本地 @State 是工程既有兜底范式，同 fontTick）。
   */
  async setColumnMode(mode: number): Promise<void> {
    const v: number = (mode === 1 || mode === 2) ? mode : 0;
    AppStorage.setOrCreate('columnMode', v);
    AppStorage.setOrCreate('columnModeTick', (AppStorage.get<number>('columnModeTick') ?? 0) + 1);
    this.persistColumnMode(v).catch(() => {
    });
  }

  private async persistColumnMode(mode: number): Promise<void> {
    if (!this.context) {
      return;
    }
    try {
      const cache = CacheManager.getInstance();
      await cache.init(this.context);
      await cache.put(CACHE_KEY.COLUMN_MODE, `${mode}`);
    } catch (e) {
      // 忽略持久化错误
    }
  }

  private async persistDarkMode(enabled: boolean): Promise<void> {
    if (!this.context) {
      return;
    }
    try {
      const cache = CacheManager.getInstance();
      await cache.init(this.context);
      await cache.put(CACHE_KEY.DARK_MODE, enabled ? '1' : '0');
    } catch (e) {
      // 忽略持久化错误
    }
  }

  private async persistFollowSystemDark(enabled: boolean): Promise<void> {
    if (!this.context) {
      return;
    }
    try {
      const cache = CacheManager.getInstance();
      await cache.init(this.context);
      await cache.put(CACHE_KEY.FOLLOW_SYSTEM_DARK, enabled ? '1' : '0');
    } catch (e) {
      // 忽略持久化错误
    }
  }

  /**
   * 当前是否已「关闭自动旋转」。默认 false（允许旋转），保持既有行为零回归。
   */
  isAutoRotateOff(): boolean {
    return AppStorage.get<boolean>('autoRotateOff') ?? false;
  }

  /**
   * 设置「关闭自动旋转」：立即更新 AppStorage、落盘，并**即时下发窗口方向**。
   * 即时下发不可省：宿主只在冷启动 onWindowStageCreate 下发过一次方向，不补发就得杀进程重进才生效。
   */
  async setAutoRotateOff(enabled: boolean): Promise<void> {
    AppStorage.setOrCreate('autoRotateOff', enabled);
    this.persistAutoRotate(enabled).catch(() => {
    });
    applyAutoRotateOff(enabled);
  }

  private async persistAutoRotate(enabled: boolean): Promise<void> {
    if (!this.context) {
      return;
    }
    try {
      const cache = CacheManager.getInstance();
      await cache.init(this.context);
      await cache.put(CACHE_KEY.AUTO_ROTATE, enabled ? '1' : '0');
    } catch (e) {
      // 忽略持久化错误
    }
  }
}

/**
 * 按「关闭自动旋转」开关下发窗口方向（模块级：不依赖 manager 实例，宿主与页面可共用）。
 * - 守卫：仅阔直屏直板（isWideBarFlatDevice()）真下发。该开关只对阔直屏显示；其余形态
 *   （Pura X、Pura X Max 展开、大折叠展开、平板、普通手机）若被误调一律直接 return，
 *   绝不把不该锁的设备锁成竖屏。
 * - 关闭 = PORTRAIT（显式锁竖屏，而非「不干预」）：阔直屏走 module.json5 默认 unspecified
 *   跟随系统开关，用户系统开关若为开，不干预等于开关无效。
 * - 未关闭 = AUTO_ROTATION_RESTRICTED（允许旋转，但遵从系统旋转锁定）。
 * - mainWindow 未就绪时静默跳过：冷启动首帧方向由 EntryAbility 同步读 prefs 兜住。
 */
export function applyAutoRotateOff(off: boolean): void {
  try {
    if (!isWideBarFlatDevice()) {
      return;
    }
    const mainWindow: window.Window | undefined = AppStorage.get<window.Window>('mainWindow');
    if (!mainWindow) {
      return;
    }
    mainWindow.setPreferredOrientation(off
      ? window.Orientation.PORTRAIT
      : window.Orientation.AUTO_ROTATION_RESTRICTED)
      .catch((err: Error) => {
        hilog.error(0x0000, TAG, 'setPreferredOrientation(autoRotateOff=%{public}s) failed: %{public}s',
          off ? '1' : '0', JSON.stringify(err));
      });
  } catch (e) {
    hilog.error(0x0000, TAG, 'applyAutoRotateOff failed: %{public}s', JSON.stringify(e));
  }
}
