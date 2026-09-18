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

import { uiMaterial, window, display } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { common, ConfigurationConstant } from '@kit.AbilityKit';

/**
 * 主题与设计令牌。
 * 通过模块级变量维护全局深色模式（V1 组件兼容方案）。
 */
let _globalIsDark: boolean = false;

// ========== 设备沉浸光感能力检测 ==========

let _materialInitialized: boolean = false;
let _materialSupported: boolean = false;
let _materialApiLevel: number = 0;

/**
 * 初始化设备沉浸光感能力检测。
 * 在应用启动时调用一次，结果缓存。
 */
export function initMaterialSupport(): void {
  if (_materialInitialized) {
    return;
  }
  _materialInitialized = true;
  try {
    // HarmonyOS 工程的 API 兼容判断必须使用 apiAvailable；sdkApiVersion 仅适用于
    // OpenHarmony 底座接口。此处保持独立 if，以便编译器识别 API 26 的保护范围。
    // Some API-24 tablet builds report the target SDK through apiAvailable even
    // though the API-26 ImmersiveStyle enum is absent at runtime. Require the
    // actual device SDK as HarmonyX does before touching uiMaterial symbols.
    if (deviceInfo.sdkApiVersion >= 26 && deviceInfo.apiAvailable('26.0.0')) {
      _materialApiLevel = 26;
      // 即便设备声称支持 API 26，也实际构造一次，异常系统或不完整实现立即回退。
      const probe: uiMaterial.ImmersiveMaterial = new uiMaterial.ImmersiveMaterial();
      _materialSupported = !!probe;
      return;
    }
    // API 23~25 可以使用 HDS 材质，但没有 ArkUI uiMaterial；它们不能共用同一开关。
    _materialApiLevel = 0;
    _materialSupported = false;
  } catch (e) {
    _materialSupported = false;
  }
}

/**
 * 当前设备是否支持沉浸光感。
 */
export function isMaterialSupported(): boolean {
  if (!_materialInitialized) {
    initMaterialSupport();
  }
  return _materialSupported;
}

// ========== 沉浸光感材质预设 ==========
// 基于官方 uiMaterial.ImmersiveMaterial（@since 26.0.0），提供统一的材质风格。
// 低版本（API 23~25）没有 uiMaterial：所有实例统一经 createMaterial() 构造，
// 不支持时返回 undefined（`.systemMaterial()` 接受 undefined，等价于官方兼容写法）。

// 材质实例缓存
let _matControl: uiMaterial.Material | undefined = undefined;
let _matBar: uiMaterial.Material | undefined = undefined;
let _matTab: uiMaterial.Material | undefined = undefined;
let _matCardAction: uiMaterial.Material | undefined = undefined;
let _matFab: uiMaterial.Material | undefined = undefined;
let _matFabFlat: uiMaterial.Material | undefined = undefined;
let _matRowItem: uiMaterial.Material | undefined = undefined;
let _matTabActiveDark: uiMaterial.Material | undefined = undefined;
let _matTabActiveLight: uiMaterial.Material | undefined = undefined;
let _matAccentDark: uiMaterial.Material | undefined = undefined;
let _matAccentLight: uiMaterial.Material | undefined = undefined;
let _matDangerDark: uiMaterial.Material | undefined = undefined;
let _matDangerLight: uiMaterial.Material | undefined = undefined;
let _matBottomGlowDark: uiMaterial.Material | undefined = undefined;
let _matBottomGlowLight: uiMaterial.Material | undefined = undefined;
let _matFloating: uiMaterial.ImmersiveMaterial | undefined = undefined;
let _matFloatingFlat: uiMaterial.ImmersiveMaterial | undefined = undefined;
let _matDialog: uiMaterial.ImmersiveMaterial | undefined = undefined;
let _matSegActive: uiMaterial.Material | undefined = undefined;
let _matSegIdle: uiMaterial.Material | undefined = undefined;
let _matSegActiveFlat: uiMaterial.Material | undefined = undefined;
let _matSegIdleFlat: uiMaterial.Material | undefined = undefined;

/** Application accent is kept in AppStorage so every page reads one source of truth. */
function currentAccent(): string {
  const saved: string = AppStorage.get<string>('appAccentColor') ?? '#E6162D';
  if (saved === '#E6162D' || saved === '#007DFF' || saved === '#7856FF'
    || saved === '#00A870' || saved === '#F59E0B') {
    return saved;
  }
  return '#E6162D';
}

function accentAlpha(alpha: string): string {
  return `#${alpha}${currentAccent().substring(1)}`;
}

/**
 * Accent-tinted material instances are immutable. Clear just those caches
 * whenever the application preference changes so the next render recreates
 * them with the new global color.
 */
export function refreshAppAccentMaterials(): void {
  _matTabActiveDark = undefined;
  _matTabActiveLight = undefined;
  _matAccentDark = undefined;
  _matAccentLight = undefined;
  _matBottomGlowDark = undefined;
  _matBottomGlowLight = undefined;
}

/**
 * 低版本安全网：材质实例统一构造入口。
 *
 * - `uiMaterial` 全部 API 为 `@since 26.0.0`，API 23~25 上该命名空间不存在，
 *   此时 `new uiMaterial.ImmersiveMaterial(...)` 会抛异常；
 * - 而 `ImmMaterial.*` 在工程内有 100+ 处**无条件**调用（`.systemMaterial(ImmMaterial.X())`），
 *   没有逐点包三元/判断，所以把口袋收在这里；
 * - 不支持 / 构造失败时返回 **运行期 `undefined`**：`common.d.ts` 中
 *   `.systemMaterial(material: SystemUiMaterial | undefined)` 明确接受 `undefined`，
 *   与官方兼容写法 `apiVersion >= 26 ? material : undefined` 完全等价（低版本字段被系统忽略）。
 *
 * 因此本文件材质相关的返回类型统一放宽为 `| undefined`（调用点零改动：
 * `.systemMaterial()` 与各 options 的 `systemMaterial?` 都接受 undefined）。
 */
enum ImmersiveStyleKind {
  UltraThin,
  Thin,
  Regular,
  Thick,
}

interface ImmersiveMaterialRecipe {
  style: ImmersiveStyleKind;
  interactive: boolean;
  applyShadow: boolean;
  enableLightEffect?: boolean;
  materialColor?: string;
  colorInvert?: boolean;
}

function createMaterial(recipe: ImmersiveMaterialRecipe): uiMaterial.ImmersiveMaterial | undefined {
  // apiAvailable 必须直接置于 if 条件中，才能同时形成运行时保护并消除低版本 API 告警。
  if (deviceInfo.sdkApiVersion >= 26 && deviceInfo.apiAvailable('26.0.0')) {
    if (!isMaterialSupported()) {
      return undefined;
    }
    try {
      let nativeStyle: uiMaterial.ImmersiveStyle = uiMaterial.ImmersiveStyle.REGULAR;
      if (recipe.style === ImmersiveStyleKind.UltraThin) {
        nativeStyle = uiMaterial.ImmersiveStyle.ULTRA_THIN;
      } else if (recipe.style === ImmersiveStyleKind.Thin) {
        nativeStyle = uiMaterial.ImmersiveStyle.THIN;
      } else if (recipe.style === ImmersiveStyleKind.Thick) {
        nativeStyle = uiMaterial.ImmersiveStyle.THICK;
      }
      if (recipe.enableLightEffect === true) {
        return new uiMaterial.ImmersiveMaterial({
          style: nativeStyle,
          interactive: recipe.interactive,
          lightEffect: { color: undefined },
          applyShadow: recipe.applyShadow,
          materialColor: recipe.materialColor,
          colorInvert: recipe.colorInvert,
        });
      }
      if (recipe.enableLightEffect === false) {
        return new uiMaterial.ImmersiveMaterial({
          style: nativeStyle,
          interactive: recipe.interactive,
          lightEffect: null,
          applyShadow: recipe.applyShadow,
          materialColor: recipe.materialColor,
          colorInvert: recipe.colorInvert,
        });
      }
      return new uiMaterial.ImmersiveMaterial({
        style: nativeStyle,
        interactive: recipe.interactive,
        applyShadow: recipe.applyShadow,
        materialColor: recipe.materialColor,
        colorInvert: recipe.colorInvert,
      });
    } catch (e) {
      return undefined;
    }
  }
  return undefined;
}

function ensureControl(): uiMaterial.Material | undefined {
  if (!_matControl) {
    _matControl = createMaterial({
      style: ImmersiveStyleKind.UltraThin,
      interactive: true,
      enableLightEffect: true,
      applyShadow: true,
    });
  }
  return _matControl;
}

function ensureBar(): uiMaterial.Material | undefined {
  if (!_matBar) {
    _matBar = createMaterial({
      style: ImmersiveStyleKind.UltraThin,
      interactive: false,
      enableLightEffect: true,
      applyShadow: true,
      colorInvert: true,
    });
  }
  return _matBar;
}

