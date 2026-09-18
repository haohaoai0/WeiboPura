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

/**
 * Search.ets —— 全吧搜索（搜吧 / 搜贴 / 搜人）
 *
 * 首页右上角搜索入口的新落地页：直接检索整个百度贴吧内容。
 * 三个模块复用同一 PC 网页全站搜索协议（TiebaService.searchForumGlobal /
 * searchPostGlobal / searchUserGlobal，aiotieba 同款签名）。
 *
 * UI 语言遵循项目规范：
 *  - 顶部悬浮栏（返回钮 + 玻璃搜索框）
 *  - 底部悬浮模块栏（搜吧 / 搜贴 / 搜人，与首页底栏同款沉浸光感：留边 24 / 圆角 37 / 真模糊磨砂）
 *  - 推荐位大卡 / 相关吧列表卡等全部使用 Theme 玻璃/卡片体系
 */
import { curves } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { display } from '@kit.ArkUI';
import { Theme, Radius, Breakpoint, fs, isDarkMode, ImmMaterial, MaterialManager, isWideBarDevice, isLargeFoldDevice, isWideFormDevice as detectWideFormDevice, readColumnMode, overrideColumns, isLargeScreenForm, isWideBarFullscreen } from '../common/Theme';
import { TiebaService } from '../service/TiebaService';
import {
  GlobalForumResult, GlobalForumSearchData, GlobalPostResult, GlobalPostSearchData,
  GlobalUserResult, GlobalUserSearchData
} from '../model/DataModel';
import { LoadingView, EmptyView, ErrorView } from '../components/CommonComponents';

const MODULE_LABELS: string[] = ['搜吧', '搜贴', '搜人'];
// 顶部悬浮栏整体高度（状态栏留位 + 搜索行），首屏内容让位基准（三段胶囊已下移为底部模块栏，原 154 - 胶囊行 40）
const HEADER_TOP_SPACE: number = 114;
// 底部悬浮模块栏让位：栏顶距物理底 = 30(margin) + 74(栏高) = 104，再加内容滚出余量
const BOTTOM_BAR_SPACE: number = 130;
// 顶部官方槽位开关（§6.10 同机制）：true → 顶栏整行搬进 Navigation 的 title 槽位吃官方沉浸材质；
// false → 回退改造前的页面主体悬浮栏（FloatingHeader，自绘真模糊玻璃，几何同源）
const SEARCH_OFFICIAL_TITLE_BAR: boolean = true;
// 槽位高度 = 44(状态栏让位) + 40(搜索行高) + 14(底部呼吸) = 98，与旧 FloatingHeader 的 padding 逐项对齐
const SEARCH_TITLE_BAR_HEIGHT: number = 98;
// 头像占位色板（按名称散列取色）
const AVATAR_COLORS: string[] = ['#3173FF', '#8A5CF6', '#2CB883', '#F0576B', '#FF9F0A', '#37A2FF', '#7C62FF', '#FF6FB4'];

@Entry
@Component
struct GlobalQueryPage {
  @StorageLink('fontScale') fontScale: number = 1.0;
  @State fontSizeTick: number = 0;
  // 「列数调整」档位广播（2026-09-18，个性化 → 列数调整）：@Watch 回写本地档位 → 列数函数按新档返回并强制回到列表顶部
  // （离屏期间 @StorageLink 同步不重绘，故用 tick + 本地 @State 兜底，同 fontTick 范式）
  @StorageLink('columnModeTick') @Watch('onColumnModeTick') columnModeTick: number = 0;
  @State columnMode: number = 0;
  @State isDark: boolean = isDarkMode();
  // API26+ 真机沉浸光感：为 true 时 build 走官方 Tabs 悬浮条壳（底部模块栏整体入 .tabBar() 槽位，
  // 悬浮条本体挂 barFloatingStyle.systemMaterial 才渲染官方材质，与首页底栏同一机制）；其余走原手写真模糊兜底
  @State materialSupported: boolean = false;
  // 官方悬浮条宽度依赖的屏宽（onAreaChange 实时更新）
  @State currentWidth: number = 360;

  // ===== 平板适配（docs/TiebaPura平板适配.md §4.7，2026-09-15 用户拍板重定）=====
  /** 大屏形态设备（平板 / 2in1 / 折叠屏）：静态判定一次。折叠屏 deviceType 为 'phone'，必须单独用 isFoldable 识别（§4.8 T-B 同款） */
  private readonly isWideFormDevice: boolean = detectWideFormDevice();
  /** 窗口宽 / 高（vp）：aboutToAppear 同步取首帧初值，onAreaChange 兜底 */
  @State pageWidth: number = 0;
  @State pageHeight: number = 0;
  private isLandscape: boolean = false;

  private scroller: Scroller = new Scroller();
  private searchController: TextInputController = new TextInputController();
  private requestSerial: number = 0; // 最新一次"整页搜索"序号，用于丢弃过期请求的回写

  // 输入与模块
  @State keyword: string = '';
  @State activeModule: number = 0;
  @State hasSearchedOnce: boolean = false; // 是否至少发起过一次搜索（区分引导态）
  @State searching: boolean = false;       // 整页/换词搜索请求中
  @State errorMsg: string = '';
  // 模块切换对滑动画（与首页底栏同款手法）：prevModule = 正在退场滑出的旧模块(-1 无)，
  // inOffset/outOffset = 进场/退场模块页横向位移百分比（100 = 整屏宽）
  @State prevModule: number = -1;
  @State inOffset: number = 0;
  @State outOffset: number = 0;
  private animLock: boolean = false;

  // 搜吧
  @State forumData: GlobalForumSearchData = { exact: null, list: [], hasMore: false, page: 0 };
  @State forumKeywordLoaded: string = '';
  @State forumLoadingMore: boolean = false;

  // 搜贴
  @State postData: GlobalPostSearchData = { list: [], hasMore: false, page: 0 };
  @State postKeywordLoaded: string = '';
  @State postLoadingMore: boolean = false;

  // 搜人
  @State userData: GlobalUserSearchData = { exact: null, list: [], hasMore: false, page: 0 };
  @State userKeywordLoaded: string = '';
  @State userLoadingMore: boolean = false;

  aboutToAppear(): void {
    MaterialManager.init();
    this.materialSupported = MaterialManager.isSupported() && MaterialManager.getApiLevel() >= 26;
    this.isDark = isDarkMode();
    // 「列数调整」档位初值（2026-09-18）：冷启动首帧即按已选档渲染
    // （UsageHabitsManager.init 的 columnModeTick 可能早于本页构造，@Watch 不会补触发，故此处直读）
    this.columnMode = readColumnMode();
    const params = this.getUIContext().getRouter().getParams() as Record<string, string>;
    if (params && params.keyword && params.keyword.length > 0) {
      this.keyword = params.keyword;
      // 入参关键词：直接进入首轮搜索
      this.submitSearch();
    }
    // 首帧形态初值（§4.6 H-A / §4.8 T-B 同源）：onAreaChange 只在尺寸变化后触发，冷启动平板横屏
    // 若不预置会出现「先 1 列再跳 3/4 列」的首帧跳变。取不到就保持 0，由 onAreaChange 兜底。
    this.refreshFormMetrics();
  }

  /** 形态度量回填：aboutToAppear 首帧（display 兜底猜测）+ 根容器 onAreaChange（窗口实值）共用。
   *  2026-09-17 小窗 / 分屏适配：传入窗口宽高时以窗口为准（自由多窗下 display ≠ 窗口）。 */
  private refreshFormMetrics(winW?: number, winH?: number): void {
    let w: number = winW ?? 0;
    let h: number = winH ?? 0;
    if (w <= 0 || h <= 0) {
      try {
        const d = display.getDefaultDisplaySync();
        w = this.getUIContext().px2vp(d.width);
        h = this.getUIContext().px2vp(d.height);
      } catch (e) {
        // 忽略：窗口未 attach 时取宽会失败
        return;
      }
    }
    if (w <= 0 || h <= 0) {
      return;
    }
    this.pageWidth = w;
    this.pageHeight = h;
    this.isLandscape = w > h;
  }

