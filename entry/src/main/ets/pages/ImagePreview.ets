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
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileIo } from '@kit.CoreFileKit';
import { HttpClient } from '../network/HttpClient';
import { TiebaService, ThreadDetailResult } from '../service/TiebaService';
import { FloorItem } from '../model/DataModel';
import { Theme, Spacing, Radius, isDarkMode, MaterialManager, fs } from '../common/Theme';

/**
 * 图片流式补页一次触发的最大请求页数：楼层页里可能有整页无图（纯文字楼层），
 * 需要连续翻页才能凑到新图；限 2 页既避免"滑一下拉十页"，也保证多数情况一次触发即出图。
 */
const MAX_STREAM_FETCH_PER_TRIGGER: number = 2;
/**
 * 流式补页的会话上限（相对打开浏览时的已加载页码）：防极端长帖（数百页）在浏览页
 * 无限翻页拖垮流量；到达上限即视作"到底"，行为与改造前一致（停在已补齐的图片上）。
 */
const MAX_STREAM_PAGES: number = 20;

@Entry
@Component
struct ImagePreview {
  @State urls: string[] = [];
  @State currentIndex: number = 0;
  @State isDark: boolean = isDarkMode();
  @StorageLink('fontScale') fontScale: number = 1.0;
  /** 页面可见时自增，强制组件重建使字号实时生效 */
  @State fontSizeTick: number = 0;
  // ===== 图片流式补页（2026-09-17）=====
  // 由 ThreadDetail 打开浏览时随路由参数带入分页上下文，滑到已加载图片末尾就继续拉后续楼层页，
  // 追加这些楼层（含其楼中楼）的图片，使用户不需先滚回列表加载楼层才能滑到那张图。
  /** 正在补页（顶栏计数胶囊显示"加载中"，并作为并发防重） */
  @State streamingMore: boolean = false;
  /** 是否已无更多可补页（无上下文参数 / 已到总页 / 已到会话上限） */
  @State streamEnded: boolean = true;
  /** 帖子 id（空串=不带补页能力，例如非帖子详情页调用本页） */
  private streamTid: string = '';
  private streamSortType: number = 0;
  private streamSeeLz: boolean = false;
  private streamForumId: string = '';
  private streamCommentRn: number = 3;
  /** 下一个待补的楼层页码；streamEnded 为 true 时无意义 */
  private nextStreamPage: number = 0;
  /** 本次浏览允许补到的最大页码（totalPage 与会话上限取小） */
  private maxStreamPage: number = 0;

  onPageShow(): void {
    this.fontSizeTick++;
  }
  @State saving: boolean = false;
  @State showControls: boolean = true;
  @State viewportWidth: number = 360;
  @State viewportHeight: number = 800;
  @State zoomScale: number = 1;
  @State panX: number = 0;
  @State panY: number = 0;
  /** Route-safe preview entrance/exit: it never depends on a retained list item's coordinates. */
  @State previewOpacity: number = 0;
  @State previewScale: number = 0.96;

  private pinchBaseScale: number = 1;
  private pinchBasePanX: number = 0;
  private pinchBasePanY: number = 0;
  private pinchCenterX: number = 180;
  private pinchCenterY: number = 400;
  private panStartX: number = 0;
  private panStartY: number = 0;
  private panBaseX: number = 0;
  private panBaseY: number = 0;
  private dragReady: boolean = false;
  private isClosing: boolean = false;
  private context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;