function ensureFloatingBar(): uiMaterial.ImmersiveMaterial | undefined {
  if (!_matFloating) {
    _matFloating = createMaterial({
      style: ImmersiveStyleKind.Thin,
      interactive: false,
      // 显式禁用流光：官方语义「传对象=启用、传 null=禁用、不传=跟随组件默认」；
      // 此前 { color: undefined } 属于「传对象启用」，悬浮岛上沿会渲染一条白色光感线（真机可见，用户要求去掉）。
      enableLightEffect: false,
      applyShadow: true,
      colorInvert: true,
    });
  }
  return _matFloating;
}

/**
 * 悬浮玻璃胶囊 — 无阴影档：与 ensureFloatingBar 仅 `applyShadow` 之差（其余 THIN / 无流光 /
 * colorInvert 逐项一致）。
 * 用于**由页面元素自己挂 `systemMaterial`** 的悬浮栏（空壳槽位路径，如吧主页底部排序栏）：
 * 这类栏贴在列表内容上方、下方没有「官方背板」托底，材质自带投影会在栏体四周压出一圈
 * 突兀的暗晕（真机反馈要求去除，2026-09-12）；走 `barFloatingStyle` 的官方悬浮岛仍用带阴影版
 * （首页 / 搜索页 / 帖子详情页底栏 —— 那里的阴影属于悬浮岛观感的一部分，不在此列）。
 * 处理方式与 `segFlat`（帖子详情页排序胶囊）/ `fabFlat`（右下加号）同款。
 */
function ensureFloatingBarFlat(): uiMaterial.ImmersiveMaterial | undefined {
  if (!_matFloatingFlat) {
    _matFloatingFlat = createMaterial({
      style: ImmersiveStyleKind.Thin,
      interactive: false,
      enableLightEffect: false,
      applyShadow: false,
      colorInvert: true,
    });
  }
  return _matFloatingFlat;
}

function ensureTab(): uiMaterial.Material | undefined {
  if (!_matTab) {
    _matTab = createMaterial({
      style: ImmersiveStyleKind.Regular,
      interactive: true,
      enableLightEffect: true,
      applyShadow: true,
    });
  }
  return _matTab;
}

function ensureTabActiveDark(): uiMaterial.Material | undefined {
  if (!_matTabActiveDark) {
    _matTabActiveDark = createMaterial({
      style: ImmersiveStyleKind.Regular,
      interactive: true,
      enableLightEffect: true,
      applyShadow: true,
      materialColor: accentAlpha('55'),
    });
  }
  return _matTabActiveDark;
}

function ensureTabActiveLight(): uiMaterial.Material | undefined {
  if (!_matTabActiveLight) {
    _matTabActiveLight = createMaterial({
      style: ImmersiveStyleKind.Regular,
      interactive: true,
      enableLightEffect: true,
      applyShadow: true,
      materialColor: accentAlpha('38'),
    });
  }
  return _matTabActiveLight;
}

/**
 * 标题栏分段胶囊 — 选中档：REGULAR 中性玻璃（不染色，选中感由文字强调色 + 字重承担，
 * 与首页「推荐/关注动态」既有观感一致）+ 按压弹性形变 + 光感反馈。
 */
function ensureSegActive(): uiMaterial.Material | undefined {
  if (!_matSegActive) {
    _matSegActive = createMaterial({
      style: ImmersiveStyleKind.Regular,
      interactive: true,
      enableLightEffect: true,
      applyShadow: true,
    });
  }
  return _matSegActive;
}

/**
 * 标题栏分段胶囊 — 未选中档：THIN，比选中档更薄，形成选中/未选中层次。
 */
function ensureSegIdle(): uiMaterial.Material | undefined {
  if (!_matSegIdle) {
    _matSegIdle = createMaterial({
      style: ImmersiveStyleKind.Thin,
      interactive: true,
      enableLightEffect: true,
      applyShadow: true,
    });
  }
  return _matSegIdle;
}

/**
 * 分段胶囊 — 选中档（无阴影版）：与 ensureSegActive 仅 applyShadow 之差。
 * 用于帖子详情页底部排序胶囊：两枚胶囊浮在白卡上方，材质自带阴影落在卡面上
 * 合并成一层明显的淡阴影（真机反馈要求去除，2026-09-10）；标题栏胶囊仍用带阴影版。
 */
function ensureSegActiveFlat(): uiMaterial.Material | undefined {
  if (!_matSegActiveFlat) {
    _matSegActiveFlat = createMaterial({
      style: ImmersiveStyleKind.Regular,
      interactive: true,
      enableLightEffect: true,
      applyShadow: false,
    });
  }
  return _matSegActiveFlat;
}

/** 分段胶囊 — 未选中档（无阴影版）：与 ensureSegIdle 仅 applyShadow 之差。 */
function ensureSegIdleFlat(): uiMaterial.Material | undefined {
  if (!_matSegIdleFlat) {
    _matSegIdleFlat = createMaterial({
      style: ImmersiveStyleKind.Thin,
      interactive: true,
      enableLightEffect: true,
      applyShadow: false,
    });
  }
  return _matSegIdleFlat;
}

function ensureCardAction(): uiMaterial.Material | undefined {
  if (!_matCardAction) {
    _matCardAction = createMaterial({
      style: ImmersiveStyleKind.Thin,
      interactive: true,
      applyShadow: true,
    });
  }
  return _matCardAction;
}

function ensureFab(): uiMaterial.Material | undefined {
  if (!_matFab) {
    _matFab = createMaterial({
      style: ImmersiveStyleKind.Thick,
      interactive: true,
      enableLightEffect: true,
      applyShadow: true,
    });
  }
  return _matFab;
}

/**
 * FAB 悬浮圆钮 — 自适应反色 + 无阴影档（与底栏同排的槽位 FAB 专用，如吧主页右下加号）。
 *
 * 与 `ensureFab` 的差别：材质档由 THICK 收到 THIN、关掉材质自带投影（同 ensureFloatingBarFlat，
 * 钮直接浮在列表内容上，带阴影会在钮下方压出一圈淡影，真机反馈要求去除，2026-09-11），
 * 并**开启 `colorInvert`**。
 *
 * `colorInvert: true` 是「材质随背景明暗自动翻转」的开关（官方语义：材质按其覆盖区域的背景
 * 明暗，自动反转材质与其中**系统语义色内容**的着色）。此前该钮用 `segFlat(false)`（无 colorInvert），
 * 与同排底栏（floatingBarFlat，带 colorInvert）并排时只有底栏及其文字随背景变色、加号纹丝不动
 * （用户反馈，2026-09-12）；换成本档后钮与底栏同档，材质与图标一起翻色。
 * 保留 `interactive: true`（可点按圆钮，按压弹性形变 + 光感反馈，与 segFlat 一致）。
 *
 * ⚠️ 使用约束：图标 / 文字必须用**系统语义色**（如 `$r('sys.color.font_primary')`）才能被反色，
 * 用自绘 hex（Theme.textPrimary 等）时 colorInvert 对该内容无效。
 */
function ensureFabFlat(): uiMaterial.Material | undefined {
  if (!_matFabFlat) {
    _matFabFlat = createMaterial({
      style: ImmersiveStyleKind.Thin,
      interactive: true,
      enableLightEffect: true,
      applyShadow: false,
      colorInvert: true,
    });
  }
  return _matFabFlat;
}

function ensureAccentDark(): uiMaterial.Material | undefined {
  if (!_matAccentDark) {
    _matAccentDark = createMaterial({
      style: ImmersiveStyleKind.Thin,
      interactive: true,
      enableLightEffect: true,
      applyShadow: true,
      materialColor: accentAlpha('66'),
    });
  }
  return _matAccentDark;
}

function ensureAccentLight(): uiMaterial.Material | undefined {
  if (!_matAccentLight) {
    _matAccentLight = createMaterial({
      style: ImmersiveStyleKind.Thin,
      interactive: true,
      enableLightEffect: true,
      applyShadow: true,
      materialColor: accentAlpha('4C'),
    });
  }
  return _matAccentLight;
}

/**
 * 危险色主按钮（删除 / 清空等不可逆操作）。与 accent 严格同构，仅把品牌蓝赋色换成危险红
 * （Theme.danger() = #F5222D），保证「主按钮 / 危险按钮」两档材质观感一致。
 */
function ensureDangerDark(): uiMaterial.Material | undefined {
  if (!_matDangerDark) {
    _matDangerDark = createMaterial({
      style: ImmersiveStyleKind.Thin,
      interactive: true,
      enableLightEffect: true,
      applyShadow: true,
      materialColor: '#66F5222D',
    });
  }
  return _matDangerDark;
}

function ensureDangerLight(): uiMaterial.Material | undefined {
  if (!_matDangerLight) {
    _matDangerLight = createMaterial({
      style: ImmersiveStyleKind.Thin,
      interactive: true,
      enableLightEffect: true,
      applyShadow: true,
      materialColor: '#4CF5222D',
    });
  }
  return _matDangerLight;
}

