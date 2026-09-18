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

import { AbilityConstant, UIAbility, Want, common, ConfigurationConstant, Configuration } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Theme, setDarkMode as applyThemeDarkMode, initDarkMode, syncDarkFromConfig, isWideBarDevice, isLargeFoldDevice, isWideBarFlatDevice } from '../common/Theme';
import { UsageHabitsManager } from '../service/UsageHabitsManager';
import { CacheManager, STORE_NAME } from '../cache/CacheManager';
import { CACHE_KEY } from '../common/Constants';
import { AppSettingsStore } from '../service/AppSettingsStore';
import { WEIBO_BREAKPOINT_KEY, WeiboResponsiveLayout } from '../common/WeiboNavigationLayout';

const TAG: string = 'EntryAbility';
const STATUS_BAR_HEIGHT_KEY: string = 'weibo.status_bar_height';
const NAVIGATION_INDICATOR_HEIGHT_KEY: string = 'weibo.navigation_indicator_height';
const TOP_RECT_HEIGHT_KEY: string = 'weibo.top_rect_height';

export default class EntryAbility extends UIAbility {
  /** Window whose size and avoid-area listeners are owned by this Ability. */
  private observedMainWindow: window.Window | null = null;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(0x0000, TAG, 'Ability onCreate');
    // 关键时序：在首帧渲染前 fire-and-forget 异步把 Application Configuration 同步到 manual 值。
    // 此前 onWindowStageCreate loadContent 回调里调 setColorMode 会有 setColorMode 异步窗口与
    // onConfigurationUpdate 竞态（回调里 Configuration.colorMode 仍是旧值，按旧值再 setColorMode
    // 会把档位反向拉回）——挪到 onCreate 阶段可避开 loadContent 期间的 onConfigurationUpdate 干扰。
    // 注：onCreate 是 sync 函数，cache.init/get 是 async，故 fire-and-forget；首帧可能仍按系统档
    // 渲染（极短一次"闪烁"），随后 Configuration 同步，UI 自动按新档翻档。
    try {
      const ctx: common.UIAbilityContext = this.context;
      Promise.resolve().then(async () => {
        try {
          const cache = CacheManager.getInstance();
          await cache.init(ctx);
          const savedFollowSys: string | undefined = await cache.get(CACHE_KEY.FOLLOW_SYSTEM_DARK);
          const followSys: boolean = savedFollowSys !== '0';
          if (followSys) {
            // 跟随系统：不动 Configuration，让它保持 COLOR_MODE_NOT_SET 让系统档驱动
            return;
          }
          const savedDark: string | undefined = await cache.get(CACHE_KEY.DARK_MODE);
          const manualDark: boolean = savedDark === '1';
          ctx.getApplicationContext().setColorMode(manualDark
            ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK
            : ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
          hilog.info(0x0000, TAG, 'Cold start manualColorMode=%{public}s', manualDark ? 'DARK' : 'LIGHT');
        } catch (innerError) {
          hilog.error(0x0000, TAG, 'Cold start setColorMode failed: %{public}s', JSON.stringify(innerError));
        }
      }).catch(() => {
      });
    } catch (syncError) {
      hilog.error(0x0000, TAG, 'Cold start setup failed: %{public}s', JSON.stringify(syncError));
    }
  }