  aboutToAppear(): void {
    MaterialManager.init();
    this.hideStatusBar();
    const params = this.getUIContext().getRouter().getParams() as Record<string, Object>;
    const routeUrls: Object | undefined = params ? params.urls : undefined;
    if (Array.isArray(routeUrls)) {
      this.urls = (routeUrls as Object[])
        .map((item: Object) => `${item}`)
        .filter((item: string) => item.length > 0);
    } else if (typeof routeUrls === 'string') {
      this.urls = routeUrls.split(',')
        .filter((item: string) => item.length > 0)
        .map((item: string) => decodeURIComponent(item));
    } else if (params && typeof params.url === 'string') {
      this.urls = [decodeURIComponent(`${params.url}`)];
    }
    if (params && params.index !== undefined) {
      this.currentIndex = Number(params.index) || 0;
    }
    this.isDark = isDarkMode();
    // 流式补页上下文：只有从帖子详情页带上下文进来才有补页能力，其它调用点（单图预览等）保持原行为
    this.initImageStream(params);
    // 缓冲①：打开即预取下一页，滑到最后一张时数据大概率已在路上
    if (!this.streamEnded) {
      TiebaService.getInstance().prefetchThreadNextPage(
        this.streamTid, this.nextStreamPage - 1, this.streamSortType, this.streamSeeLz,
        this.streamForumId, this.streamCommentRn);
    }
    // 缓冲②：初始位置已贴近已加载图片末尾（例如从中部楼层点开靠后的一张图）时立即补一页，
    // 否则首屏就是"最后一张"、要等用户先滑动一次才触发
    if (this.currentIndex >= this.urls.length - 3) {
      this.appendStreamPage();
    }
    const sharedElementReady: boolean = params !== undefined && `${params.sharedElementReady}` === 'true';
    if (sharedElementReady) {
      // ThreadDetail 的同树共享元素舞台已完成到全屏的最后一帧；这里直接承接，避免二次缩放。
      this.previewOpacity = 1;
      this.previewScale = 1;
    } else {
      this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut }, (): void => {
        this.previewOpacity = 1;
        this.previewScale = 1;
      });
    }
  }

  /**
   * 解析路由带入的补页上下文（ThreadDetail.ImageGrid 跳转时携带）。
   * 缺任一关键参数即判定"无补页能力"，streamEnded 保持 true，浏览行为与改造前完全一致。
   */
  private initImageStream(params: Record<string, Object> | undefined): void {
    if (!params) {
      return;
    }
    const tid: string = params.tid !== undefined ? `${params.tid}`.trim() : '';
    const loadedPage: number = params.loadedPage !== undefined ? Number(params.loadedPage) || 0 : 0;
    const totalPage: number = params.totalPage !== undefined ? Number(params.totalPage) || 0 : 0;
    if (tid.length === 0 || loadedPage <= 0 || totalPage <= loadedPage) {
      return;
    }
    this.streamTid = tid;
    this.streamSortType = params.sortType !== undefined ? Number(params.sortType) || 0 : 0;
    this.streamSeeLz = `${params.seeLz}` === 'true';
    this.streamForumId = params.forumId !== undefined ? `${params.forumId}` : '';
    this.streamCommentRn = params.commentRn !== undefined ? Number(params.commentRn) || 3 : 3;
    this.nextStreamPage = loadedPage + 1;
    this.maxStreamPage = Math.min(totalPage, loadedPage + MAX_STREAM_PAGES);
    this.streamEnded = false;
  }

  aboutToDisappear(): void {
    this.restoreStatusBar();
  }

  private async hideStatusBar(): Promise<void> {
    try {
      const win = await window.getLastWindow(this.context);
      await win.setWindowSystemBarEnable(['navigation']);
    } catch (e) {
    }
  }

  private async restoreStatusBar(): Promise<void> {
    try {
      const win = await window.getLastWindow(this.context);
      await win.setWindowSystemBarEnable(['status', 'navigation']);
    } catch (e) {
    }
  }

  build() {
    Stack() {
      if (this.urls.length > 0) {
        Swiper() {
          ForEach(this.urls, (url: string, idx: number) => {
            Stack() {
              // 图片节点常驻：缩放/平移只改属性，节点永不销毁重建，
              // 双击放大/缩回瞬间不再重新解码位图，消除"闪一下"
              Image(url)
                .width('100%')
                .height('100%')
                .objectFit(ImageFit.Contain)
                .scale({ x: this.getScale(idx), y: this.getScale(idx) })
                .translate({ x: this.getPanX(idx), y: this.getPanY(idx) })

              // 透明手势层：只切换手势集合，不触碰图片节点生命周期
              if (idx === this.currentIndex && this.getScale(idx) > 1.05) {
                // 放大态：双击缩小 + 捏合缩放 + 拖动平移 + 单击控制条
                Stack()
                  .width('100%')
                  .height('100%')
                  .gesture(
                    GestureGroup(
                      GestureMode.Exclusive,
                      TapGesture({ count: 2 }).onAction(() => { this.toggleZoom(); }),
                      PinchGesture({ fingers: 2, distance: 5 })
                        .onActionStart((event: GestureEvent) => { this.startPinch(event); })
                        .onActionUpdate((event: GestureEvent) => { this.updatePinch(event); })
                        .onActionEnd(() => { this.finishZoom(); }),
                      PanGesture({ fingers: 1, direction: PanDirection.All, distance: 3 })
                        .onActionStart((event: GestureEvent) => { this.startPan(event); })
                        .onActionUpdate((event: GestureEvent) => { this.updatePan(event); })
                        .onActionEnd((event: GestureEvent) => { this.finishPan(event); }),
                      TapGesture({ count: 1 }).onAction(() => { this.showControls = !this.showControls; }),
                      LongPressGesture({ fingers: 1, repeat: false, duration: 350 })
                        .onAction((): void => { this.showSaveControls(); })
                    )
                  )
              } else {
                // 未放大态：不挂 Pan，水平滑动让给 Swiper 翻页
                Stack()
                  .width('100%')
                  .height('100%')
                  .gesture(
                    GestureGroup(
                      GestureMode.Exclusive,
                      TapGesture({ count: 2 }).onAction(() => {
                        if (idx === this.currentIndex) this.toggleZoom();
                      }),
                      PinchGesture({ fingers: 2, distance: 5 })
                        .onActionStart((event: GestureEvent) => { if (idx === this.currentIndex) this.startPinch(event); })
                        .onActionUpdate((event: GestureEvent) => { if (idx === this.currentIndex) this.updatePinch(event); })
                        .onActionEnd(() => { if (idx === this.currentIndex) this.finishZoom(); }),
                      TapGesture({ count: 1 }).onAction(() => {
                        this.showControls = !this.showControls;
                      }),
                      LongPressGesture({ fingers: 1, repeat: false, duration: 350 })
                        .onAction((): void => { this.showSaveControls(); })
                    )
                  )
              }
            }
            .width('100%')
            .height('100%')
            .onAreaChange((_oldArea: Area, newArea: Area) => {
              if (idx === this.currentIndex) {
                const w = Math.max(1, Number(newArea.width));
                const h = Math.max(1, Number(newArea.height));
                this.viewportWidth = w;
                this.viewportHeight = h;
                this.panX = this.clampPanX(this.panX, this.zoomScale);
                this.panY = this.clampPanY(this.panY, this.zoomScale);
              }
            })
          }, (url: string, idx: number) => `${idx}_${url}`)
        }
        .index(this.currentIndex)
        .vertical(false)
        .autoPlay(false)
        .indicator(false)
        .itemSpace(0)
        .curve(Curve.EaseOut)
        .duration(220)
        .onChange((index: number) => {
          this.currentIndex = index;
          this.resetZoom();
          // 流式补页触发：距已加载图片末尾还剩 3 张时开始拉下一页，尽量让用户滑到头时新图已就位
          if (index >= this.urls.length - 3) {
            this.appendStreamPage();
          }
        })
        .width('100%')
        .height('100%')
      }

      if (this.showControls) {
        Column() {
          Row() {
            Stack() {
              // 补页中追加"加载中"后缀：长帖补页有网络耗时，需给出可见反馈（不新增胶囊、不改几何）
              Text(this.streamingMore
                ? `${this.currentIndex + 1} / ${this.urls.length} · 加载中`
                : `${this.currentIndex + 1} / ${this.urls.length}`)
                .fontSize(fs(14, this.fontScale))
                .fontColor(Color.White)
            }
            .backgroundColor(Theme.glassControlSolid(true))
            .border({ width: 0.5, color: Theme.glassControlLine(true) })
            .shadow({ radius: 8, color: '#33000000', offsetY: 1 })
            // 圆角 26：与全局卡片统一口径（本胶囊高约 28vp，圆角已被裁为全圆，视觉不变）
            .borderRadius(26)
            .padding({ left: 12, right: 12, top: 4, bottom: 4 })

            Blank()
          }
          .width('100%')
          .padding({ left: Spacing.lg, right: Spacing.lg, top: 12, bottom: 10 })

          Blank().layoutWeight(1)

          Row({ space: 12 }) {
            Blank().layoutWeight(1)
            Stack() {
              SymbolGlyph($r('sys.symbol.xmark'))
                .fontColor([Color.White])
                .fontSize(fs(20, this.fontScale))
            }
            .width(48)
            .height(48)
            .borderRadius(24)
            .backgroundColor(Theme.glassControlSolid(true))
            .border({ width: 0.5, color: Theme.glassControlLine(true) })
            .shadow({ radius: 12, color: '#40000000', offsetY: 2 })
            .onClick(() => { this.closePreview(); })

            // 保存改用系统安全控件 SaveButton：点击即临时获得图库写入授权（约 10 秒），
            // 因此无需在 module.json5 声明 READ/WRITE_IMAGEVIDEO，也无需运行时弹权限申请。
            // 外观为 48×48 实底圆钮（与左侧关闭钮逐项一致：同色实底 + 0.5vp 白描边 + 同款阴影），
            // 只把内层图标换成系统保存图标。
            Stack() {
              SaveButton({
                icon: SaveIconStyle.LINES,
                buttonType: ButtonType.Circle
              })
                .iconSize(fs(24, this.fontScale))
                .iconColor(Color.White)
                // 实底（不用 Color.Transparent）：安全控件自带不透明背托，透明底会被系统判为非法样式而回退，
                // 观感变成与外壳割裂的纯黑圆盘；改传不透明实底后与背托同源，和关闭钮逐项一致
                // （坑 29：backgroundColor 属安全控件白名单，材质类属性则不在白名单，禁止挂）
                .backgroundColor(Theme.glassControlSolid(true))
                .borderWidth(0)
                // 44 < 外壳 48：border 绘制在子节点之下，控件填满会把外壳 0.5vp 白描边整圈盖掉，缩小后描边露出
                .width(44)
                .height(44)
                .enabled(this.urls.length > 0)
                .onClick(async (_event: ClickEvent, result: SaveButtonOnClickResult) => {
                  if (this.saving || this.urls.length === 0) {
                    return;
                  }
                  if (result !== SaveButtonOnClickResult.SUCCESS) {
                    this.getUIContext().getPromptAction().showToast({ message: '未获得保存授权，请重试' });
                    return;
                  }
                  await this.saveCurrentImage();
                })
              if (this.saving) {
                LoadingProgress()
                  .width(20)
                  .height(20)
                  .color(Color.White)
              }
            }
            .width(48)
            .height(48)
            .borderRadius(24)
            .backgroundColor(Theme.glassControlSolid(true))
            .border({ width: 0.5, color: Theme.glassControlLine(true) })
            .shadow({ radius: 12, color: '#40000000', offsetY: 2 })
            .clip(true)
          }
          .width('100%')
          .padding({ left: Spacing.lg, right: Spacing.lg, bottom: 28 })
        }
        .width('100%')
        .height('100%')
        .alignItems(HorizontalAlign.Start)
        .hitTestBehavior(HitTestMode.Transparent)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Black)
    .opacity(this.previewOpacity)
    .scale({ x: this.previewScale, y: this.previewScale })
    .renderGroup(true)
  }

  private getScale(idx: number): number {
    return idx === this.currentIndex ? this.zoomScale : 1;
  }

  private closePreview(): void {
    if (this.isClosing) {
      return;
    }
    this.isClosing = true;
    this.getUIContext().animateTo({ duration: 160, curve: Curve.EaseIn }, (): void => {
      this.previewOpacity = 0;
      this.previewScale = 0.98;
    });
    setTimeout((): void => {
      this.getUIContext().getRouter().back();
    }, 160);
  }

  /**
   * Gallery writes require a user-activated SaveButton security component.
   * Long press therefore reveals that component instead of attempting an
   * unauthorized background write; one tap on the visible save icon completes
   * the platform-authorized save operation.
   */
  private showSaveControls(): void {
    this.showControls = true;
    this.getUIContext().getPromptAction().showToast({ message: '点击右下角保存按钮即可保存到相册' });
  }

  private getPanX(idx: number): number {
    return idx === this.currentIndex ? this.panX : 0;
  }

  private getPanY(idx: number): number {
    return idx === this.currentIndex ? this.panY : 0;
  }

  private toggleZoom(): void {
    if (this.zoomScale > 1.05) {
      // 缩回原位：动画平滑回正
      this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut }, () => {
        this.zoomScale = 1;
        this.panX = 0;
        this.panY = 0;
      });
      this.dragReady = false;
    } else {
      // 双击放大：动画平滑放大到 2x
      this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut }, () => {
        this.zoomScale = 2;
        this.panX = this.clampPanX(this.panX, this.zoomScale);
        this.panY = this.clampPanY(this.panY, this.zoomScale);
      });
    }
  }

  private startPinch(event: GestureEvent): void {
    this.pinchBaseScale = this.zoomScale;
    this.pinchBasePanX = this.panX;
    this.pinchBasePanY = this.panY;
    this.pinchCenterX = Number(event.pinchCenterX);
    this.pinchCenterY = Number(event.pinchCenterY);
  }

  private updatePinch(event: GestureEvent): void {
    const rawScale: number = this.pinchBaseScale * Number(event.scale);
    const nextScale: number = Math.max(1, Math.min(4, rawScale));
    const centerX: number = Number(event.pinchCenterX);
    const centerY: number = Number(event.pinchCenterY);
    const baseScale: number = Math.max(0.01, this.pinchBaseScale);
    const scaleRatio: number = nextScale / baseScale;
    const baseCenterX: number = this.viewportWidth / 2;
    const baseCenterY: number = this.viewportHeight / 2;
    const contentX: number = (this.pinchBasePanX + this.pinchCenterX - baseCenterX) / baseScale;
    const contentY: number = (this.pinchBasePanY + this.pinchCenterY - baseCenterY) / baseScale;
    const nextPanX: number = (centerX - baseCenterX) - contentX * nextScale;
    const nextPanY: number = (centerY - baseCenterY) - contentY * nextScale;
    this.zoomScale = nextScale;
    this.panX = this.clampPanX(nextPanX, nextScale);
    this.panY = this.clampPanY(nextPanY, nextScale);
  }

  private finishZoom(): void {
    if (this.zoomScale < 1.05) {
      this.zoomScale = 1;
    }
    if (this.zoomScale === 1) {
      this.panX = 0;
      this.panY = 0;
    } else {
      this.panX = this.clampPanX(this.panX, this.zoomScale);
      this.panY = this.clampPanY(this.panY, this.zoomScale);
    }
  }

  private startPan(event: GestureEvent): void {
    this.panStartX = event.offsetX;
    this.panStartY = event.offsetY;
    this.panBaseX = this.panX;
    this.panBaseY = this.panY;
    this.dragReady = this.zoomScale > 1.05;
  }

  private updatePan(event: GestureEvent): void {
    if (this.dragReady && this.zoomScale > 1.05) {
      this.panX = this.clampPanX(this.panBaseX + event.offsetX - this.panStartX, this.zoomScale);
      this.panY = this.clampPanY(this.panBaseY + event.offsetY - this.panStartY, this.zoomScale);
    }
  }

  private finishPan(event: GestureEvent): void {
    if (this.dragReady && this.zoomScale > 1.05) {
      this.panX = this.clampPanX(this.panX, this.zoomScale);
      this.panY = this.clampPanY(this.panY, this.zoomScale);
      this.dragReady = false;
    }
  }

  private clampPanX(value: number, scale: number): number {
    const limit: number = Math.max(0, (this.viewportWidth * Math.max(1, scale - 1)) / 2);
    return Math.max(-limit, Math.min(limit, value));
  }

  private clampPanY(value: number, scale: number): number {
    const limit: number = Math.max(0, (this.viewportHeight * Math.max(1, scale - 1)) / 2);
    return Math.max(-limit, Math.min(limit, value));
  }

  private resetZoom(): void {
    this.zoomScale = 1;
    this.panX = 0;
    this.panY = 0;
    this.dragReady = false;
  }

  /**
   * 流式补页（2026-09-17）：拉取后续楼层页，把其中的图片追加到 `urls`。
   * - 复用详情页同一套分页参数与同一份"下一页"缓存（`takeThreadNextPage`），顺序口径与
   *   `ThreadDetail.collectAllImages()` 完全一致：逐楼层 images → 该楼 comments[].images。
   *   刻意不含 `result.detail.images`：那是主楼（第 1 页）内容，打开浏览时已随 urls 带入，
   *   若每页都收会造成主楼图片重复。
   * - 单次触发最多翻 `MAX_STREAM_FETCH_PER_TRIGGER` 页：楼层页可能整页无图（纯文字楼层），
   *   需连续翻页才能凑到新图；凑到即停，剩余交给下一次滑动触发，避免"滑一下就拉好几页"。
   * - 失败静默：保持已加载图片可用，用户滑到末尾会再次触发（自然重试），不弹错误打断浏览。
   */
  private async appendStreamPage(): Promise<void> {
    if (this.streamingMore || this.streamEnded) {
      return;
    }
    this.streamingMore = true;
    try {
      let fetched: number = 0;
      while (fetched < MAX_STREAM_FETCH_PER_TRIGGER && !this.streamEnded) {
        fetched++;
        const page: number = this.nextStreamPage;
        const cached: ThreadDetailResult | undefined =
          TiebaService.getInstance().takeThreadNextPage(this.streamTid, this.streamSortType, this.streamSeeLz, page);
        const result: ThreadDetailResult = cached !== undefined
          ? cached
          : await TiebaService.getInstance().fetchThreadDetail(
            this.streamTid, page, this.streamSortType, this.streamSeeLz, this.streamForumId, this.streamCommentRn, 0);
        // 游标先行推进：本页即使无图也必须前进，否则会在纯文字页上原地打转
        this.nextStreamPage = page + 1;
        if (this.nextStreamPage > this.maxStreamPage) {
          this.streamEnded = true;
        }
        const fresh: string[] = this.extractStreamImages(result.floors ?? []);
        if (fresh.length > 0) {
          this.urls = [...this.urls, ...fresh];
          break;
        }
      }
    } catch (e) {
      console.error('[IMGSTREAM] 补页失败:', (e as Error).message);
    } finally {
      this.streamingMore = false;
    }
    // 缓冲：本次补完后立刻预取下一页，令下一次滑动直接命中内存缓存（与详情页共用同一份缓存，
    // 返回详情页继续下滑时也能命中，等于顺带帮忙预取）
    if (!this.streamEnded) {
      TiebaService.getInstance().prefetchThreadNextPage(
        this.streamTid, this.nextStreamPage - 1, this.streamSortType, this.streamSeeLz,
        this.streamForumId, this.streamCommentRn);
    }
  }

  /**
   * 从楼层页结果提取图片，顺序与 `ThreadDetail.collectAllImages()` 逐项一致
   * （楼图 → 该楼楼中楼图）。空串过滤仅为防御：空 url 不可渲染，正常解析不应产生。
   */
  private extractStreamImages(floors: FloorItem[]): string[] {
    const out: string[] = [];
    for (const floor of floors) {
      if (floor.images && floor.images.length > 0) {
        out.push(...floor.images);
      }
      if (floor.comments) {
        for (const comment of floor.comments) {
          if (comment.images && comment.images.length > 0) {
            out.push(...comment.images);
          }
        }
      }
    }
    return out.filter((url: string) => url.length > 0);
  }

  private async saveCurrentImage(): Promise<void> {
    if (this.urls.length === 0 || this.saving) {
      return;
    }
    this.saving = true;
    let createdUri: string = '';
    try {
      const helper = photoAccessHelper.getPhotoAccessHelper(this.context);
      // SaveButton 的临时授权窗口很短（约 10 秒），因此先在窗口内建好媒体库资源并拿到 fd，
      // 之后的网络下载与写文件不再受该窗口限制。
      createdUri = await helper.createAsset(photoAccessHelper.PhotoType.IMAGE, 'jpg');
      const dest = await fileIo.open(createdUri, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);
      try {
        const imageUrl: string = this.urls[this.currentIndex];
        const bytes: ArrayBuffer = await HttpClient.getBinary(imageUrl, {
          'Accept': 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
          'Referer': 'https://tieba.baidu.com/'
        });
        if (bytes.byteLength === 0) {
          throw new Error('图片内容为空');
        }
        await fileIo.write(dest.fd, bytes);
      } finally {
        await fileIo.close(dest);
      }
      this.getUIContext().getPromptAction().showToast({ message: '已保存到图库' });
    } catch (e) {
      // 写入失败时清掉刚建好的空资源，避免图库里残留空白图片
      if (createdUri.length > 0) {
        try {
          await photoAccessHelper.MediaAssetChangeRequest.deleteAssets(this.context, [createdUri]);
        } catch (cleanupError) {
        }
      }
      this.getUIContext().getPromptAction().showToast({ message: '保存失败，请重试' });
    } finally {
      this.saving = false;
    }
  }
}