function ensureBottomGlowDark(): uiMaterial.Material | undefined {
  if (!_matBottomGlowDark) {
    _matBottomGlowDark = createMaterial({
      style: ImmersiveStyleKind.Thick,
      interactive: false,
      applyShadow: true,
      materialColor: accentAlpha('55'),
    });
  }
  return _matBottomGlowDark;
}

function ensureBottomGlowLight(): uiMaterial.Material | undefined {
  if (!_matBottomGlowLight) {
    _matBottomGlowLight = createMaterial({
      style: ImmersiveStyleKind.Thick,
      interactive: false,
      applyShadow: true,
      materialColor: accentAlpha('38'),
    });
  }
  return _matBottomGlowLight;
}

function ensureRowItem(): uiMaterial.Material | undefined {
  if (!_matRowItem) {
    _matRowItem = createMaterial({
      style: ImmersiveStyleKind.Regular,
      interactive: true,
      enableLightEffect: true,
      applyShadow: true,
    });
  }
  return _matRowItem;
}

/**
 * 弹窗卡片材质（系统 CustomDialog 的 systemMaterial）。
 * REGULAR 档：对齐改造前弹窗玻璃的 BlurStyle.Regular 观感；
 * interactive=false / applyShadow=true：保持与既有弹窗一致的「无按压形变 + 系统阴影」。
 * 注意：必须挂在不透明弹窗容器的 options.systemMaterial 上（customStyle 需为 false），
 * 挂在页面 body 的自绘浮层上会判 out of scope 而不渲染。
 */
function ensureDialog(): uiMaterial.ImmersiveMaterial | undefined {
  if (!_matDialog) {
    _matDialog = createMaterial({
      style: ImmersiveStyleKind.Regular,
      interactive: false,
      applyShadow: true,
    });
  }
  return _matDialog;
}

/**
 * 沉浸光感材质预设 — 对外导出接口。
 * 所有方法返回 uiMaterial.Material 实例，可安全复用。
 * 沉浸光感恒开启（默认即此路径），系统材质始终启用，不再受运行时开关控制。
 */
export class ImmMaterial {
  /** 圆形控制按钮（顶栏返回/搜索/更多等 44x44 圆形按钮）。ULTRA_THIN + 按压弹性形变 + 光感反馈。 */
  static control(): uiMaterial.Material | undefined {
    return ensureControl();
  }
  /** 底部/顶部容器栏。THIN + 系统阴影，无交互形变。 */
  static bar(): uiMaterial.Material | undefined {
    return ensureBar();
  }
  /** 底部悬浮玻璃胶囊（挂真实 Tabs.tabBar 槽位，供原生 barFloatingStyle 的 systemMaterial 使用）。 */
  static floatingBar(): uiMaterial.ImmersiveMaterial | undefined {
    return ensureFloatingBar();
  }
  /** 同 floatingBar，但 applyShadow: false（无材质投影）。用于页面元素自己挂材质的悬浮栏
   *  （空壳槽位路径，如吧主页底部排序栏 —— 悬浮在列表之上，自带阴影会压出突兀暗晕，
   *  真机反馈要求去除，详见 ensureFloatingBarFlat 注释）。 */
  static floatingBarFlat(): uiMaterial.ImmersiveMaterial | undefined {
    return ensureFloatingBarFlat();
  }
  /** 胶囊 Tab 按钮。REGULAR + 按压弹性形变 + 光感反馈。 */
  static tab(): uiMaterial.Material | undefined {
    return ensureTab();
  }
  /**
   * 标题栏 / 吸顶分段胶囊（选中 REGULAR、未选中 THIN，两档均中性无色）。
   * 仅用于官方槽位（Navigation/NavDestination 标题栏、Tabs(barPosition=End) 底部 TabBar）内的分段钮：
   * 页面主体元素挂 systemMaterial 判 out of scope 不渲染，且官方建议 systemMaterial 不要与
   * backgroundColor / backgroundBlurStyle / border / shadow 同用（会互相覆盖）。
   */
  static seg(active: boolean): uiMaterial.Material | undefined {
    return active ? ensureSegActive() : ensureSegIdle();
  }
  /** 同 seg，但 applyShadow: false（无材质投影）。用于浮在白卡上方的排序胶囊（详见 ensureSegActiveFlat 注释）。 */
  static segFlat(active: boolean): uiMaterial.Material | undefined {
    return active ? ensureSegActiveFlat() : ensureSegIdleFlat();
  }
  /** 选中态胶囊 Tab。REGULAR + 品牌色赋色 + 光感反馈。 */
  static tabActive(isDark: boolean): uiMaterial.Material | undefined {
    return isDark ? ensureTabActiveDark() : ensureTabActiveLight();
  }
  /** 卡片内操作按钮。THIN + 按压弹性形变。 */
  static cardAction(): uiMaterial.Material | undefined {
    return ensureCardAction();
  }
  /** FAB 悬浮操作按钮。THICK + 按压弹性形变 + 光感反馈。 */
  static fab(): uiMaterial.Material | undefined {
    return ensureFab();
  }
  /** 同 fab，但材质档降到 THIN、去掉材质投影、并开启 `colorInvert`（随背景自动反色）。
   *  用于与底部悬浮栏**同排**的槽位 FAB（如吧主页右下加号）：与同排底栏同档才能一起随背景变色。
   *  ⚠️ 钮内图标须用系统语义色（`$r('sys.color.font_primary')`），自绘 hex 不受 colorInvert 影响。 */
  static fabFlat(): uiMaterial.Material | undefined {
    return ensureFabFlat();
  }
  /** 品牌主按钮。THIN + 品牌色赋色 + 光感反馈。 */
  static accent(isDark: boolean): uiMaterial.Material | undefined {
    return isDark ? ensureAccentDark() : ensureAccentLight();
  }
  /** 危险色主按钮（删除 / 清空等不可逆操作）。THIN + 危险红赋色 + 光感反馈，与 accent 同构。 */
  static danger(isDark: boolean): uiMaterial.Material | undefined {
    return isDark ? ensureDangerDark() : ensureDangerLight();
  }
  /** 底栏选中项高亮。THICK + 品牌色赋色，最强光晕。 */
  static bottomGlow(isDark: boolean): uiMaterial.Material | undefined {
    return isDark ? ensureBottomGlowDark() : ensureBottomGlowLight();
  }
  /** 条目按钮。REGULAR + 按压弹性形变。 */
  static rowItem(): uiMaterial.Material | undefined {
    return ensureRowItem();
  }
  /**
   * 系统弹窗卡片（CustomDialog 的 options.systemMaterial）。
   * REGULAR + 系统阴影，无按压形变 —— 对齐改造前弹窗玻璃的 BlurStyle.Regular 观感。
   * 只能用于系统弹窗（customStyle=false），挂在页面 body 自绘浮层上不渲染。
   */
  static dialog(): uiMaterial.ImmersiveMaterial | undefined {
    return ensureDialog();
  }
  /**
   * 半模态抽屉（bindSheet 的 options.systemMaterial）。
   * 与 dialog 同为「REGULAR 卡片档」且共用同一实例（材质按 style 分档缓存，参数相同不必再建一个）。
   * 同样只能用于系统槽位（半模态 / 弹窗），页面 body 内的自绘浮层上不渲染。
   */
  static sheet(): uiMaterial.ImmersiveMaterial | undefined {
    return ensureDialog();
  }
  /**
   * 下拉菜单（bindMenu 的 options.systemMaterial）。
   * 同为「REGULAR 卡片档」，沿用同一实例 —— 对齐改造前自绘下拉面板的 `BlurStyle.Regular, scale 0.85` 观感。
   * 只能用于系统槽位（bindMenu / bindContextMenu 的 options），页面 body 内的自绘浮层上不渲染。
   */
  static menu(): uiMaterial.ImmersiveMaterial | undefined {
    return ensureDialog();
  }
}

/**
 * 背景效果预设 — 与 ImmMaterial 方法同名一一对应（无参版本）。
 * 沉浸光感恒开启：统一返回空背景效果（radius 0 + 全透明色，不渲染模糊），
 * 玻璃外观完全由 ImmersiveMaterial（systemMaterial）承担，避免双模糊叠加。
 * 使用方法：在每个 `.systemMaterial(ImmMaterial.X(...))` 前追加一行
 * `.backgroundEffect(ImmBlur.X())`，背景效果常驻但为空，保持与既有调用点结构一致。
 */
export interface ImmEffectOptions {
  radius: number;
  saturation?: number;
  brightness?: number;
  color?: string;
}

/** 玻璃浮起阴影（结构对齐 ArkUI ShadowOptions） */
export interface GlassShadowOptions {
  radius: number;
  color?: string;
  offsetX?: number;
  offsetY?: number;
}

/** 空背景效果：模糊半径 0 + 全透明，避免与系统材质叠加 */
const IMM_EMPTY_EFFECT: ImmEffectOptions = { radius: 0, color: '#00000000' };

/** 空阴影：零半径 + 全透明，避免与系统材质自带阴影叠成双影 */
const IMM_EMPTY_SHADOW: GlassShadowOptions = { radius: 0, color: '#00000000' };