  /**
   * 结果列数：大屏竖屏 3 / 横屏 4（2026-09-15 用户拍板，与首页 §4.2 决策 12 同口径）。
   * 形态闸门必须放首行：只按宽度判会让手机横屏误命中多列（§6.1 D4）。
   */
  /**
   * 「列数调整」档位变化（个性化页写入 → `columnModeTick` 广播）：
   * 回写本地档位（列数函数随新档返回，搜吧 / 搜贴 / 搜人三态共用）→ 强制回到列表顶部。
   * 默认档（0）与原自动适配逐像素一致，仅「用户显式选择」后才改变列数。
   */
  private onColumnModeTick(): void {
    this.columnMode = readColumnMode();
    try {
      this.scroller.scrollTo({ xOffset: 0, yOffset: 0 });
    } catch (e) {
    }
  }

  private searchColumns(): number {
    // 窗口闸门最前（2026-09-17 小窗 / 分屏适配）：窗口宽 <600（自由多窗小窗 / 分屏窄窗）一律回落
    // 手机单列档——须在设备恒值分支（大折叠恒 3）之前，防小窗误命中
    // 阔直屏全屏白名单（2026-09-18）：Pura X View（VOL-AL00）等阔直屏竖屏全屏窗口宽仅 ~440vp，
    // 会被本闸门误判成小窗；白名单放行（小窗 / 分屏仍拦，见 Theme.isWideBarFullscreen）
    if (this.pageWidth > 0 && this.pageWidth < Breakpoint.sm && !isWideBarFullscreen(this.pageWidth)) {
      return 1;
    }
    // 「列数调整」（2026-09-18，个性化 → 列数调整）：仅大屏形态（平板 / 阔直屏 / 大折叠展开）生效，
    // 窄窗与手机档已由上面的窗口闸门返回不受影响；默认档 ov=0 → 原样走下面自动适配分支（逐像素零回归）
    if (isLargeScreenForm(this.isWideFormDevice)) {
      const ov: number = overrideColumns(this.columnMode, this.isLandscape);
      if (ov > 0) {
        return ov;
      }
    }
    // 大折叠（docs/TiebaPura大折叠适配.md §4.2）：竖 2 / 横 3（2026-09-17 用户改定，与阔直屏同口径；搜吧 / 搜贴 / 搜人共用）
    if (isLargeFoldDevice()) {
      return this.isLandscape ? 3 : 2;
    }
    // 阔直屏（docs/TiebaPura阔直屏适配.md §4.2，2026-09-17 用户改定）：不依赖宽度阈值（竖屏宽 <600），
    // 竖 1 / 横 3（竖屏回落手机单列档；初版竖 2 作废）
    if (isWideBarDevice()) {
      return this.isLandscape ? 3 : 1;
    }
    if (!this.isWideFormDevice) {
      return 1;
    }
    if (this.pageWidth < Breakpoint.sm) {
      return 1;
    }
    // 2026-09-17 三次拍板：平板**竖屏 2 列**（≥840 竖屏 3 列作废）/ 横屏 3 列（搜吧 / 搜贴 / 搜人共用）
    return this.isLandscape ? 3 : 2;
  }

  /** 列索引数组 [0..列数-1]：外层 ForEach 只遍历索引（key 稳定 → 列容器复用，收藏页五轮教训） */
  private searchColIndexes(): number[] {
    const n: number = this.searchColumns();
    const arr: number[] = [];
    for (let i = 0; i < n; i++) {
      arr.push(i);
    }
    return arr;
  }

  /**
   * 通用分桶（方案 B「带滞回的最短列」，2026-09-15，与 §4.9/§4.10/§4.12 同款）：
   * 默认按 `i % 列数` 轮转（保序观感），仅当轮转目标列与最短列的估算高差 > 240vp（≈一张短卡）
   * 时改投最短列补位。确定性估算、无测量循环；前缀稳定贪心：结果追加从头重算，旧卡落列不变。
   * `gap` 为列内间距（各模块与自身渲染间距同源：搜吧/搜人/搜贴列内均为 12）。
   */
  private bucketColumns<T>(items: T[], estimate: (item: T) => number): T[][] {
    const cols: number = this.searchColumns();
    const buckets: T[][] = [];
    const heights: number[] = [];
    for (let c = 0; c < cols; c++) {
      buckets.push([]);
      heights.push(0);
    }
    for (let i = 0; i < items.length; i++) {
      let target: number = i % cols;
      let shortest: number = 0;
      for (let c = 1; c < cols; c++) {
        if (heights[c] < heights[shortest]) {
          shortest = c;
        }
      }
      if (heights[target] - heights[shortest] > 240) {
        target = shortest;
      }
      buckets[target].push(items[i]);
      heights[target] += estimate(items[i]) + 12;
    }
    return buckets;
  }

  /** 搜吧卡估算高（多列档口径：头像行 52 + padding 28，slogan ≤1 行 +22） */
  private estimateForumCard(item: GlobalForumResult): number {
    let h: number = 92;
    if (item.slogan.length > 0) {
      h += 22;
    }
    return h;
  }

  /** 搜人卡估算高（与搜吧卡同构：头像行 52 + padding 28，intro ≤1 行 +22） */
  private estimateUserCard(item: GlobalUserResult): number {
    let h: number = 92;
    if (item.intro.length > 0) {
      h += 22;
    }
    return h;
  }

  /** 搜贴卡估算高（多列档口径：padding 28 + 信息行 24；标题 ≤2 行 fs16、摘要 ≤2 行 fs13） */
  private estimatePostCard(item: GlobalPostResult): number {
    let h: number = 124;
    const title: string = item.title.length > 0 ? item.title : item.content;
    if (title.length > 0) {
      h += Math.min(Math.ceil(title.length / 18), 2) * 22 + 6;
    }
    if (item.title.length > 0 && item.content.length > 0 && item.title !== item.content) {
      h += Math.min(Math.ceil(item.content.length / 20), 2) * 20 + 6;
    }
    return h;
  }

  onPageShow(): void {
    this.isDark = isDarkMode();
    this.fontSizeTick++;
  }