  onDestroy(): void {
    hilog.info(0x0000, TAG, 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // 缓存 UIAbilityContext：Theme.setDarkMode 切换深色时要用它调 applicationContext.setColorMode(...)，
    // 让 Configuration.colorMode 跟随变化，官方槽位（Navigation title 的 systemMaterial、
    // $r('sys.color.font_primary') / $r('sys.color.icon_primary') 等系统反色资源）才会自动翻档。
    // 必须写在 loadContent 之前——页面 aboutToAppear 里就可能读取它。
    AppStorage.setOrCreate<common.UIAbilityContext>('abilityContext', this.context);
    // 生产入口：Index.ets（微博客户端宿主壳：首页 / 说明 / 我的）
    windowStage.loadContent('pages/Index', async (err) => {
      if (err.code) {
        hilog.error(0x0000, TAG, 'Failed to load content: %{public}s', JSON.stringify(err));
        return;
      }
      try {
        const mainWindow: window.Window = await windowStage.getMainWindow();
        // 启动遮罩深色兜底（方案 B）：startWindow 由系统在应用进程外绘制，只能靠 resources/dark
        // 资源限定符跟随系统档（方案 A）；「应用内手动深色 + 系统浅色」场景系统无从得知，个别
        // 系统版本启动窗也可能不翻档。这里在窗口就绪后第一时间按持久化深色设置同步设主窗底色
        // （Theme.bg 深色档 #101114 / 浅色档 #F2F4F7），压缩遮罩消失→页面首帧之间的色差闪。
        // 注意：官方约束 setWindowBackgroundColor 必须在 loadContent 生效后调用，且为同步 void
        // 签名（无 Promise），故放在回调内 try/catch 兜底。同进度同步读 preferences（getPreferencesSync）。
        // 「关闭自动旋转」（阔直屏直板专用）冷启动取值容器：必须声明在下方 splash 的 try 块**外**，
        // 因为方向下发发生在该 try 之后（prefs 是块级作用域，出了块不可见）。
        // 取值失败 / 抛异常时保持 false = 允许旋转（安全方向，零回归）。
        let bootAutoRotateOff: boolean = false;
        try {
          const prefs: preferences.Preferences = preferences.getPreferencesSync(this.context, { name: STORE_NAME });
          const splashFollowSys: boolean = prefs.getSync(CACHE_KEY.FOLLOW_SYSTEM_DARK, '1') !== '0';
          const splashManualDark: boolean = prefs.getSync(CACHE_KEY.DARK_MODE, '0') === '1';
          // 借同一次同步读把「关闭自动旋转」开关也取出来（'1' = 已关闭自动旋转），供下方方向下发使用
          bootAutoRotateOff = prefs.getSync(CACHE_KEY.AUTO_ROTATE, '0') === '1';
          const splashSysDark: boolean =
            this.context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
          mainWindow.setWindowBackgroundColor((splashFollowSys ? splashSysDark : splashManualDark)
            ? '#101114' : '#F2F4F7');
        } catch (splashError) {
          hilog.error(0x0000, TAG, 'Splash window bg setup failed: %{public}s', JSON.stringify(splashError));
        }
        await mainWindow.setWindowLayoutFullScreen(true);
        this.observeWindowAvoidAreas(mainWindow);
        // 阔直屏 / 大折叠展开态：允许自动旋转（docs/TiebaPura阔直屏适配.md §2.4、docs/TiebaPura大折叠适配.md §三）。
        // AUTO_ROTATION_RESTRICTED 跟随重力，但遵从系统的旋转锁定开关。
        if (isWideBarDevice() || isLargeFoldDevice()) {
          // 阔直屏**直板**额外受「关闭自动旋转」开关约束（设置-使用习惯，仅该形态显示该开关）：
          // 开关打开 → 显式锁 PORTRAIT；未打开 → AUTO_ROTATION_RESTRICTED。
          // Pura X / Pura X Max 展开、大折叠展开都不在 isWideBarFlatDevice() 内 →
          // 恒走受系统旋转锁定控制的自动旋转。
          // 开关值取自上方 splash 段的同步读（bootAutoRotateOff）：UsageHabitsManager.init 在下方
          // await 才执行，若等它则窗口已按横屏渲染一帧，关闭旋转的设备会先横后竖地闪一下。
          const lockPortrait: boolean = isWideBarFlatDevice() && bootAutoRotateOff;
          const targetOrientation: window.Orientation = lockPortrait
            ? window.Orientation.PORTRAIT
            : window.Orientation.AUTO_ROTATION_RESTRICTED;
          mainWindow.setPreferredOrientation(targetOrientation).catch((err: Error) => {
            hilog.error(0x0000, TAG, 'setPreferredOrientation(%{public}s) failed: %{public}s',
              lockPortrait ? 'PORTRAIT' : 'AUTO_ROTATION_RESTRICTED', JSON.stringify(err));
          });
        }
        // 缓存主窗口：Theme.setDarkMode 切换深色时要同步状态栏内容色，避免每次异步 getLastWindow
        AppStorage.setOrCreate<window.Window>('mainWindow', mainWindow);
        // 初始化持久化深色设置到 AppStorage + 同步模块变量 + 同步状态栏内容色。
        // 注意：Configuration 的 setColorMode 已在 onCreate fire-and-forget 里做了，
        // 这里不再调 setColorMode，避免 setColorMode 异步窗口与 onConfigurationUpdate 竞态。
        await UsageHabitsManager.getInstance().init(this.context);
        // Language must be restored after loadContent has completed. This mirrors
        // HarmonyX's ApplicationContext timing and lets resource qualifiers take effect.
        await AppSettingsStore.getInstance().restoreLanguage(this.context);
        const followSys: boolean = UsageHabitsManager.getInstance().isFollowSystemDark();
        const sysDark: boolean =
          this.context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
        const manualDark: boolean = UsageHabitsManager.getInstance().isDarkModeManual();
        const resolvedDark: boolean = followSys ? sysDark : manualDark;
        // 跟随系统：冷启动时把手动「深色模式」开关值同步为系统当前态（覆盖 App 关闭期间
        // 系统切过色的场景，保证 PersonalizedPage 的手动 toggle 显示与系统档一致）
        if (followSys && manualDark !== sysDark) {
          UsageHabitsManager.getInstance().setDarkModeManual(sysDark);
        }
        // 同步模块变量：让 Theme 自绘 tokens 与 Configuration 一致
        initDarkMode(resolvedDark);
        // 同步状态栏/导航栏内容色：避免 Configuration 已切到目标档但状态栏文字色仍按冷启动默认浅色档
        mainWindow.setWindowSystemBarProperties({
          statusBarColor: '#00000000',
          navigationBarColor: '#00000000',
          statusBarContentColor: resolvedDark ? '#FFFFFF' : '#1A1A1A',
          navigationBarContentColor: resolvedDark ? '#FFFFFF' : '#1A1A1A',
        }).catch((err: Error) => {
          hilog.error(0x0000, TAG, 'setWindowSystemBarProperties failed: %{public}s', JSON.stringify(err));
        });
        hilog.info(0x0000, TAG,
          'Cold start resolvedDark=%{public}s followSys=%{public}s sysDark=%{public}s manualDark=%{public}s',
          resolvedDark ? '1' : '0',
          followSys ? '1' : '0',
          sysDark ? '1' : '0',
          manualDark ? '1' : '0');
        // 兜底：冷启动时 UI 渲染（各 Tab aboutToAppear）可能先于本回调里的 initDarkMode 执行，
        // 导致 HomeTab/MineTab 等读到的 isDarkMode() 是旧 _globalIsDark=false，this.isDark 卡在浅色档。
        // 这里递增一次 darkTick 让所有 @StorageLink('darkTick') @Watch 监听者触发 onDarkTick
        // 重读 isDarkMode() → 同步到正确档。darkTick 此时已是 0/1，自增必触发 watch。
        AppStorage.setOrCreate<number>('darkTick', (AppStorage.get<number>('darkTick') ?? 0) + 1);
        hilog.info(0x0000, TAG, 'Immersive window configured');
      } catch (windowError) {
        hilog.error(0x0000, TAG, 'Immersive window setup failed: %{public}s', JSON.stringify(windowError));
      }
      hilog.info(0x0000, TAG, 'Succeeded in loading content');
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(0x0000, TAG, 'Ability onWindowStageDestroy');
    const mainWindow: window.Window | null = this.observedMainWindow;
    this.observedMainWindow = null;
    if (mainWindow === null) {
      return;
    }
    try {
      mainWindow.off('windowSizeChange');
      mainWindow.off('avoidAreaChange');
    } catch (error) {
      hilog.warn(0x0000, TAG, 'Unable to remove window listeners: %{public}s', JSON.stringify(error));
    }
  }

  /** Keep routed pages aligned with the real system cutout and navigation indicator. */
  private observeWindowAvoidAreas(mainWindow: window.Window): void {
    try {
      this.observedMainWindow = mainWindow;
      const uiContext: UIContext = mainWindow.getUIContext();
      const systemAvoidArea: window.AvoidArea = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const navigationAvoidArea: window.AvoidArea =
        mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      AppStorage.setOrCreate<number>(TOP_RECT_HEIGHT_KEY, systemAvoidArea.topRect.height);
      AppStorage.setOrCreate<number>(STATUS_BAR_HEIGHT_KEY, uiContext.px2vp(systemAvoidArea.topRect.height));
      AppStorage.setOrCreate<number>(NAVIGATION_INDICATOR_HEIGHT_KEY,
        uiContext.px2vp(navigationAvoidArea.bottomRect.height));
      const windowRect: window.Rect = mainWindow.getWindowProperties().windowRect;
      this.updateResponsiveState(uiContext, windowRect.width);
      mainWindow.on('windowSizeChange', (windowSize: window.Size): void => {
        this.updateResponsiveState(uiContext, windowSize.width);
      });
      mainWindow.on('avoidAreaChange', (avoidAreaOption) => {
        if (avoidAreaOption.type === window.AvoidAreaType.TYPE_SYSTEM) {
          AppStorage.setOrCreate<number>(TOP_RECT_HEIGHT_KEY, avoidAreaOption.area.topRect.height);
          AppStorage.setOrCreate<number>(STATUS_BAR_HEIGHT_KEY,
            uiContext.px2vp(avoidAreaOption.area.topRect.height));
        } else if (avoidAreaOption.type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR) {
          AppStorage.setOrCreate<number>(NAVIGATION_INDICATOR_HEIGHT_KEY,
            uiContext.px2vp(avoidAreaOption.area.bottomRect.height));
        }
      });
    } catch (error) {
      hilog.error(0x0000, TAG, 'Unable to observe window avoid areas: %{public}s', JSON.stringify(error));
    }
  }

  /** Re-evaluate the split-navigation breakpoint for rotation, fold, and window resize. */
  private updateResponsiveState(uiContext: UIContext, windowWidthPx: number): void {
    const widthVp: number = uiContext.px2vp(windowWidthPx);
    const breakpoint: string = WeiboResponsiveLayout.breakpointForWidth(widthVp);
    AppStorage.setOrCreate<string>(WEIBO_BREAKPOINT_KEY, breakpoint);
  }

  onForeground(): void {
    hilog.info(0x0000, TAG, 'Ability onForeground');
  }

  /**
   * 系统配置变化回调：用户在系统控制中心切换深色模式时触发。
   *
   * **只读不写**！绝不调 setColorMode —— 在此回调里调 setColorMode 是反向拉回 / 重入循环的最大来源：
   * - 用户主动切色触发 setColorMode(DARK) → 异步窗口内 onConfigurationUpdate 触发 → 回调里
   *   newConfig.colorMode 仍是旧值 LIGHT → 调 setColorMode(LIGHT) 把档位反向拉回
   * - 系统 Configuration 已变 LIGHT（onConfigurationUpdate 收到的就是新值），官方槽位自动按 LIGHT
   *   渲染——不需要再调 setColorMode
   *
   * 此回调只做两件事：
   * 1. 同步 _globalIsDark 模块变量（Theme.syncDarkFromConfig），让 Theme 自绘 tokens 跟档
   * 2. 递增 darkTick 触发所有监听 darkTick 的页面 @StorageLink('darkTick') watch 翻 @State isDark
   *
   * 不跟随系统分支：用户在 ForumsTab/我的/月亮钮切过色（已写 setFollowSystemDark(false)），
   * 直接 return —— App 已锁在手动态，不再响应系统切色（这也是 HarmonyOS setColorMode 写死后的正常行为）。
   */
  onConfigurationUpdate(newConfig: Configuration): void {
    try {
      const followSys: boolean = AppStorage.get<boolean>('appFollowSystemDark') ?? true;
      if (!followSys) {
        // 手动档对账自愈：系统上报的 colorMode 为明确的 LIGHT/DARK 且与持久化手动档矛盾时，
        // 说明系统侧把应用级 colorMode 冲回了系统档（概率性，某些配置事件触发——表现为手动深色下
        // $r('sys.color.font_primary') 等系统反色资源突然变浅色档黑字）。重新下发手动档纠正。
        // 目标值取持久化手动档（固定值、不从 newConfig 推导），不存在「反向拉回」；纠正触发的
        // 下一次回调里两者已一致，幂等收敛。_globalIsDark 不动（应用内状态本来就没变，darkTick 不发）。
        const rawCfg: number | undefined = newConfig.colorMode;
        const cfgDark: boolean | null =
          rawCfg === ConfigurationConstant.ColorMode.COLOR_MODE_DARK ? true :
            (rawCfg === ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT ? false : null);
        if (cfgDark !== null) {
          const manualDark: boolean = UsageHabitsManager.getInstance().isDarkModeManual();
          if (cfgDark !== manualDark) {
            this.context.getApplicationContext().setColorMode(manualDark
              ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK
              : ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
            hilog.info(0x0000, TAG, 'Reassert manual colorMode=%{public}s (system reverted it)',
              manualDark ? 'DARK' : 'LIGHT');
          }
        }
        hilog.info(0x0000, TAG, 'Configuration update ignored: followSys=OFF (locked to manual)');
        return;
      }
      // newConfig.colorMode 可能为 undefined（系统 Configuration 变化可能不是色模态），
      // undefined 一律按 LIGHT 处理
      const rawColorMode: number | undefined = newConfig.colorMode;
      const sysDark: boolean =
        rawColorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
      hilog.info(0x0000, TAG,
        'Configuration update colorMode=%{public}s, followSys=ON, sysDark=%{public}s',
        String(rawColorMode), sysDark ? '1' : '0');
      // 1. 同步 _globalIsDark 模块变量（Theme 自绘 tokens 立即跟档）
      syncDarkFromConfig(sysDark);
      // 1.5 跟随系统期间，把手动「深色模式」开关值同步为系统当前态：
      //     系统进深色 → 自动打开「深色模式」开关；系统退深色 → 自动关闭。
      //     这样 PersonalizedPage 的「深色模式」toggle（@StorageLink('appDarkMode')）实时反映
      //     系统档位，且后续用户关掉「跟随系统」时手动档已等于当前系统态、不发生跳色。
      //     幂等短路：仅当 manual 值与系统态不一致时才写（setDarkModeManual 只写 AppStorage +
      //     持久化，不调 setColorMode，无重入风险）。
      if (UsageHabitsManager.getInstance().isDarkModeManual() !== sysDark) {
        UsageHabitsManager.getInstance().setDarkModeManual(sysDark);
      }
      // ⚠️ 不要在 onConfigurationUpdate 里调 setColorMode —— 这是「跟随系统档」架构的关键：
      //   跟随系统档要求 Application Configuration 永远保持 COLOR_MODE_NOT_SET（系统档驱动），
      //   系统切色时 Configuration 自动跟档，顶栏 systemMaterial / $r('sys.color.font_primary') 自动翻档。
      //   一旦在此调 setColorMode(DARK/LIGHT)，Configuration 被写死 + 「已锁死」标记让
      //   后续 onConfigurationUpdate 静默，系统切色不响应。
      // 2. 同步状态栏/导航栏内容色（冷启动时按 resolvedDark 设过色，后续系统切色时必须重设，
      //    否则状态栏文字色卡在冷启动档——黑字配深色背景几乎看不清）
      const mainWindow = AppStorage.get<window.Window>('mainWindow');
      if (mainWindow) {
        mainWindow.setWindowSystemBarProperties({
          statusBarColor: '#00000000',
          navigationBarColor: '#00000000',
          statusBarContentColor: sysDark ? '#FFFFFF' : '#1A1A1A',
          navigationBarContentColor: sysDark ? '#FFFFFF' : '#1A1A1A',
        }).catch((err: Error) => {
          hilog.error(0x0000, TAG, 'setWindowSystemBarProperties in onConfigurationUpdate failed: %{public}s',
            JSON.stringify(err));
        });
        // 窗口底色跟档：setWindowBackgroundColor 显式设过底色后不再自动跟随资源翻档，
        // 系统切色时这里按系统档重设（手动档切换由 Theme.setDarkMode 负责，不走此处）。
        // 同步 void 签名，异常由外层 try/catch 兜底
        mainWindow.setWindowBackgroundColor(sysDark ? '#101114' : '#F2F4F7');
      }
      // 3. 递增 darkTick 触发所有监听 darkTick 的页面 @StorageLink('darkTick') watch 翻 @State isDark
      AppStorage.setOrCreate<number>('darkTick', (AppStorage.get<number>('darkTick') ?? 0) + 1);
    } catch (e) {
      hilog.error(0x0000, TAG, 'onConfigurationUpdate failed: %{public}s', JSON.stringify(e));
    }
  }

  onBackground(): void {
    hilog.info(0x0000, TAG, 'Ability onBackground');
  }
}