export class ImmBlur {
  /** control 同源档（空背景效果） */
  static control(): ImmEffectOptions { return IMM_EMPTY_EFFECT; }
  /** bar 同源档（空背景效果） */
  static bar(): ImmEffectOptions { return IMM_EMPTY_EFFECT; }
  /** cardAction 同源档（空背景效果） */
  static cardAction(): ImmEffectOptions { return IMM_EMPTY_EFFECT; }
  /** accent 强调档（空背景效果，品牌色由材质赋色承担） */
  static accent(): ImmEffectOptions { return IMM_EMPTY_EFFECT; }
  /** tab/rowItem 同源档（空背景效果） */
  static tab(): ImmEffectOptions { return IMM_EMPTY_EFFECT; }
  /** tabActive 强调档（空背景效果，蓝色由材质赋色承担） */
  static tabActive(): ImmEffectOptions { return IMM_EMPTY_EFFECT; }
  /** rowItem 同源档（空背景效果） */
  static rowItem(): ImmEffectOptions { return IMM_EMPTY_EFFECT; }
  /** fab 同源档（空背景效果） */
  static fab(): ImmEffectOptions { return IMM_EMPTY_EFFECT; }
  /** bottomGlow 强调档（空背景效果） */
  static bottomGlow(): ImmEffectOptions { return IMM_EMPTY_EFFECT; }
}

/**
 * 设备沉浸光感能力管理器（兼容 API）。
 */
export class MaterialManager {
  static init(): void { initMaterialSupport(); }
  static isSupported(): boolean { return isMaterialSupported(); }
  static getApiLevel(): number { return _materialApiLevel; }
}

// ========== 降级方案颜色 ==========
// 设备不支持 systemMaterial 时的手动玻璃效果颜色

export class Theme {
  // 背景
  static bg(isDark: boolean): string { return isDark ? '#101114' : '#F2F4F7'; }
  static bgCard(isDark: boolean): string { return isDark ? '#1B1E24' : '#FFFFFF'; }
  static bgElevated(isDark: boolean): string { return isDark ? '#252A33' : '#FFFFFF'; }
  // v1.15.9 弹窗卡片背景：高不透明度纯色（替代磨砂玻璃 systemMaterial，避免暗蒙层+模糊叠加泛白；配合弱蒙层+强阴影产生浮起层次）
  // v1.18 降低沉浸光感透出：alpha F2(95%) → F8(97.6%) → FA(98%)，弹窗更实、材质光感更收敛
  // v1.19 方案B(层次光感)：深色底提亮为墨蓝 #232832，配合顶部高光边+双层阴影+降透蒙层营造浮起光感，文字对比度同步提升
  static sheetBg(isDark: boolean): string { return isDark ? '#FC232832' : '#FAFFFFFF'; }
  /** v1.19 弹窗卡片顶部高光边(1.5vp border，模拟玻璃上缘受光；深色明显、浅色白卡上近乎不可见) */
  static sheetTopGlow(isDark: boolean): string { return isDark ? '#40FFFFFF' : '#80FFFFFF'; }
  /** 弹窗/浮层真模糊磨砂底（配合 .backgroundBlurStyle(BlurStyle.Regular, {scale}) 使用）：
   *  与 segGlass 同思路「不铺白夹层」：亮色完全透明、深色仅 18% 微暗底，
   *  让 Regular 自带的白 tint 直接呈现磨砂、背后内容（吧卡/头像/文字）透出轮廓——
   *  任何半透明白底叠在 blur 上都会形成「白夹层」盖掉模糊与透出，观感退回纯白底。 */
  static sheetGlass(isDark: boolean): string { return isDark ? '#2E1A1A1E' : '#00000000'; }
  static bgSurface(isDark: boolean): string { return isDark ? '#262B34' : '#F5F6F8'; }
  static glass(isDark: boolean): string { return isDark ? '#B81B1E24' : '#CCFFFFFF'; }
  static glassHighlight(isDark: boolean): string { return isDark ? '#36FFFFFF' : '#DFFFFFFF'; }
  // 骨架屏（第四批；v1.16：亮色占位块加深一档突出层次，高亮透明度调低避免刺眼，深色高亮稍提亮保证可见）
  static skeletonBase(isDark: boolean): string { return isDark ? '#252A33' : '#E3E7EF'; }
  static skeletonHighlight(isDark: boolean): string { return isDark ? '#30FFFFFF' : '#26FFFFFF'; }
  // 骨架屏方案G："未上墨的纸"——整块占位底色，比页面底色略深一档，接近背景避免块状突兀
  static skeletonSheet(isDark: boolean): string { return isDark ? '#171A20' : '#EDF0F4'; }
  static glassSheen(isDark: boolean): string { return isDark ? '#48FFFFFF' : '#F0FFFFFF'; }
  static glassAccent(): string { return currentAccent(); }
  static glassGlow(isDark: boolean): string { return accentAlpha(isDark ? '66' : '45'); }
  static glassGlowStrong(isDark: boolean): string { return accentAlpha(isDark ? 'A0' : '70'); }
  static glassShadow(isDark: boolean): string { return isDark ? '#99000000' : '#3D102018'; }
  static glassControl(isDark: boolean): string { return isDark ? '#7A252A33' : '#B8FFFFFF'; }
  // 实底档（图片浏览浮层三件套用）：不透明，取代半透明玻璃档。
  // 原因：系统安全控件 SaveButton 自带不透明背托，无法玻璃化（材质属性不在其白名单内），
  // 若外壳继续用半透明档，会出现「实底黑钮 vs 半透明玻璃钮」的割裂观感（坑 29）。
  static glassControlSolid(isDark: boolean): string { return isDark ? '#1B1E24' : '#FFFFFF'; }
  static glassControlLine(isDark: boolean): string { return isDark ? '#58FFFFFF' : '#E6FFFFFF'; }
  static glassControlShadow(isDark: boolean): string { return isDark ? '#70000000' : '#30101824'; }
  static glassBrand(isDark: boolean): string { return accentAlpha(isDark ? '7A' : '4C'); }
  static topBarGlass(isDark: boolean): string { return isDark ? '#991B1E24' : '#B8FFFFFF'; }
  static topBarLine(isDark: boolean): string { return isDark ? '#42FFFFFF' : '#D6FFFFFF'; }
  static topBarShadow(isDark: boolean): string { return isDark ? '#66000000' : '#24101824'; }
  static bottomGlass(isDark: boolean): string { return isDark ? '#661B1E24' : '#66FFFFFF'; }
  static bottomGlassLine(isDark: boolean): string { return isDark ? '#55FFFFFF' : '#B8FFFFFF'; }
  static bottomGlassShadow(isDark: boolean): string { return isDark ? '#88000000' : '#30101824'; }
  static homeTopStart(isDark: boolean): string { return isDark ? '#E61B2530' : '#EAF1F8'; }
  static homeTopMid(isDark: boolean): string { return isDark ? '#D61B1F29' : '#F6F9FC'; }
  static homeTopEnd(isDark: boolean): string { return isDark ? '#001B1F29' : '#00F6F9FC'; }
  static homeTopLine(isDark: boolean): string { return isDark ? '#36FFFFFF' : '#B8FFFFFF'; }
  static homeTopShadow(isDark: boolean): string { return isDark ? '#33000000' : '#14101824'; }
  // 文字
  static textPrimary(isDark: boolean): string { return isDark ? '#F0F2F5' : '#1A1A1A'; }
  static textSecondary(isDark: boolean): string { return isDark ? '#A8AEB8' : '#4E545C'; }
  static textTertiary(isDark: boolean): string { return isDark ? '#6E7480' : '#9AA0A6'; }
  /**
   * 图标主色（替代 $r('sys.color.icon_primary')，绕开 Configuration 锁死后系统反色资源卡在旧档的坑）。
   * 与 textPrimary 同源深色档（#F0F2F5 / #1A1A1A），视觉上与 HarmonyOS 默认 icon_primary 一致。
   */
  static iconPrimary(isDark: boolean): string { return isDark ? '#F0F2F5' : '#1A1A1A'; }
  // 分割线
  static divider(isDark: boolean): string { return isDark ? '#2E2E33' : '#EBEDF0'; }
  // 应用强调色：默认微博红，可由「软件设置」中的主题色即时覆盖。
  static brand(): string { return currentAccent(); }
  /**
   * 分段胶囊选中文字色（沉浸光感恒开启）：
   * 选中为浅蓝官方材质胶囊 → 亮色深字 / 深色白字
   */
  static segActiveText(isDark: boolean): string {
    return isDark ? '#FFFFFF' : '#000000';
  }
  // 强调背景
  static brandBg(isDark: boolean): string {
    const accent: string = Theme.brand();
    if (accent === '#007DFF') {
      return isDark ? '#1F3555' : '#E7F2FF';
    }
    if (accent === '#7856FF') {
      return isDark ? '#33295A' : '#F0ECFF';
    }
    if (accent === '#00A870') {
      return isDark ? '#1E4438' : '#E4F7EF';
    }
    if (accent === '#F59E0B') {
      return isDark ? '#4A391D' : '#FFF4DC';
    }
    return isDark ? '#45232A' : '#FCECEE';
  }
  // 置顶徽章（柔红底白字，深色降一档明度避免刺眼；与精品蓝 badge 语义区分）
  static badgePin(isDark: boolean): string { return isDark ? '#E06161' : '#FF8A8A'; }
  static glassLine(isDark: boolean): string { return isDark ? '#4AFFFFFF' : '#80FFFFFF'; }
  // 危险色
  static danger(): string { return '#F5222D'; }
  // 成功色
  static success(): string { return '#52C41A'; }