  private notify(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message });
  }

  /* ============== 输入与搜索动作 ============== */

  private submitSearch(): void {
    const kw: string = this.keyword.trim();
    if (kw.length === 0) {
      this.notify('请输入要搜索的内容');
      return;
    }
    this.hasSearchedOnce = true;
    this.errorMsg = '';
    this.prepareModule(false);
  }

  /** 模块切换（与首页底栏同款手法）：方向感知整屏对滑。
   *  目标模块在当前右侧(index 更大) → 新内容从右侧滑入、旧内容向左滑出；反向镜像。
   *  动画期间锁定(animLock)，连点直接忽略避免错乱；退场页由定时器在动画结束后卸载 */
  private switchModule(index: number): void {
    if (index === this.activeModule || this.animLock) {
      return;
    }
    const dir: number = index > this.activeModule ? 1 : -1;
    this.animLock = true;
    this.prevModule = this.activeModule;
    this.activeModule = index;
    this.scroller.scrollEdge(Edge.Top);
    this.errorMsg = '';
    // 初始位置(无动画赋值)：新页从 dir 侧整屏外进入、旧页原位准备退场
    this.inOffset = dir * 100;
    this.outOffset = 0;
    this.getUIContext().animateTo(
      { duration: 320, curve: curves.springMotion(0.72, 0.86) },
      () => {
        this.outOffset = -dir * 100;
        this.inOffset = 0;
      }
    );
    // SDK 的 animateTo 无 onFinish 回调，用定时器在动画结束后卸载退场页并释放切换锁
    // （时长取动画约 1.3 倍，避免弹簧曲线回弹超时导致退场页提前卸载）
    setTimeout(() => {
      this.prevModule = -1;
      this.outOffset = 0;
      this.animLock = false;
    }, 420);
    const kw: string = this.keyword.trim();
    if (kw.length === 0) {
      return;
    }
    // 引导态下直接点模块页签也视为「已发起搜索」：否则请求已发出（数据已就绪），
    // 但内容区仍停在引导态 → 表现为「第一次切到搜贴没内容，再点一次搜索才出现」
    this.hasSearchedOnce = true;
    this.prepareModule(false);
  }

  /** 决定当前模块是否发起整页搜索（关键词变了/无缓存数据才发请求） */
  private prepareModule(loadMore: boolean): void {
    const kw: string = this.keyword.trim();
    if (kw.length === 0) {
      this.searching = false;
      return;
    }
    if (this.activeModule === 0) {
      if (!loadMore && this.forumKeywordLoaded === kw && (this.forumData.exact !== null || this.forumData.list.length > 0)) {
        this.searching = false;
        return;
      }
      this.searching = !loadMore;
      this.runForumSearch(kw, loadMore);
    } else if (this.activeModule === 1) {
      if (!loadMore && this.postKeywordLoaded === kw && this.postData.list.length > 0) {
        this.searching = false;
        return;
      }
      this.searching = !loadMore;
      this.runPostSearch(kw, loadMore);
    } else {
      if (!loadMore && this.userKeywordLoaded === kw && (this.userData.exact !== null || this.userData.list.length > 0)) {
        this.searching = false;
        return;
      }
      this.searching = !loadMore;
      this.runUserSearch(kw, loadMore);
    }
  }

  private runForumSearch(kw: string, loadMore: boolean): void {
    const mySerial: number = ++this.requestSerial;
    if (!loadMore) {
      this.forumData = { exact: null, list: [], hasMore: false, page: 0 };
    } else {
      this.forumLoadingMore = true;
    }
    const nextPage: number = loadMore ? this.forumData.page + 1 : 1;
    TiebaService.getInstance().searchForumGlobal(kw, nextPage, 20).then((result: GlobalForumSearchData) => {
      if (loadMore) {
        this.forumData = { exact: result.exact, list: this.forumData.list.concat(result.list), hasMore: result.hasMore, page: nextPage };
      } else {
        this.forumData = result;
      }
      this.forumKeywordLoaded = kw;
      this.forumLoadingMore = false;
      if (mySerial === this.requestSerial) {
        this.searching = false;
      }
    }).catch((err: Error) => {
      const msg: string = err instanceof Error ? err.message : String(err);
      this.forumLoadingMore = false;
      if (mySerial === this.requestSerial) {
        this.searching = false;
        this.errorMsg = msg;
      } else if (loadMore) {
        this.notify(msg);
      }
    });
  }

  private runPostSearch(kw: string, loadMore: boolean): void {
    const mySerial: number = ++this.requestSerial;
    if (!loadMore) {
      this.postData = { list: [], hasMore: false, page: 0 };
    } else {
      this.postLoadingMore = true;
    }
    const nextPage: number = loadMore ? this.postData.page + 1 : 1;
    // 2026-09-15 切客户端端点 /c/s/searchpost（不带 kw = 全吧搜贴）：旧 web 端点 /mo/q/search/thread
    // 已被百度停摆（success + 空结果 + blank_type:1，带签名直连/带 BDUSS 均空，见 service 注释）
    TiebaService.getInstance().searchPostGlobalClient(kw, nextPage, 20).then((result: GlobalPostSearchData) => {
      if (loadMore) {
        this.postData = { list: this.postData.list.concat(result.list), hasMore: result.hasMore, page: nextPage };
      } else {
        this.postData = result;
      }
      this.postKeywordLoaded = kw;
      this.postLoadingMore = false;
      if (mySerial === this.requestSerial) {
        this.searching = false;
      }
    }).catch((err: Error) => {
      const msg: string = err instanceof Error ? err.message : String(err);
      this.postLoadingMore = false;
      if (mySerial === this.requestSerial) {
        this.searching = false;
        this.errorMsg = msg;
      } else if (loadMore) {
        this.notify(msg);
      }
    });
  }

  private runUserSearch(kw: string, loadMore: boolean): void {
    const mySerial: number = ++this.requestSerial;
    if (!loadMore) {
      this.userData = { exact: null, list: [], hasMore: false, page: 0 };
    } else {
      this.userLoadingMore = true;
    }
    const nextPage: number = loadMore ? this.userData.page + 1 : 1;
    TiebaService.getInstance().searchUserGlobal(kw, nextPage, 20).then((result: GlobalUserSearchData) => {
      if (loadMore) {
        this.userData = { exact: result.exact, list: this.userData.list.concat(result.list), hasMore: result.hasMore, page: nextPage };
      } else {
        this.userData = result;
      }
      this.userKeywordLoaded = kw;
      this.userLoadingMore = false;
      if (mySerial === this.requestSerial) {
        this.searching = false;
      }
    }).catch((err: Error) => {
      const msg: string = err instanceof Error ? err.message : String(err);
      this.userLoadingMore = false;
      if (mySerial === this.requestSerial) {
        this.searching = false;
        this.errorMsg = msg;
      } else if (loadMore) {
        this.notify(msg);
      }
    });
  }

  /** 滚动到底加载下一页（当前模块） */
  private onReachBottom(): void {
    if (this.searching || this.errorMsg.length > 0) {
      return;
    }
    const kw: string = this.keyword.trim();
    if (this.activeModule === 0 && this.forumData.hasMore && !this.forumLoadingMore && this.forumKeywordLoaded === kw) {
      this.runForumSearch(kw, true);
    } else if (this.activeModule === 1 && this.postData.hasMore && !this.postLoadingMore && this.postKeywordLoaded === kw) {
      this.runPostSearch(kw, true);
    } else if (this.activeModule === 2 && this.userData.hasMore && !this.userLoadingMore && this.userKeywordLoaded === kw) {
      this.runUserSearch(kw, true);
    }
  }

  /* ============== 导航 ============== */

  private goBack(): void {
    this.getUIContext().getRouter().back();
  }

  private openForum(item: GlobalForumResult): void {
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/ThreadList',
      params: { kw: item.forumName, forumName: item.forumName, fid: item.forumId }
    }).catch(() => {
      this.notify('贴吧页面打开失败，请稍后重试');
    });
  }

  private openThread(item: GlobalPostResult): void {
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/ThreadDetail',
      params: { tid: item.tid, forum: item.forumName, fid: item.forumId }
    }).catch(() => {
      this.notify('帖子打开失败，请稍后重试');
    });
  }

  private openUser(item: GlobalUserResult): void {
    const show: string = item.showName.length > 0 ? item.showName : item.userName;
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/UserProfile',
      params: { userId: item.userId, userName: show }
    }).catch(() => {
      this.notify('用户主页打开失败，请稍后重试');
    });
  }

  /* ============== 格式化工具 ============== */

  /** 秒时间戳 → 相对时间 */
  private formatAgo(ts: number): string {
    if (ts <= 0) {
      return '';
    }
    const diff: number = Math.floor(Date.now() / 1000) - ts;
    if (diff < 0) {
      return '刚刚';
    }
    if (diff < 60) {
      return '刚刚';
    }
    if (diff < 3600) {
      return `${Math.floor(diff / 60)}分钟前`;
    }
    if (diff < 86400) {
      return `${Math.floor(diff / 3600)}小时前`;
    }
    if (diff < 86400 * 7) {
      return `${Math.floor(diff / 86400)}天前`;
    }
    const date: Date = new Date(ts * 1000);
    const month: number = date.getMonth() + 1;
    const day: number = date.getDate();
    const year: number = date.getFullYear();
    const nowYear: number = new Date().getFullYear();
    const dd: string = day < 10 ? `0${day}` : `${day}`;
    return year === nowYear ? `${month}月${dd}日` : `${year}-${month < 10 ? `0${month}` : `${month}`}-${dd}`;
  }

  /** 粉丝等纯数字计数 → 万/亿展示 */
  private formatCount(num: number): string {
    if (num <= 0) {
      return '';
    }
    if (num >= 100000000) {
      const v: string = (num / 100000000).toFixed(1);
      return `${v.endsWith('.0') ? v.substring(0, v.length - 2) : v}亿`;
    }
    if (num >= 10000) {
      const v: string = (num / 10000).toFixed(1);
      return `${v.endsWith('.0') ? v.substring(0, v.length - 2) : v}万`;
    }
    return `${num}`;
  }

  private avatarChar(name: string): string {
    if (name.length === 0) {
      return '?';
    }
    return name.substring(0, 1).toUpperCase();
  }

  private avatarColor(name: string): string {
    let sum: number = 0;
    for (let i = 0; i < name.length; i++) {
      sum += name.charCodeAt(i);
    }
    return AVATAR_COLORS[sum % AVATAR_COLORS.length];
  }

  /* ============== 通用小组件 ============== */

  @Builder
  AvatarView(url: string, name: string, size: number) {
    Stack() {
      Column() {
        Text(this.avatarChar(name))
          .fontSize(fs(Math.round(size * 0.42), this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFFFF')
      }
      .width(size)
      .height(size)
      .justifyContent(FlexAlign.Center)
      .borderRadius(size / 2)
      .backgroundColor(this.avatarColor(name))
      if (url.length > 0) {
        Image(url)
          .width(size)
          .height(size)
          .borderRadius(size / 2)
          .objectFit(ImageFit.Cover)
          .onError(() => {
          })
      }
    }
    .width(size)
    .height(size)
    .borderRadius(size / 2)
    .clip(true)
  }

  @Builder
  SectionHeader(label: string) {
    Row() {
      Column()
        .width(3)
        .height(14)
        .borderRadius(1.5)
        .backgroundColor(Theme.brand())
      Text(label)
        .fontSize(fs(15, this.fontScale))
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.textPrimary(this.isDark))
        .margin({ left: 6 })
      Blank()
    }
    .width('100%')
    .padding({ left: 4, right: 4, bottom: 4 })
  }

  @Builder
  CountText(text: string) {
    Text(text)
      .fontSize(fs(12, this.fontScale))
      .fontColor(Theme.textSecondary(this.isDark))
  }

  /** 吧/用户搜索结果卡片：点击进入对应主页 */
  @Builder
  EntryCard(name: string, sub: string, avatarUrl: string, onClick: () => void) {
    Row() {
      this.AvatarView(avatarUrl, name, 46)
      Column({ space: 2 }) {
        Text(name)
          .fontSize(fs(16, this.fontScale))
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textPrimary(this.isDark))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (sub.length > 0) {
          Text(sub)
            .fontSize(fs(12, this.fontScale))
            .fontColor(Theme.textSecondary(this.isDark))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 12 })
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontColor([Theme.textTertiary(this.isDark)])
        .fontSize(fs(16, this.fontScale))
    }
    .width('100%')
    .padding({ left: 14, right: 12, top: 12, bottom: 12 })
    .backgroundColor(Theme.bgCard(this.isDark))
    .borderRadius(26)
    .onClick(onClick)
  }

  /* ============== 引导态 ============== */

  /** 引导态扁平放大镜：扁平简约（纯色、无渐变/阴影）。
   *  环 = 描边圆，柄 = 圆头直线（沿 45° 指向右下方），主题品牌蓝，适配明暗双模式。 */
  @Builder
  GuideIcon() {
    Stack() {
      Circle()
        .width(52)
        .height(52)
        .fill(Color.Transparent)
        .stroke(Theme.brand())
        .strokeWidth(7)
        .position({ x: 4, y: 1 })
      Line()
        .startPoint([0, 0])
        .endPoint([30, 30])
        .stroke(Theme.brand())
        .strokeWidth(7)
        .strokeLineCap(LineCapStyle.Round)
        .position({ x: 40, y: 36 })
    }
    .width(84)
    .height(84)
    .alignContent(Alignment.Center)
  }

  @Builder
  GuideBuilder() {
    Column({ space: 12 }) {
      this.GuideIcon()
      Text('搜索整个百度贴吧')
        .fontSize(fs(17, this.fontScale))
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.textPrimary(this.isDark))
      Text('输入关键词，一站式搜吧 · 搜贴 · 搜人')
        .fontSize(fs(13, this.fontScale))
        .fontColor(Theme.textSecondary(this.isDark))
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ top: 120, bottom: 120 })
  }

  /* ============== 搜吧结果 ============== */

  @Builder
  ForumResults() {
    if (this.forumData.exact === null && this.forumData.list.length === 0) {
      EmptyView({ message: '没有找到相关贴吧', icon: '🗂️' })
        .margin({ top: 90 })
        .height(160)
    } else {
      Column({ space: 12 }) {
        // 推荐位：完全匹配的吧
        if (this.forumData.exact !== null) {
          this.SectionHeader('推荐')
          this.ForumExactCard()
        }
        // 相关吧（2026-09-15 拍板：竖 3 / 横 4 列，列内独立堆叠）
        if (this.forumData.list.length > 0) {
          Column() {
            this.SectionHeader('相关吧')
          }
          .width('100%')
          .margin({ top: 16 })
          if (this.searchColumns() > 1) {
            Row({ space: 12 }) {
              ForEach(this.searchColIndexes(), (colIdx: number) => {
                Column({ space: 12 }) {
                  ForEach(this.bucketColumns(this.forumData.list, (it: GlobalForumResult) => this.estimateForumCard(it))[colIdx],
                    (item: GlobalForumResult) => {
                      this.ForumRowCard(item)
                    }, (item: GlobalForumResult) => `${item.forumId}_${item.forumName}`)
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
              }, (colIdx: number) => `fcol_${colIdx}`)
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)
          } else {
            ForEach(this.forumData.list, (item: GlobalForumResult) => {
              this.ForumRowCard(item)
            }, (item: GlobalForumResult) => `${item.forumId}_${item.forumName}`)
          }
        }
        this.ModuleFooter(this.forumData.hasMore, this.forumLoadingMore)
      }
      .width('100%')
      .padding({ left: 12, right: 12 })
    }
  }

  @Builder
  ForumExactCard() {
    Column() {
      if (this.forumData.exact !== null) {
        Row() {
          this.AvatarView(this.forumData.exact.avatar, this.forumData.exact.forumNameShow, 54)
          Column({ space: 3 }) {
            Row({ space: 6 }) {
              Text(this.forumData.exact.forumNameShow)
                .fontSize(fs(18, this.fontScale))
                .fontWeight(FontWeight.Bold)
                .fontColor(Theme.textPrimary(this.isDark))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              if (this.forumData.exact.isOfficial) {
                Text('官方')
                  .fontSize(fs(10, this.fontScale))
                  .fontColor('#3173FF')
                  .padding({ left: 5, right: 5, top: 2, bottom: 2 })
                  .backgroundColor('#1A3173FF')
                  .borderRadius(6)
              }
            }
            .width('100%')
            Row({ space: 4 }) {
              this.CountText(`成员 ${this.forumData.exact.memberNumShow}`)
              Text('·').fontSize(fs(12, this.fontScale)).fontColor(Theme.textTertiary(this.isDark))
              this.CountText(`帖子 ${this.forumData.exact.postNumShow}`)
            }
            .width('100%')
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          .margin({ left: 12 })
        }
        .width('100%')
        if (this.forumData.exact.slogan.length > 0) {
          Text(this.forumData.exact.slogan)
            .fontSize(fs(13, this.fontScale))
            .fontColor(Theme.textSecondary(this.isDark))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .margin({ top: 10 })
        }
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.bgCard(this.isDark))
    // 推荐位卡片圆角 26：与全站卡片口径统一（此前 18）
    .borderRadius(26)
    .border({ width: 1, color: Theme.manualGlassBorder() })
    .onClick(() => {
      if (this.forumData.exact !== null) {
        this.openForum(this.forumData.exact)
      }
    })
  }

  @Builder
  ForumRowCard(item: GlobalForumResult) {
    Column() {
      Row() {
        this.AvatarView(item.avatar, item.forumNameShow, 44)
        Column({ space: 3 }) {
          Text(item.forumNameShow)
            .fontSize(fs(16, this.fontScale))
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.textPrimary(this.isDark))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Row({ space: 4 }) {
            this.CountText(`成员 ${item.memberNumShow}`)
            Text('·').fontSize(fs(12, this.fontScale)).fontColor(Theme.textTertiary(this.isDark))
            this.CountText(`帖子 ${item.postNumShow}`)
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 12 })
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontColor([Theme.textTertiary(this.isDark)])
          .fontSize(fs(16, this.fontScale))
      }
      .width('100%')
      if (item.slogan.length > 0) {
        Text(item.slogan)
          .fontSize(fs(12, this.fontScale))
          .fontColor(Theme.textSecondary(this.isDark))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 8 })
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.bgCard(this.isDark))
    .borderRadius(26)
    .onClick(() => this.openForum(item))
  }

  /* ============== 搜贴结果 ============== */

  @Builder
  PostResults() {
    if (this.postData.list.length === 0) {
      EmptyView({ message: '没有找到相关帖子', icon: '📄' })
        .margin({ top: 90 })
        .height(160)
    } else {
      Column({ space: 12 }) {
        // 搜贴（2026-09-15 拍板：首页同款瀑布流，竖 3 / 横 4 列，列内独立堆叠 + 方案 B 分桶）
        if (this.searchColumns() > 1) {
          Row({ space: 12 }) {
            ForEach(this.searchColIndexes(), (colIdx: number) => {
              Column({ space: 12 }) {
                ForEach(this.bucketColumns(this.postData.list, (it: GlobalPostResult) => this.estimatePostCard(it))[colIdx],
                  (item: GlobalPostResult) => {
                    this.PostCard(item)
                  }, (item: GlobalPostResult) => `${item.tid}_${item.pid}_${item.createTime}`)
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            }, (colIdx: number) => `pcol_${colIdx}`)
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
        } else {
          ForEach(this.postData.list, (item: GlobalPostResult) => {
            this.PostCard(item)
          }, (item: GlobalPostResult) => `${item.tid}_${item.pid}_${item.createTime}`)
        }
        this.ModuleFooter(this.postData.hasMore, this.postLoadingMore)
      }
      .width('100%')
      .padding({ left: 12, right: 12 })
    }
  }

  @Builder
  PostCard(item: GlobalPostResult) {
    Column({ space: 6 }) {
      Text(item.title.length > 0 ? item.title : item.content)
        .fontSize(fs(16, this.fontScale))
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.textPrimary(this.isDark))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
      if (item.title.length > 0 && item.content.length > 0 && item.title !== item.content) {
        Text(item.content)
          .fontSize(fs(13, this.fontScale))
          .fontColor(Theme.textSecondary(this.isDark))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      Row({ space: 8 }) {
        Text(item.forumName)
          .fontSize(fs(11, this.fontScale))
          .fontColor('#3173FF')
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .backgroundColor('#1A3173FF')
          .borderRadius(5)
        Text(item.authorShowName)
          .fontSize(fs(12, this.fontScale))
          .fontColor(Theme.textSecondary(this.isDark))
        if (item.createTime > 0) {
          Text(this.formatAgo(item.createTime))
            .fontSize(fs(12, this.fontScale))
            .fontColor(Theme.textTertiary(this.isDark))
        }
        Blank()
        if (item.replyNum > 0) {
          Text(`回复 ${item.replyNum}`)
            .fontSize(fs(12, this.fontScale))
            .fontColor(Theme.textTertiary(this.isDark))
        }
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(14)
    .backgroundColor(Theme.bgCard(this.isDark))
    .borderRadius(26)
    .onClick(() => this.openThread(item))
  }

  /* ============== 搜人结果 ============== */

  @Builder
  UserResults() {
    if (this.userData.exact === null && this.userData.list.length === 0) {
      EmptyView({ message: '没有找到相关用户', icon: '👤' })
        .margin({ top: 90 })
        .height(160)
    } else {
      Column({ space: 12 }) {
        if (this.userData.exact !== null) {
          this.SectionHeader('推荐')
          this.UserExactCard()
        }
        if (this.userData.list.length > 0) {
          Column() {
            this.SectionHeader('用户')
          }
          .width('100%')
          .margin({ top: 16 })
          if (this.searchColumns() > 1) {
            Row({ space: 12 }) {
              ForEach(this.searchColIndexes(), (colIdx: number) => {
                Column({ space: 12 }) {
                  ForEach(this.bucketColumns(this.userData.list, (it: GlobalUserResult) => this.estimateUserCard(it))[colIdx],
                    (item: GlobalUserResult) => {
                      this.UserRowCard(item)
                    }, (item: GlobalUserResult) => `${item.userId}_${item.userName}`)
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
              }, (colIdx: number) => `ucol_${colIdx}`)
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)
          } else {
            ForEach(this.userData.list, (item: GlobalUserResult) => {
              this.UserRowCard(item)
            }, (item: GlobalUserResult) => `${item.userId}_${item.userName}`)
          }
        }
        this.ModuleFooter(this.userData.hasMore, this.userLoadingMore)
      }
      .width('100%')
      .padding({ left: 12, right: 12 })
    }
  }

  @Builder
  UserExactCard() {
    Column() {
      if (this.userData.exact !== null) {
        Row() {
          this.AvatarView(this.userData.exact.avatar, this.userData.exact.showName, 54)
          Column({ space: 3 }) {
            Text(this.userData.exact.showName)
              .fontSize(fs(18, this.fontScale))
              .fontWeight(FontWeight.Bold)
              .fontColor(Theme.textPrimary(this.isDark))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Row({ space: 4 }) {
              if (this.userData.exact.userName.length > 0 && this.userData.exact.showName !== this.userData.exact.userName) {
                Text(`@${this.userData.exact.userName}`)
                  .fontSize(fs(12, this.fontScale))
                  .fontColor(Theme.textTertiary(this.isDark))
              }
              if (this.userData.exact.fansNum > 0) {
                this.CountText(`粉丝 ${this.formatCount(this.userData.exact.fansNum)}`)
              }
            }
            .width('100%')
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          .margin({ left: 12 })
        }
        .width('100%')
        if (this.userData.exact.intro.length > 0) {
          Text(this.userData.exact.intro)
            .fontSize(fs(13, this.fontScale))
            .fontColor(Theme.textSecondary(this.isDark))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .margin({ top: 10 })
        }
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.bgCard(this.isDark))
    // 推荐位卡片圆角 26：与全站卡片口径统一（此前 18）
    .borderRadius(26)
    .border({ width: 1, color: Theme.manualGlassBorder() })
    .onClick(() => {
      if (this.userData.exact !== null) {
        this.openUser(this.userData.exact)
      }
    })
  }

  @Builder
  UserRowCard(item: GlobalUserResult) {
    Row() {
      this.AvatarView(item.avatar, item.showName, 44)
      Column({ space: 3 }) {
        Text(item.showName)
          .fontSize(fs(16, this.fontScale))
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textPrimary(this.isDark))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Row({ space: 6 }) {
          if (item.userName.length > 0 && item.showName !== item.userName) {
            Text(`@${item.userName}`)
              .fontSize(fs(12, this.fontScale))
              .fontColor(Theme.textTertiary(this.isDark))
          }
          if (item.fansNum > 0) {
            this.CountText(`粉丝 ${this.formatCount(item.fansNum)}`)
          }
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 12 })
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontColor([Theme.textTertiary(this.isDark)])
        .fontSize(fs(16, this.fontScale))
    }
    .width('100%')
    .padding({ left: 14, right: 12, top: 12, bottom: 12 })
    .backgroundColor(Theme.bgCard(this.isDark))
    .borderRadius(26)
    .onClick(() => this.openUser(item))
  }

  /* ============== 列表底部翻页状态 ============== */

  @Builder
  ModuleFooter(hasMore: boolean, loadingMore: boolean) {
    Row() {
      if (loadingMore) {
        LoadingView({ message: '加载中...' })
          .height(36)
      } else if (hasMore) {
        Text('上拉加载更多')
          .fontSize(fs(12, this.fontScale))
          .fontColor(Theme.textTertiary(this.isDark))
      } else {
        Text('— 没有更多了 —')
          .fontSize(fs(12, this.fontScale))
          .fontColor(Theme.textTertiary(this.isDark))
      }
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ top: 14, bottom: 14 })
  }

  /* ============== 顶部满宽渐显带 ============== */

  @Builder
  TopFadeOverlay() {
    // 顶部渐显：只覆盖悬浮搜索行区域（下沿 = HEADER_TOP_SPACE，即搜索框底部），
    // 内容滚过搜索行下缘后即完全清晰，不再被渐隐带往下盖住；
    // DST_IN 白区不挖洞，1.0 处与带外内容连续；悬浮栏后渲染（zIndex 2）不受影响
    Stack()
      .width('100%')
      .height(HEADER_TOP_SPACE)
      .linearGradient({
        direction: GradientDirection.Bottom,
        colors: [['#00FFFFFF', 0.0], ['#FFFFFFFF', 0.7], ['#FFFFFFFF', 1.0]]
      })
      .blendMode(BlendMode.DST_IN, BlendApplyType.OFFSCREEN)
      .hitTestBehavior(HitTestMode.None)
  }

  /* ============== 底部悬浮模块栏（与首页底栏同款：icon22+文字11、等分、选中仅加粗+强调色，无缩放） ============== */

  @Builder
  ModuleSegBar() {
    Row() {
      this.ModuleSegButton(0)
      this.ModuleSegButton(1)
      this.ModuleSegButton(2)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 8, right: 8, top: 6, bottom: 6 })
  }

  @Builder
  ModuleSegButton(index: number) {
    Column({ space: 3 }) {
      SymbolGlyph(this.moduleSymbol(index))
        .fontSize(fs(22, this.fontScale))
        .fontWeight(this.activeModule === index ? FontWeight.Bold : FontWeight.Medium)
        .fontColor([this.activeModule === index
          ? $r('sys.color.icon_emphasize')
          : $r('sys.color.icon_primary')])
        .renderingStrategy(SymbolRenderingStrategy.SINGLE)
      Text(MODULE_LABELS[index])
        .fontSize(fs(11, this.fontScale))
        .fontWeight(this.activeModule === index ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(this.activeModule === index
          ? $r('sys.color.font_emphasize')
          : $r('sys.color.font_primary'))
    }
    .layoutWeight(1)
    .height(58)
    .justifyContent(FlexAlign.Center)
    .borderRadius(29)
    .backgroundColor(Color.Transparent)
    .accessibilityText(MODULE_LABELS[index])
    .onClick(() => this.switchModule(index))
  }

  private moduleSymbol(index: number): Resource {
    if (index === 0) {
      return $r('sys.symbol.grid');           // 搜吧：吧
    }
    if (index === 1) {
      return $r('sys.symbol.line_3_horizontal'); // 搜贴：帖子列表
    }
    return $r('sys.symbol.person');           // 搜人：用户
  }

  /* ============== 顶部悬浮栏 ============== */

  @Builder
  FloatingHeader() {
    Column() {
      // 搜索输入行
      Row() {
        Button({ type: ButtonType.Normal, stateEffect: false }) {
          // backgroundBlurStyle 在 Button 上固定矩形、不跟随圆角；须放到铺满的内层 Row 才按圆角裁剪（同搜索框）
          Row() {
            SymbolGlyph($r('sys.symbol.chevron_left'))
              .fontColor([$r('sys.color.icon_primary')])
              .fontSize(fs(28, this.fontScale))
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .borderRadius(Radius.full)
          .backgroundColor(Theme.segGlass(this.isDark, false))
          .border({ width: 0.5, color: Theme.manualGlassBorder() })
          .backgroundBlurStyle(BlurStyle.Thin, { scale: 0.85 })
          .shadow(Theme.segGlassShadow(this.isDark, false))
        }
        .width(36)
        .height(36)
        .backgroundColor(Color.Transparent)
        .onClick(() => this.goBack())

        // 玻璃搜索框（内含清除按钮）
        Row() {
          TextInput({
            text: this.keyword,
            placeholder: '搜索贴吧 · 帖子 · 用户',
            controller: this.searchController
          })
            .layoutWeight(1)
            .height(40)
            .fontSize(fs(15, this.fontScale))
            .fontColor(Theme.textPrimary(this.isDark))
            .placeholderColor(Theme.textTertiary(this.isDark))
            .placeholderFont({ size: fs(14, this.fontScale) })
            .backgroundColor(Color.Transparent)
            .padding({ left: 16, right: 8 })
            .enterKeyType(EnterKeyType.Search)
            .onChange((value: string) => {
              this.keyword = value
            })
            .onSubmit(() => {
              this.submitSearch()
            })
          if (this.keyword.length > 0) {
            Button({ type: ButtonType.Circle, stateEffect: false }) {
              SymbolGlyph($r('sys.symbol.xmark'))
                .fontColor([Theme.textSecondary(this.isDark)])
                .fontSize(fs(10, this.fontScale))
            }
            .width(22)
            .height(22)
            .backgroundColor(this.isDark ? '#26FFFFFF' : '#14000000')
            .margin({ right: 8 })
            .onClick(() => {
              this.keyword = ''
            })
          }
        }
        .layoutWeight(1)
        .height(40)
        .padding({ left: 0, right: 4 })
        .borderRadius(20)
        .backgroundColor(Theme.segGlass(this.isDark, false))
        .border({ width: 0.5, color: Theme.manualGlassBorder() })
        .backgroundBlurStyle(BlurStyle.Regular, { scale: 0.85 })
        .shadow(Theme.segGlassShadow(this.isDark, false))
        .margin({ left: 10, right: 10 })

        Button({ type: ButtonType.Normal, stateEffect: false }) {
          // backgroundBlurStyle 在 Button 上固定矩形、不跟随圆角；须放到铺满的内层 Row 才按圆角裁剪（同搜索框）
          Row() {
            SymbolGlyph($r('sys.symbol.magnifyingglass'))
              .fontColor([$r('sys.color.icon_primary')])
              .fontSize(fs(20, this.fontScale))
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .borderRadius(Radius.full)
          .backgroundColor(Theme.segGlass(this.isDark, false))
          .border({ width: 0.5, color: Theme.manualGlassBorder() })
          .backgroundBlurStyle(BlurStyle.Thin, { scale: 0.85 })
          .shadow(Theme.segGlassShadow(this.isDark, false))
        }
        .width(36)
        .height(36)
        .backgroundColor(Color.Transparent)
        .onClick(() => this.submitSearch())
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 44, bottom: 14 })
    }
    .width('100%')
    .zIndex(2)
  }

  /* ============== 顶部官方槽位标题栏（Navigation title） ============== */

  /**
   * 官方槽位标题栏：整行搬进 Navigation 的 title 槽位吃官方沉浸材质（§6.10 同机制）。
   * 几何与兜底路径的 FloatingHeader 逐项一致（外层 high 98 / padding top 44 + bottom 14 + 左右 12、
   * 行内 = 返回钮 36 + 间距 10 + 搜索框 40 + 间距 10 + 搜索钮 36），只把玻璃从 segGlass +
   * backgroundBlurStyle 自绘换成官方沉浸材质：
   * - 返回钮 / 搜索框 / 搜索钮 → ImmMaterial.seg(false)（THIN 中性档，与首页顶栏、各二级页顶栏同一套材质语言）；
   * - 含 Button 的两颗必须显式 backgroundColor(Color.Transparent)：Button 自带品牌蓝默认填充，不清底会透出蓝底；
   * - 不挂 border / backgroundBlurStyle / shadow：官方口径 systemMaterial 不与三者同用（会互相覆盖）；
   * - 文字/图标色改用系统可反色资源（font_primary / font_secondary / icon_primary），满足官方自动反色前提；
   * - 旧外壳 Column 的 zIndex(2) 去掉（槽内无叠层序需求，顶栏由 Navigation 承载不再与内容层争层级）。
   */
  @Builder
  SearchTitleBar() {
    Column() {
      // 搜索输入行
      Row() {
        Button({ type: ButtonType.Normal, stateEffect: false }) {
          Row() {
            SymbolGlyph($r('sys.symbol.chevron_left'))
              .fontColor([$r('sys.color.icon_primary')])
              .fontSize(fs(28, this.fontScale))
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
        }
        .width(36)
        .height(36)
        .backgroundColor(Color.Transparent)
        .systemMaterial(ImmMaterial.seg(false))
        .borderRadius(Radius.full)
        .onClick(() => this.goBack())

        // 玻璃搜索框（内含清除按钮）：外层 Row 承担玻璃与圆角，TextInput 清底透出材质
        Row() {
          TextInput({
            text: this.keyword,
            placeholder: '搜索贴吧 · 帖子 · 用户',
            controller: this.searchController
          })
            .layoutWeight(1)
            .height(40)
            .fontSize(fs(15, this.fontScale))
            .fontColor($r('sys.color.font_primary'))
            .placeholderColor($r('sys.color.font_secondary'))
            .placeholderFont({ size: fs(14, this.fontScale) })
            .backgroundColor(Color.Transparent)
            .padding({ left: 16, right: 8 })
            .enterKeyType(EnterKeyType.Search)
            .onChange((value: string) => {
              this.keyword = value
            })
            .onSubmit(() => {
              this.submitSearch()
            })
          if (this.keyword.length > 0) {
            // 清除钮是实心小圆底（非玻璃元素），保留原样：不挂材质，故与 systemMaterial 无叠用冲突
            Button({ type: ButtonType.Circle, stateEffect: false }) {
              SymbolGlyph($r('sys.symbol.xmark'))
                .fontColor([$r('sys.color.icon_secondary')])
                .fontSize(fs(10, this.fontScale))
            }
            .width(22)
            .height(22)
            .backgroundColor(this.isDark ? '#26FFFFFF' : '#14000000')
            .margin({ right: 8 })
            .onClick(() => {
              this.keyword = ''
            })
          }
        }
        .layoutWeight(1)
        .height(40)
        .padding({ left: 0, right: 4 })
        .borderRadius(20)
        .systemMaterial(ImmMaterial.seg(false))
        .margin({ left: 10, right: 10 })

        Button({ type: ButtonType.Normal, stateEffect: false }) {
          Row() {
            SymbolGlyph($r('sys.symbol.magnifyingglass'))
              .fontColor([$r('sys.color.icon_primary')])
              .fontSize(fs(20, this.fontScale))
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
        }
        .width(36)
        .height(36)
        .backgroundColor(Color.Transparent)
        .systemMaterial(ImmMaterial.seg(false))
        .borderRadius(Radius.full)
        .onClick(() => this.submitSearch())
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 44, bottom: 14 })
    }
    .width('100%')
  }

  /* ============== 构建 ============== */

  /** 官方悬浮底栏宽度（vp，形态分档）：手机档「屏宽 - 48」（下限 240）逐像素不变；
   *  平板 / 大屏档封顶 **480**（与首页底栏平板档同口径——同为 icon+文字三钮栏，观感统一），
   *  防「屏宽 - 48」在 1024 下拉成 976vp 通栏（2026-09-15 用户拍板「底栏不拉伸」） */
  private pillWidth(): number {
    const w: number = this.currentWidth > 0 ? this.currentWidth - 48 : 312;
    if (!this.isWideFormDevice) {
      return w > 240 ? w : 240;
    }
    const capped: number = w > 480 ? 480 : w;
    return capped > 240 ? capped : 240;
  }

  /** API26+ 官方路径：真实 Tabs 单内容承载页叠层，底部模块栏整体放入 .tabBar() 槽位，
   *  悬浮条本体挂 barFloatingStyle.systemMaterial（与 Index 首页底栏同一机制）才渲染官方真沉浸材质 */
  @Builder
  ImmersiveShell() {
    Tabs({ barPosition: BarPosition.End }) {
      TabContent() {
        this.ContentLayer()
      }
      .tabBar(this.ModuleSegBar())
    }
    .width('100%')
    .height('100%')
    .vertical(false)
    .scrollable(false)
    .barOverlap(true)
    .barHeight(74)
    .barBackgroundColor(Color.Transparent)
    .barFloatingStyle({
      barWidth: {
        smallBarWidth: this.pillWidth(),
        mediumBarWidth: this.pillWidth(),
        largeBarWidth: this.pillWidth()
      },
      barBottomMargin: 30,
      systemMaterial: ImmMaterial.floatingBar()
    })
    .backgroundColor(Color.Transparent)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .clip(false)
  }

  /** 加载态（仅当前模块页显示） */
  @Builder
  PageLoading() {
    LoadingView({ message: '正在搜索...' })
      .margin({ top: 60 })
      .height(220)
  }

  /** 错误态（仅当前模块页显示） */
  @Builder
  PageError() {
    ErrorView({ message: this.errorMsg, onRetry: () => this.submitSearch() })
      .margin({ top: 40 })
      .height(220)
  }

  /** 模块页整层内容：每个模块一个专属 builder（与首页各 Tab 各自独立组件同构）。
   *  不用「同一 builder 传不同 index 产出两个兄弟节点」——那样节点身份仅靠参数区分，
   *  退场页与进场页会互相错挂内容（表现即三个模块都显示搜吧列表）。
   *  非当前模块（退场中）只渲染已就绪结果，loading/错误只作用于当前模块 */
  @Builder
  ForumPageBody() {
    Column() {
      if (this.activeModule === 0 && this.searching) {
        this.PageLoading()
      } else if (this.activeModule === 0 && this.errorMsg.length > 0) {
        this.PageError()
      } else if (this.activeModule === 0 || this.forumData.exact !== null || this.forumData.list.length > 0) {
        // 退场中的模块若无任何数据则不渲染，避免对滑瞬间闪出「没有找到相关贴吧」
        this.ForumResults()
      }
    }
    .width('100%')
  }

  @Builder
  PostPageBody() {
    Column() {
      if (this.activeModule === 1 && this.searching) {
        this.PageLoading()
      } else if (this.activeModule === 1 && this.errorMsg.length > 0) {
        this.PageError()
      } else if (this.activeModule === 1 || this.postData.list.length > 0) {
        // 退场中的模块若无任何数据则不渲染，避免对滑瞬间闪出「没有找到相关帖子」
        this.PostResults()
      }
    }
    .width('100%')
  }

  @Builder
  UserPageBody() {
    Column() {
      if (this.activeModule === 2 && this.searching) {
        this.PageLoading()
      } else if (this.activeModule === 2 && this.errorMsg.length > 0) {
        this.PageError()
      } else if (this.activeModule === 2 || this.userData.exact !== null || this.userData.list.length > 0) {
        // 退场中的模块若无任何数据则不渲染，避免对滑瞬间闪出「没有找到相关用户」
        this.UserResults()
      }
    }
    .width('100%')
  }

  /** 模块页横向位移（百分比）：当前页用 inOffset，退场页用 outOffset */
  private moduleX(page: number): string {
    if (page === this.activeModule) {
      return `${this.inOffset}%`;
    }
    return `${this.outOffset}%`;
  }

  /** 模块页层级：进场页盖在退场页之上 */
  private moduleZ(page: number): number {
    return page === this.activeModule ? 1 : 0;
  }

  /** 内容滚动层（官方壳 TabContent 与手写兜底分支共用）。
   *  搜索后内容区 = 模块对滑 Stack：同时渲染「退场页(prevModule)+当前页(activeModule)」两层，
   *  以整屏宽(100%)百分比互斥位移——与首页底栏切换动画同款手法，替代引擎转场在滚动内容上的叠层错乱 */
  @Builder
  ContentLayer() {
    Scroll(this.scroller) {
      Column() {
        // 首屏内容让位：悬浮顶栏下方初始留白
        Column()
          .width('100%')
          .height(HEADER_TOP_SPACE)
        if (!this.hasSearchedOnce) {
          this.GuideBuilder()
        } else {
          Stack() {
            // 每个模块固定一个专属节点（退场/进场由该节点自身的位移表达），与首页底栏同款
            if (this.prevModule === 0 || this.activeModule === 0) {
              Column() {
                this.ForumPageBody()
              }
              .width('100%')
              .translate({ x: this.moduleX(0) })
              .zIndex(this.moduleZ(0))
            }
            if (this.prevModule === 1 || this.activeModule === 1) {
              Column() {
                this.PostPageBody()
              }
              .width('100%')
              .translate({ x: this.moduleX(1) })
              .zIndex(this.moduleZ(1))
            }
            if (this.prevModule === 2 || this.activeModule === 2) {
              Column() {
                this.UserPageBody()
              }
              .width('100%')
              .translate({ x: this.moduleX(2) })
              .zIndex(this.moduleZ(2))
            }
          }
          .width('100%')
          .alignContent(Alignment.Top)
        }
      }
      .width('100%')
      .padding({ bottom: BOTTOM_BAR_SPACE })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    // Scroll 在内容不足一屏时默认垂直居中（搜人等结果少时表现为内容悬在屏幕中部），
    // 显式对齐到顶部：少结果靠顶显示，多结果滚动能力不受影响
    .align(Alignment.TopStart)
    .onReachEnd(() => this.onReachBottom())
    .blendMode(BlendMode.SRC_OVER, BlendApplyType.OFFSCREEN)
    .overlay(this.TopFadeOverlay())
  }

  /** 手写兜底底栏（materialSupported=false 时）：真模糊磨砂 + 半透明白底 + 白描边 + 投影
   *  （页面主体 systemMaterial 不渲染，仅 API26 以下环境需要此分支） */
  @Builder
  LegacyModuleBar() {
    Row() {
      Row() {
        this.ModuleSegBar()
      }
      .width('calc(100% - 48vp)')
      .height(74)
      .backgroundColor(this.isDark ? '#3DFFFFFF' : '#66FFFFFF')
      .border({ width: 0.5, color: Theme.manualGlassBorder() })
      .backgroundBlurStyle(BlurStyle.Regular, { scale: 0.85 })
      .borderRadius(37)
      .shadow({
        radius: 24,
        color: this.isDark ? '#55000000' : '#30101824',
        offsetY: 8
      })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Bottom)
    .padding({ bottom: 30 })
    .hitTestBehavior(HitTestMode.Transparent)
    .zIndex(3)
  }

  build() {
    if (SEARCH_OFFICIAL_TITLE_BAR && this.materialSupported) {
      // 官方槽位路径（§6.10 同机制）：Navigation + 自定义 title（height 98，与改造前悬浮栏几何一致），
      // 顶部返回钮 / 搜索框 / 搜索钮三元素进槽吃官方沉浸材质；
      // 二级路由页判据带 materialSupported：低版本 / 关闭沉浸光感时自动回退自绘真模糊路径，不会出现「槽位里没有玻璃」
      Navigation() {
        this.SearchRoot()
      }
      .title({ builder: this.SearchTitleBar(), height: SEARCH_TITLE_BAR_HEIGHT },
        { barStyle: BarStyle.STACK, backgroundColor: Color.Transparent })
      .mode(NavigationMode.Stack)
      .hideTitleBar(false)
      .hideBackButton(true)
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Transparent)
      .clip(false)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    } else {
      // 兜底路径：改造前原样（页面主体悬浮栏 FloatingHeader + 自绘真模糊玻璃）
      this.SearchRoot()
    }
  }

  /** 页面主体层：原 build() 根 Stack 原样抽成（背景 + 官方底部 Tabs 壳 / 手写兜底底栏）。
   *  顶部悬浮栏仅在兜底路径挂在层内；槽位路径由 Navigation.title 承载（SearchTitleBar）。 */
  @Builder
  SearchRoot() {
    Stack({ alignContent: Alignment.Top }) {
      // 背景
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(Theme.bg(this.isDark))

      // 内容层 + 底部模块栏：
      // API26+ 真机沉浸光感走官方 Tabs 悬浮条壳（底栏入 .tabBar() 槽位，官方材质才渲染，与首页同一机制）；
      // 其余环境走原手写叠放路径（内容层 + 真模糊玻璃底栏），与定稿几何一致
      if (this.materialSupported) {
        this.ImmersiveShell()
      } else {
        this.ContentLayer()
        this.LegacyModuleBar()
      }

      // 兜底路径才挂自绘顶部悬浮栏；槽位路径由 Navigation.title 承载（SearchTitleBar）
      if (!(SEARCH_OFFICIAL_TITLE_BAR && this.materialSupported)) {
        this.FloatingHeader()
      }
    }
    .width('100%')
    .height('100%')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .onAreaChange((_oldValue: Area, newValue: Area) => {
      const width = newValue.width as number;
      if (width > 0) {
        this.currentWidth = width;
      }
      // 形态变化兜底（横竖屏 / 分屏拖宽：§4.7，与 §4.8 T-B 同款同点追加）；窗口实值优先（小窗 display ≠ 窗口）
      this.refreshFormMetrics(width, newValue.height as number);
    })
  }
}