  // 用户等级徽章色：贴吧官方 18 级（1-3 绿 / 4-9 蓝 / 10-14 红 / 15-18 黄）
  static levelColor(level: number): string {
    if (level >= 15) return '#FFC107';
    if (level >= 10) return '#F44336';
    if (level >= 4) return '#2196F3';
    return '#4CAF50';
  }

  // ========== 手动玻璃兜底（低版本 API 23~25 / 材质范围外 / 材质渲染失败时）==========
  // ========== 手动玻璃降级（页面主体元素无真材质，须视觉兜底）==========
  // 官方范围约束：沉浸光感（systemMaterial/ImmersiveMaterial）仅弹窗类组件、
  // Slider/Toggle/Select，及 Navigation 标题栏 / Tabs(BarPosition.End) 底部 TabBar 内生效。
  // 页面主体元素（顶部分段胶囊、圆形按钮等）挂材质不渲染（Material inactive: out of scope），
  // 只能用半透明 manualGlass 背景 + 白描边模拟玻璃观感。
  // 调用方式：.backgroundColor(Theme.manualGlass(isDark)).border({...})
  //          .backgroundEffect(ImmBlur.X()).systemMaterial(ImmMaterial.X())
  /**
   * 手动玻璃降级总开关。
   * 若某日官方材质在页面主体所有区域稳定渲染，可将此改为 false，
   * 所有降级背景/描边立即变为全透明，还原纯净官方材质效果。
   */
  static readonly GLASS_FALLBACK_ENABLED: boolean = true;

  /**
   * 手动玻璃背景色（页面主体元素的玻璃兜底）。
   * - 普通：亮色用浅蓝灰（白卡上明显色差），深色用半透明白。
   * - active=true：选中态用半透明品牌蓝玻璃。
   */
  static manualGlass(isDark: boolean, active: boolean = false): string {
    if (!Theme.GLASS_FALLBACK_ENABLED) {
      return '#00000000';
    }
    if (active) {
      return isDark ? '#993173FF' : '#803173FF';
    }
    return isDark ? '#3DFFFFFF' : '#E6F0F4F8';
  }
  /**
   * 吸顶切换钮玻璃底（HomeTab 顶栏推荐/关注/搜索共用）。
   * 参考底栏形态：无任何彩色胶囊底，仅一层低不透明度中性玻璃（黑/白），
   * 让 backgroundBlurStyle 真磨砂透过内容可见；选中/未选中完全由文字强调色 + 字重表达。
   */
  static segGlass(isDark: boolean, active: boolean): string {
    if (!Theme.GLASS_FALLBACK_ENABLED) {
      return '#00000000';
    }
    // 亮色不留实白底，避免白夹层盖住真模糊；状态由强调色文字 + 阴影强度承担
    return active
      ? (isDark ? '#4D1A1A1E' : '#00000000')
      : (isDark ? '#2E1A1A1E' : '#00000000');
  }
  /**
   * 吸顶切换钮玻璃浮起阴影：中性色（不染蓝），选中态略重抬起，未选中/圆钮轻投影，
   * 与描边一起保住胶囊层次感。仅真模糊路径使用。
   */
  static segGlassShadow(isDark: boolean, active: boolean): GlassShadowOptions {
    if (!Theme.GLASS_FALLBACK_ENABLED) {
      return IMM_EMPTY_SHADOW;
    }
    return active
      ? (isDark
        ? { radius: 12, color: '#66000000', offsetY: 3 }
        : { radius: 12, color: '#3D000000', offsetY: 3 })
      : (isDark
        ? { radius: 10, color: '#40000000', offsetY: 2 }
        : { radius: 10, color: '#26000000', offsetY: 2 });
  }
  /**
   * 底部悬浮排序胶囊（正序/倒序、只看全部）底色。
   * 与 manualGlass 的区别：不透明度刻意压到极低（普通约 5~8%、选中约 10~15%），
   * 只留极淡的底色提示状态，让楼层/回复文字整条滑过胶囊后方时仍能透出，不会整块消失。
   * active 状态主要靠文字颜色和字重区分，不再依赖高不透明蓝底。
   */
  static bottomSegGlass(isDark: boolean, active: boolean): string {
    if (!Theme.GLASS_FALLBACK_ENABLED) {
      return '#00000000';
    }
    return active ? (isDark ? '#263173FF' : '#1A3173FF') : (isDark ? '#0DFFFFFF' : '#0DF0F4F8');
  }
  /**
   * 玻璃描边（页面主体元素玻璃兜底）。
   * 白高光边（叠在官方材质上，做玻璃上缘）。
   */
  static manualGlassBorder(): string {
    if (!Theme.GLASS_FALLBACK_ENABLED) {
      return '#00000000';
    }
    return '#22FFFFFF';
  }

  /**
   * 玻璃浮起阴影（沉浸光感恒开启路径）。
   * 恒返回全零阴影 —— ImmersiveMaterial 已带 applyShadow，再叠会成双影。
   */
  static glassShadowStyle(): GlassShadowOptions {
    return IMM_EMPTY_SHADOW;
  }
  /** 手动玻璃顶部高光线（1.5vp 用 linearGradient 模拟） */
  static manualGlassHighlight(isDark: boolean): string {
    return isDark ? '#3DFFFFFF' : '#80FFFFFF';
  }
}

/**
 * 获取当前全局深色模式
 */
export function isDarkMode(): boolean {
  return _globalIsDark;
}

/**
 * 全局字号缩放：根据当前字号级别计算实际字号。
 * 所有页面应使用 Theme.fs(baseSize) 代替硬编码 .fontSize()。
 */
export function fs(baseFontSize: number, scale: number = AppStorage.get<number>('fontScale') ?? 1.0): number {
  return Math.round(baseFontSize * scale);
}

/**
 * 冷启动入口：仅把目标深色态写入模块级变量，不下发系统。
 *
 * 冷启动时 _globalIsDark 本就由 EntryAbility.onCreate 在首帧渲染前 fire-and-forget 异步
 * 读 cache 后调 applicationContext.setColorMode(...) 把 Configuration 同步到目标档；
 * Index.aboutToAppear 再走一遍只会重复触发整树重建，重入导致闪退。
 * 因此冷启动二期（Index.aboutToAppear 阶段）只同步应用内状态，系统层不动。
 */
export function initDarkMode(isDark: boolean): void {
  _globalIsDark = isDark;
}

/**
 * 系统 Configuration 变化回调专用入口：仅写模块变量 + 递增 darkTick，**不**调 setColorMode。
 *
 * 关键设计：onConfigurationUpdate 里调 setColorMode 是反向拉回 / 重入循环的最大来源（setColorMode
 * 异步生效期间回调里 Configuration.colorMode 仍是旧值，按旧值再 setColorMode 会把档位拉回）。
 * 因此「系统切色」场景下只同步应用内状态，Configuration 本身已是新值（onConfigurationUpdate
 * 收到的就是新值），官方槽位自动翻档 —— 不需要也不应该再调 setColorMode。
 *
 * 与 setDarkMode 的区别：
 * - setDarkMode：用户主动切换入口（ForumsTab/我的/月亮钮），会调 setColorMode 主动下发
 * - syncDarkFromConfig：系统 Configuration 变化回调专用，只同步应用内状态
 */
export function syncDarkFromConfig(sysDark: boolean): void {
  _globalIsDark = sysDark;
}

/**
 * 「从手动档切到跟随系统档」专用入口：
 * - 主动调 setColorMode(NOT_SET) 把 Application Configuration 重置为跟随系统档
 *   （Configuration.colorMode 立即等于系统当前档，systemMaterial 立即按系统档渲染）
 * - 同步 _globalIsDark + 状态栏
 * - **不**调 setColorMode(DARK/LIGHT) 锁死到目标档——跟随系统档要求 Configuration 永远 NOT_SET
 *
 * ⚠️ HarmonyOS 设计限制（HTTPS 6.1 §2.1）：setColorMode(NOT_SET) 是「半重置」——
 *   Configuration.colorMode 立即等于系统档，但「已锁死」标记无法清除，
 *   未来 onConfigurationUpdate 仍可能静默。**用户仍需杀进程重进**才能让「实时跟档」行为完全恢复。
 *   不过本次重置后 Configuration.colorMode 已等于系统档 —— ForumsTitleBar / HomeTitleBar 等
 *   官方槽位的 systemMaterial 与 $r('sys.color.font_primary') 立即按系统档渲染。
 */
export function resetConfigurationToFollowSystem(): void {
  try {
    const ctx = AppStorage.get<common.UIAbilityContext>('abilityContext');
    if (!ctx) {
      return;
    }
    // 1. 把 Configuration 重置为跟随系统档（视觉上立即恢复跟随系统）
    ctx.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    // 2. 标记"尚未下发 manual 档"——后续 setDarkMode 会再设一次 DARK/LIGHT（手动档用）
    _systemSyncedDark = -1;
    // 3. 同步状态栏内容色（按当前系统档取色）
    const sysDark: boolean =
      ctx.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    const mainWindow = AppStorage.get<window.Window>('mainWindow');
    if (mainWindow) {
      mainWindow.setWindowSystemBarProperties({
        statusBarColor: '#00000000',
        navigationBarColor: '#00000000',
        statusBarContentColor: sysDark ? '#FFFFFF' : '#1A1A1A',
        navigationBarContentColor: sysDark ? '#FFFFFF' : '#1A1A1A',
      }).catch(() => {
      });
      // 窗口底色跟档：从手动档切回跟随系统后按系统档复位（取值与 Theme.bg 一致；同步 void 签名）
      mainWindow.setWindowBackgroundColor(sysDark ? '#101114' : '#F2F4F7');
    }
    console.info('Theme', 'resetConfigurationToFollowSystem: current sysDark=' + (sysDark ? '1' : '0'));
  } catch (systemError) {
    // 静默失败不影响应用内状态
  }
}

/** 已下发给系统的深色档（-1 = 尚未下发过）。setColorMode 会触发 Configuration 变化，
 *  进而触发 EntryAbility.onConfigurationUpdate 回调，后者又会调本函数 —— 没有幂等短路会形成
 *  setColorMode → onConfigurationUpdate → setColorMode 的重入循环导致闪退。 */
let _systemSyncedDark: number = -1;

/** 设置全局深色模式（用户主动切换入口）。
 *
 * 除写入模块级变量供自绘组件读取外，同步把深色态下发给系统，修「应用内软切深色、官方槽位不反色」与
 * 「重启后深色不完全」（Configuration 不跟随导致顶栏 systemMaterial / 状态栏文字色按旧档渲染）：
 * 1. `applicationContext.setColorMode(...)` 让 `Configuration.colorMode` 跟随变化，于是
 *    Navigation/NavDestination 标题栏与 Tabs 底栏里的 `systemMaterial`、以及
 *    `$r('sys.color.font_primary')` / `$r('sys.color.icon_primary')` 等系统反色资源自动翻档。
 * 2. 同步状态栏/导航栏内容色——EntryAbility 冷启动写过浅色档，不覆盖则深色下始终是黑字。
 *
 * 幂等靠 _systemSyncedDark：Configuration 已经是目标档时跳过 setColorMode，避免重入闪退。
 *
 * 失败不阻断应用内主题切换（自绘配色仍由 `_globalIsDark` 保证）。
 */
export function setDarkMode(isDark: boolean): void {
  const target: number = isDark ? 1 : 0;
  // 双条件幂等：模块变量与系统档都已同步到目标值才短路。
  // 单独看 _systemSyncedDark 不够 —— setColorMode 是异步的，回调里 Configuration 尚未真正变更时
  // _systemSyncedDark 已被标记，会出现「标记说同步了但实际没变」的误判窗口。
  if (_globalIsDark === isDark && _systemSyncedDark === target) {
    return;
  }
  _globalIsDark = isDark;
  try {
    const ctx = AppStorage.get<common.UIAbilityContext>('abilityContext');
    if (!ctx) {
      return;
    }
    _systemSyncedDark = target;
    // 关键：先 setColorMode(NOT_SET) 把 Configuration 重置为「跟随系统」（让 Configuration.colorMode
    // 立即等于系统当前档，visual 上恢复跟随系统），再 setColorMode(target) 锁死到目标档。
    // 否则用户场景「之前手动切过色 → Configuration 被锁死在 LIGHT → 系统切深色时 Configuration 仍 LIGHT →
    // systemMaterial 渲染浅色档，顶栏与卡片不同步」。
    // setColorMode(NOT_SET) 是「半重置」（web 文章 6.1 §2.1）：Configuration.colorMode 立即等于系统档，
    // 但「已锁死」标记仍在，未来 onConfigurationUpdate 仍静默 —— 所以下面 setColorMode(target) 仍需主动锁。
    ctx.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    ctx.getApplicationContext().setColorMode(isDark
      ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK
      : ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
    const mainWindow = AppStorage.get<window.Window>('mainWindow');
    if (mainWindow) {
      mainWindow.setWindowSystemBarProperties({
        statusBarColor: '#00000000',
        navigationBarColor: '#00000000',
        statusBarContentColor: isDark ? '#FFFFFF' : '#1A1A1A',
        navigationBarContentColor: isDark ? '#FFFFFF' : '#1A1A1A',
      }).catch(() => {
      });
      // 窗口底色跟档：冷启动兜底（EntryAbility）把主窗底色设过档，这里随应用内手动切换同步
      // 复位，避免切回浅色后窗口透出深底。取值与 Theme.bg 一致；同步 void 签名，异常由外层
      // try/catch 兜底。
      mainWindow.setWindowBackgroundColor(isDark ? '#101114' : '#F2F4F7');
    }
  } catch (systemError) {
    // 系统侧同步失败不影响应用内主题切换；回退标记以便下次重试
    _systemSyncedDark = -1;
  }
}

/**
 * 间距令牌接口
 */
export interface SpacingToken {
  xs: number;
  sm: number;
  md: number;
  lg: number;
  xl: number;
}

/**
 * 通用圆角、间距令牌（vp）
 */
export const Spacing: SpacingToken = {
  xs: 4,
  sm: 8,
  md: 12,
  lg: 16,
  xl: 20,
};

/**
 * 圆角令牌接口
 */
export interface RadiusToken {
  sm: number;
  md: number;
  lg: number;
  /** 帖子及内容卡片统一外圆角。 */
  postCard: number;
  full: number;
}

export const Radius: RadiusToken = {
  sm: 8,
  md: 12,
  lg: 16,
  postCard: 26,
  full: 999,
};

/**
 * 断点令牌（vp）—— 平板适配文档 §4.6 H-B「断点与几何常量收口」的唯一来源。
 * - sm = 600：窄窗门槛（折叠屏折叠态 / 平板分屏 / 自由多窗拖窄）
 * - md = 840：大屏形态门槛（宽屏档，宿主底栏与各页共用）
 * - lg = 1440：预留档
 * 说明：形态判定还要先过「是否大屏形态设备」闸门（deviceInfo.deviceType / display.isFoldable），
 *      只靠宽度会把手机横屏（约 780vp ≥ 600）误判为大屏。
 */
export interface BreakpointToken {
  sm: number;
  md: number;
  lg: number;
}

export const Breakpoint: BreakpointToken = {
  sm: 600,
  md: 840,
  lg: 1440,
};

// ========== 阔直屏形态判定（docs/TiebaPura阔直屏适配.md §二）==========

/** 阔直屏型号兜底（只做兜底、不做主判据：同设备有 AL00/TN00/TL00 等市场变体，硬编码每出新机都要发版） */
const WIDE_BAR_MODEL: string = 'VOL-AL00';

/**
 * Pura X 折叠屏展开态按阔直屏档的型号清单（2026-09-15 用户指定）：
 * VDE-AL00 / VDE-AL10，展开 6.3" 16:10（2120×1320）。
 * 折叠态外屏 ~21:9 窄屏，**不**按阔直屏（竖 2 列会拥挤）——展开按阔直屏档、折叠回落手机档
 * （isWideFormDevice 对折叠屏恒 true → 各页宽度闸门把折叠态拦回 1 列，与既有平板路径一致）。
 */
const WIDE_BAR_FOLD_MODELS: string[] = ['VDE-AL00', 'VDE-AL10'];

function isPuraXFoldModel(): boolean {
  return WIDE_BAR_FOLD_MODELS.indexOf(deviceInfo.productModel) >= 0;
}

/** 判定探针日志只打一次（isWideBarDevice 在渲染路径被高频调用，不能刷屏） */
let _wideBarProbeLogged: boolean = false;

/**
 * 阔直屏判定（§2.1）：Pura X 展开态 → 直板非折叠闸门 → 型号兜底 → 物理长宽比带。
 * - 主判据 = 能力带：deviceType==='phone' && !isFoldable && 长边/短边 ∈ (1.4, 1.85)
 *   （16:9.5 ≈ 1.684 居中；普通手机 ≥ 2.1、平板 1.33~1.6 被 deviceType 挡）
 * - Pura X（VDE-AL00/AL10）：**展开态**按阔直屏档（16:10 大屏），折叠态返回 false 回落手机档
 *   —— 本函数在渲染路径被实时调用，折叠/展开切换后由各页 onAreaChange / display.on('change')
 *   触发重渲染自动翻档；非展开的 HALF_FOLDED 不算（用户指定仅展开态）
 * - 比例用物理像素（密度无关，旋转不变）；异常一律返回 false（安全方向 = 手机档）
 * - 历史注：曾附「forceWideBar 调试开关」（无真机期验证用），2026-09-15 随云调试真机验证
 *   通过后移除（设置页开关 + 持久化恢复 + 本函数开关段一并拆除）
 */
export function isWideBarDevice(): boolean {
  try {
    if (display.isFoldable()) {
      // 折叠屏只认 Pura X 展开态与 Pura X Max（阔折叠）展开态；其它折叠设备维持既有平板档不变。
      // Pura X Max 展开态按阔直屏基础档（7.7" √2 屏，竖 1 / 横 3 同口径），差异点（回复 2 列、
      // 宫格 72、底栏/弹窗 400）由调用方以 isPuraXMaxDevice() 前置分支单独拨档。
      const hit: boolean = (isPuraXFoldModel() || isPuraXMaxDevice())
        && display.getFoldStatus() === display.FoldStatus.FOLD_STATUS_EXPANDED;
      logWideBarProbe(0, hit);
      return hit;
    }
    if (deviceInfo.deviceType !== 'phone') {
      return false;
    }
    if (isPuraXFoldModel() || deviceInfo.productModel === WIDE_BAR_MODEL) {
      // Pura X 折叠态已在上一个分支返回 false，这里兜上报异常的非折叠变体
      logWideBarProbe(0, true);
      return true;
    }
    const d: display.Display = display.getDefaultDisplaySync();
    const w: number = d.width;
    const h: number = d.height;
    if (w <= 0 || h <= 0) {
      return false;
    }
    const ratio: number = Math.max(w, h) / Math.min(w, h);
    const hit: boolean = ratio > 1.4 && ratio < 1.85;
    logWideBarProbe(ratio, hit);
    return hit;
  } catch (e) {
    return false;
  }
}

/**
 * 阔直屏**直板**判定 —— 与 isWideBarDevice() 的折叠分支严格互斥，只认 `!isFoldable() && phone`：
 * - 主判据：物理长宽比带 (1.4, 1.85)（与 isWideBarDevice 同口径，密度无关、旋转不变）
 * - 型号兜底：WIDE_BAR_MODEL（VOL-AL00）
 * - Pura X（VDE-AL00/AL10）、Pura X Max 展开、大折叠展开、平板**一律 false**。这里刻意**不**复用
 *   isWideBarDevice 里那条 `isPuraXFoldModel()` 异常兜底（HAL 误报非折叠），保证「不做 Pura X」语义干净。
 *
 * 用途：**只**服务「关闭自动旋转」开关（使用习惯页显隐 + 宿主旋转下发），不参与列数/宽度档位判定
 * （那些仍走 isWideBarDevice()）。直板形态判定在整个 App 生命周期内稳定，不存在折叠态来回翻档问题。
 */
export function isWideBarFlatDevice(): boolean {
  try {
    if (display.isFoldable()) {
      return false;
    }
    if (deviceInfo.deviceType !== 'phone') {
      return false;
    }
    if (deviceInfo.productModel === WIDE_BAR_MODEL) {
      return true;
    }
    const d: display.Display = display.getDefaultDisplaySync();
    const w: number = d.width;
    const h: number = d.height;
    if (w <= 0 || h <= 0) {
      return false;
    }
    const ratio: number = Math.max(w, h) / Math.min(w, h);
    return ratio > 1.4 && ratio < 1.85;
  } catch (e) {
    return false;
  }
}

/** 首次判定时打一条探针日志：真机到手第一时间核对 productModel / 比例，校准阈值（阔直屏文档 §2.4-2） */
function logWideBarProbe(ratio: number, hit: boolean): void {
  if (_wideBarProbeLogged) {
    return;
  }
  _wideBarProbeLogged = true;
  try {
    const d: display.Display = display.getDefaultDisplaySync();
    const r: string = ratio > 0 ? ratio.toFixed(3) : 'model-override';
    console.info(`[WIDEBAR] model=${deviceInfo.productModel} type=${deviceInfo.deviceType} `
      + `foldable=${display.isFoldable()} px=${d.width}x${d.height} ratio=${r} hit=${hit}`);
  } catch (e) {
    // 日志失败不影响判定
  }
}

// ========== Pura X Max 阔折叠判定（2026-09-17 用户立项）==========

/** Pura X Max 判定探针日志只打一次（isPuraXMaxDevice 在渲染路径被高频调用） */
let _puraXMaxProbeLogged: boolean = false;

/**
 * Pura X Max（阔折叠）展开态判定：7.7" 内屏 2584×1828，比例 √2 ≈ 1.414（类 A4 纸黄金比例）。
 * - 主判据 = 比例带 (1.36, 1.48)：居中 √2；与 Mate X3/X5 展开内屏（≈1.34）隔 ≥0.02、
 *   与 Mate X 大折叠带 (1.0,1.25)、Pura X（VDE 展开 2120×1320 ≈ 1.606）天然隔离，
 *   且仅折叠屏 + 展开态命中（折叠态外屏 1848×1264 ≈ 1.462 虽落带内，但非 EXPANDED 直接 false）
 * - 不硬编码型号（同阔直屏教训：变体型号每出新机都要发版）；真机到手按 [PURAXMAX] 探针
 *   核对 productModel / 实测比例，必要时补型号兜底
 * - 折叠态 / HALF_FOLDED / 异常一律 false（安全方向 = 手机档）；
 *   展开↔折叠切换由各页 onAreaChange / display.on('change') 触发重渲染自动翻档
 */
export function isPuraXMaxDevice(): boolean {
  try {
    if (!display.isFoldable()) {
      return false;
    }
    if (display.getFoldStatus() !== display.FoldStatus.FOLD_STATUS_EXPANDED) {
      return false;
    }
    const d: display.Display = display.getDefaultDisplaySync();
    const w: number = d.width;
    const h: number = d.height;
    if (w <= 0 || h <= 0) {
      return false;
    }
    const ratio: number = Math.max(w, h) / Math.min(w, h);
    const hit: boolean = ratio > 1.36 && ratio < 1.48;
    logPuraXMaxProbe(ratio, hit);
    return hit;
  } catch (e) {
    return false;
  }
}

/** 首次判定时打一条探针日志：真机到手第一时间核对 productModel / 实测比例，校准比例带 */
function logPuraXMaxProbe(ratio: number, hit: boolean): void {
  if (_puraXMaxProbeLogged) {
    return;
  }
  _puraXMaxProbeLogged = true;
  try {
    const d: display.Display = display.getDefaultDisplaySync();
    console.info(`[PURAXMAX] model=${deviceInfo.productModel} type=${deviceInfo.deviceType} `
      + `foldable=${display.isFoldable()} px=${d.width}x${d.height} ratio=${ratio.toFixed(3)} hit=${hit}`);
  } catch (e) {
    // 日志失败不影响判定
  }
}

// ========== 大折叠形态判定（docs/TiebaPura大折叠适配.md §二，2026-09-15）==========

/** 大折叠判定探针日志只打一次（isLargeFoldDevice 在渲染路径被高频调用） */
let _largeFoldProbeLogged: boolean = false;

/**
 * 大折叠判定（Mate X 系列大折叠展开态，2026-09-15 用户立项）：折叠屏 + 展开态 + 非 Pura X + 近方形比例带。
 * - 主判据 = 比例带：Mate X7 展开 2416×2210（≈8:7.3），长宽比 ≈1.093，比例带取 (1.0, 1.25)；
 *   与阔直屏比例带 (1.4, 1.85)、普通手机 (≥2.1) 均隔出 ≥0.3 余量；不硬编码型号（同阔直屏教训：
 *   同设备有 AL00/TL00 等变体，硬编码每出新机都要发版），真机到手按 [LARGEFOLD] 探针校准后可补型号兜底
 * - 折叠态：外屏 ~21:9（比例 ≥2.1 不命中比例带）且**非展开态直接 false** → 自动回落手机档（既有闸门拦回 1 列）；
 *   HALF_FOLDED 不算（仅展开态，与 Pura X 阔直屏档同口径）
 * - 本函数在渲染路径被实时调用，折叠/展开切换后由各页 onAreaChange / display.on('change') 触发重渲染自动翻档；
 *   异常一律返回 false（安全方向 = 既有平板档，isWideFormDevice 对折叠屏恒 true 兜底）
 */
export function isLargeFoldDevice(): boolean {
  try {
    if (!display.isFoldable() || isPuraXFoldModel()) {
      return false;
    }
    if (display.getFoldStatus() !== display.FoldStatus.FOLD_STATUS_EXPANDED) {
      return false;
    }
    const d: display.Display = display.getDefaultDisplaySync();
    const w: number = d.width;
    const h: number = d.height;
    if (w <= 0 || h <= 0) {
      return false;
    }
    const ratio: number = Math.max(w, h) / Math.min(w, h);
    const hit: boolean = ratio > 1.0 && ratio < 1.25;
    logLargeFoldProbe(ratio, hit);
    return hit;
  } catch (e) {
    return false;
  }
}

/** 首次判定时打一条探针日志：真机到手第一时间核对 productModel / 实测比例，校准比例带（阔直屏 §2.4-2 同款） */
function logLargeFoldProbe(ratio: number, hit: boolean): void {
  if (_largeFoldProbeLogged) {
    return;
  }
  _largeFoldProbeLogged = true;
  try {
    const d: display.Display = display.getDefaultDisplaySync();
    console.info(`[LARGEFOLD] model=${deviceInfo.productModel} type=${deviceInfo.deviceType} `
      + `px=${d.width}x${d.height} ratio=${ratio.toFixed(3)} hit=${hit}`);
  } catch (e) {
    // 日志失败不影响判定
  }
}

/**
 * 自绘弹窗浮层卡片限宽（2026-09-15 用户拍板「弹窗不拉伸」）：
 * - 大折叠展开态下，页面主体自绘确认卡从「通栏 calc(100% - 48vp)」收到 **400vp 封顶**
 *   （与各页 CustomDialog dialogCardWidth 同口径，屏宽不足 448 时按 屏宽−48 取值、下限 200）；
 * - 其它形态（手机 / 平板 / 2in1 / 阔直屏 / 大折叠折叠态）原样返回 calc 字符串，逐像素不变。
 * 调用点：各页自绘浮层确认卡（ThreadDetail / SubPostDetail / ForumsTab / FollowList / BlacklistManager）。
 * 注：bindSheet 半模态 SheetOptions 无 width 字段，宽度由系统按设备规格决定，不在本函数管辖内。
 */
export function overlayCardWidth(): string | number {
  // Pura X Max（阔折叠展开 ~860vp 宽）与底栏同口径：400 封顶不拉伸（同大折叠 2026-09-15 拍板）
  if (!isLargeFoldDevice() && !isPuraXMaxDevice()) {
    return 'calc(100% - 48vp)';
  }
  try {
    const d: display.Display = display.getDefaultDisplaySync();
    const w: number = d.densityPixels > 0
      ? Math.min(d.width, d.height) / d.densityPixels - 48
      : 400;
    return w > 400 ? 400 : (w > 200 ? w : 200);
  } catch (e) {
    return 400;
  }
}

/**
 * 大屏形态设备（平板 / 2in1 / 折叠屏 / 阔直屏）单一来源（阔直屏文档 §2.2 收口）：
 * 各页原 `deviceType==='tablet' || '2in1' || isFoldable()` 三行重复表达式统一改调本函数。
 * 折叠屏 deviceType 为 'phone'，必须单独用 isFoldable 识别；阔直屏为直板机，靠 isWideBarDevice 识别。
 */
export function isWideFormDevice(): boolean {
  try {
    if (deviceInfo.deviceType === 'tablet'
      || deviceInfo.deviceType === '2in1'
      || display.isFoldable()) {
      return true;
    }
  } catch (e) {
    // 取值失败继续走阔直屏判定（其内部自带 try/catch）
  }
  return isWideBarDevice();
}

/**
 * 「列数调整」（个性化 → 列数调整）当前档位：
 * 0 = 默认（按机型自动适配横竖屏）/ 1 = 竖二横三 / 2 = 竖三横四。
 * 读 AppStorage（UsageHabitsManager.init 冷启动恢复 + setColumnMode 写入）。
 */
export function readColumnMode(): number {
  const v: number = AppStorage.get<number>('columnMode') ?? 0;
  return (v === 1 || v === 2) ? v : 0;
}

/** 「列数调整」档位文案（设置项右侧状态 + 弹窗选项共用） */
export function columnModeLabel(mode: number): string {
  if (mode === 1) {
    return '竖二横三';
  }
  if (mode === 2) {
    return '竖三横四';
  }
  return '默认';
}

/**
 * 是否「大屏形态」——「列数调整」**仅**在此生效：平板 / 2in1 / 阔直屏（Pura X 直板与展开、Pura X Max 展开）
 * / 大折叠展开。手机档与窄窗（各页 pageWidth < 600 闸门已提前返回）一律不受影响。
 * 入参传各页已判好的 isWideFormDevice 字段，避免重复取值。
 */
export function isLargeScreenForm(isWideForm: boolean): boolean {
  return isWideForm || isWideBarDevice() || isLargeFoldDevice();
}

/**
 * 阔直屏「全屏」白名单 —— 「列数调整」在阔直屏竖屏下生效的**唯一放行口**（2026-09-18 用户要求）。
 *
 * 背景：8 个多列页列数函数首行都有「窗口宽 < 600 → 回落手机单列档」的自由小窗 / 分屏闸门。
 * 但阔直屏档设备**竖屏全屏**的窗口宽只有约 440vp（屏短边 1320px ÷ density；16:9.5 的
 * Pura X View（VOL-AL00，2232×1320）与 16:10 的 Pura X 展开态同值），远小于 600 →
 * 被闸门误判成自由小窗，于是「列数调整」在这类设备竖屏下**永不生效**（横屏窗口宽 ≥600 才命中）。
 *
 * 判据（必须同时满足）：
 * ① 阔直屏档设备（isWideBarDevice：型号白名单 VOL-AL00 / 物理比例带 (1.4,1.85)）；
 * ② 窗口宽 ≈ 屏短边 vp —— 即窗口占满屏宽（全屏）；自由小窗与左右分屏的窗口宽必然小于屏短边，
 * 故它们仍返回 false，**2026-09-17「小窗 <600 一律回落 1 列」的结论不被破坏**。
 *
 * 入参传各页已维护的窗口实宽（pageWidth，vp）。未就绪 / 异常一律 false（安全方向 = 维持原闸门行为）。
 */
export function isWideBarFullscreen(pageWidth: number): boolean {
  if (pageWidth <= 0) {
    return false;
  }
  if (!isWideBarDevice()) {
    return false;
  }
  try {
    const d: display.Display = display.getDefaultDisplaySync();
    const shortEdge: number = Math.min(d.width, d.height) / d.densityPixels;
    // 容差 24vp：仅吸收 vp 取整误差；自由多窗即使拉到极宽也仍小于该值（分屏为屏宽一半）
    return shortEdge > 0 && pageWidth >= shortEdge - 24;
  } catch (e) {
    return false;
  }
}

/**
 * 「列数调整」覆盖值：mode=1 → 竖 2 / 横 3；mode=2 → 竖 3 / 横 4。
 * 返回 0 表示「不覆盖」（默认档）→ 调用方继续走原自动适配分支（逐像素零回归）。
 */
export function overrideColumns(mode: number, isLandscape: boolean): number {
  if (mode === 1) {
    return isLandscape ? 3 : 2;
  }
  if (mode === 2) {
    return isLandscape ? 4 : 3;
  }
  return 0;
}

/**
 * 顶部满宽渐显带的平板收窄比例（2026-09-13，用户反馈平板竖屏下各页渐显覆盖到第一个卡片中部）：
 * 平板 / 大屏形态下渐显只覆盖顶部按钮与标题（`coverVp` = 该页顶部固定区高度，一般为顶栏 98），
 * 手机维持原 15% 比例。分母取**屏幕长边**（竖屏视口高的稳定来源，旋转不漂移）；
 * display 未就绪 / 取值失败时回退手机比例（0.15，安全方向——宁可略深也不可全实遮罩失效）。
 * 用法：各页 `BottomFadeOverlay` 的中间渐变 stop 写 `tabletTopFadeStop(该页顶部固定区高度)`。
 */
export function tabletTopFadeStop(coverVp: number): number {
  const wide: boolean = isWideFormDevice();
  if (!wide) {
    return 0.15;
  }
  try {
    const d: display.Display = display.getDefaultDisplaySync();
    const longEdge: number = Math.max(d.width, d.height) / d.densityPixels;
    if (longEdge <= 0) {
      return 0.15;
    }
    return Math.min(0.15, coverVp / longEdge);
  } catch (e) {
    return 0.15;
  }
}

/** 宿主底部悬浮底栏几何令牌（vp，见 §4.6 H-B / H-C：维持 480 封顶，零改动） */
export interface DockToken {
  height: number;
  radius: number;
  bottomMargin: number;
  maxWidthWide: number;
  tabInset: number;
}

export const Dock: DockToken = {
  height: 74,
  radius: 37,
  bottomMargin: 30,
  maxWidthWide: 480,
  tabInset: 24,
};

/** 单列页 / 二级页内容限宽令牌（宿主自身不使用，见 §4.7） */
export interface ContentToken {
  maxWidth: number;
}

export const Content: ContentToken = {
  maxWidth: 1000,
};

/**
 * 卡片列数全局标记键（AppStorage / @StorageProp）。
 * 写入纪律（§6.1 D1 / D6，手机零回归关键）：**必须无条件写**（单列档也写 1），
 * 不允许「只在多列时写」——该标记是全局单值，被多个页面的 ThreadCard 共享，
 * 任一页残留 2 / 3 会让别的页在手机上按多列几何渲染（必然触发场景：折叠屏展开 → 折叠）。
 */
export const CARD_COLUMNS_KEY: string = 'cardColumns';
