import { WEIBO_TAP_MAX_MOVEMENT } from '../common/WeiboTabSwipe';
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

import { Theme, Spacing, Radius, isDarkMode, ImmBlur, ImmMaterial, fs } from '../common/Theme';
import { ImageCache } from '../cache/ImageCache';
import { Haptic } from '../common/Haptic';
import { WeiboVideoPlayer } from './WeiboVideoPlayer';
import { WeiboRichTextView } from './WeiboRichTextView';
import { curves, display } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { hdsEffect } from '@kit.UIDesignKit';

const LOG_DOMAIN: number = 0x0A01;
const TAG: string = 'TiebaImgCard';
const MAX_URL_LOG: number = 120;

function shortUrl(url: string): string {
  return url.length > MAX_URL_LOG ? url.substring(0, MAX_URL_LOG) + '...' : url;
}

// 图片预下载全局并发闸门：限制同时下载的图片数，避免首屏大量卡片图片同时请求抢占带宽，
// 让列表正文先渲染、图片逐个到达（下载本身仍在 ImageCache 内以沙箱缓存串起复用）
const IMAGE_PRELOAD_CONCURRENCY: number = 8;
let imagePreloadActive: number = 0;
const imagePreloadWaiters: Array<() => void> = [];

function acquireImagePreloadSlot(): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    if (imagePreloadActive < IMAGE_PRELOAD_CONCURRENCY) {
      imagePreloadActive++;
      resolve();
    } else {
      imagePreloadWaiters.push(resolve);
    }
  });
}

function releaseImagePreloadSlot(): void {
  const next: (() => void) | undefined = imagePreloadWaiters.shift();
  if (next !== undefined) {
    next();
  } else {
    imagePreloadActive--;
  }
}

// 用于 @Prop 的帖子卡片数据结构
export interface ThreadItemData {
  tid: string;
  postId?: string;       // 首个楼层ID，用于点赞
  forumId?: string;
  title: string;
  forumName: string;
  forumAvatar?: string;
  author: string;
  authorAvatar?: string;
  authorId?: string;     // 作者用户 ID，用于头像点击跳转用户主页
  replyNum: number;
  likeCount?: number;
  isLiked?: boolean;     // 是否已点赞
  abstract: string;
  /** Optional original author shown before a forwarded social post body. */
  repostAuthor?: string;
  /** Uses content-first social typography instead of a forum thread headline. */
  isSocialPost?: boolean;
  firstImage: string;
  images?: string[];
  /** Optional public MP4 stream. Empty for ordinary text/image posts. */
  videoUrl?: string;
  /** Poster shown by the native video player while a stream prepares. */
  videoCoverUrl?: string;
  videoAspectRatio?: number;
  createTime: string;
  isTop: boolean;
  isGood?: boolean;
}

// 分享回调传入的帖子 payload，保证ArkTS对象字面量类型安全（禁止未声明类型的内联对象）
export interface ThreadSharePayload {
  tid: string;
  title: string;
  forumName: string;
  author: string;
  abstract: string;
  firstImage: string;
}

/**
 * 通用加载态组件：居中转圈 + 文案
 */
@Component
export struct LoadingView {
  @Prop message: string | Resource = '加载中...';
  @StorageLink('fontScale') fontScale: number = 1.0;

  build() {
    Column({ space: Spacing.md }) {
      LoadingProgress()
        .width(36)
        .height(36)
        .color(Theme.brand())
      Text(this.message)
        .fontSize(fs(14, this.fontScale))
        .fontColor(Theme.textSecondary(isDarkMode()))
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor(Theme.bg(isDarkMode()))
  }
}

/**
 * 空态组件
 */
@Component
export struct EmptyView {
  @Prop message: string | Resource = '暂无内容';
  @Prop icon: string = '📭';
  @BuilderParam action: () => void = this.emptyBuilder;
  @Prop actionText: string = '';
  @StorageLink('fontScale') fontScale: number = 1.0;

  @Builder
  emptyBuilder() {
  }

  build() {
    Column({ space: Spacing.md }) {
      Text(this.icon)
        .fontSize(fs(48, this.fontScale))
      Text(this.message)
        .fontSize(fs(15, this.fontScale))
        .fontColor(Theme.textSecondary(isDarkMode()))
      if (this.actionText.length > 0) {
        Button(this.actionText)
          .fontSize(fs(14, this.fontScale))
          .fontColor($r('sys.color.font_on_primary'))
          .backgroundColor(Theme.manualGlass(isDarkMode(), true))
          .border({ width: 0.5, color: Theme.manualGlassBorder() })
          .shadow(Theme.glassShadowStyle()).backgroundEffect(ImmBlur.accent())
          .systemMaterial(ImmMaterial.accent(isDarkMode()))
          .borderRadius(Radius.full)
          .padding({ left: 20, right: 20, top: 8, bottom: 8 })
          .onClick(() => {
            this.action();
          })
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor(Theme.bg(isDarkMode()))
  }
}

/**
 * 错误态组件：显示错误信息 + 重试按钮
 */
@Component
export struct ErrorView {
  @Prop message: string = '加载失败';
  onRetry: () => void = () => {};
  @StorageLink('fontScale') fontScale: number = 1.0;

  build() {
    Column({ space: Spacing.md }) {
      Text('⚠️')
        .fontSize(fs(44, this.fontScale))
      Text(this.message)
        .fontSize(fs(15, this.fontScale))
        .fontColor(Theme.textSecondary(isDarkMode()))
        .textAlign(TextAlign.Center)
        .padding({ left: 24, right: 24 })
      Button('重试')
        .fontSize(fs(14, this.fontScale))
        .fontColor($r('sys.color.font_on_primary'))
        .backgroundColor(Color.Transparent)
        .shadow(Theme.glassShadowStyle()).backgroundEffect(ImmBlur.accent())
        .systemMaterial(ImmMaterial.accent(isDarkMode()))
        .borderRadius(Radius.full)
        .padding({ left: 24, right: 24, top: 8, bottom: 8 })
        .onClick(() => {
          this.onRetry();
        })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor(Theme.bg(isDarkMode()))
  }
}

/**
 * 置顶帖子卡片（仅显示标题，带置顶徽章）
 */
@Component
export struct PinnedThreadItem {
  @Prop item: ThreadItemData = {
    tid: '', title: '', forumName: '', author: '',
    replyNum: 0, abstract: '', firstImage: '', createTime: '', isTop: false,
  };
  onTap: (tid: string) => void = () => {};
  @StorageLink('fontScale') fontScale: number = 1.0;

  build() {
    Row({ space: 12 }) {
      Text(this.getItem().isGood === true ? '精品' : '置顶')
        .fontSize(fs(13, this.fontScale))
        .fontColor(Color.White)
        .backgroundColor(this.getItem().isGood === true ? Theme.brand() : Theme.badgePin(isDarkMode()))
        .borderRadius(4)
        .padding({ left: 8, right: 8, top: 4, bottom: 4 })

      Text(this.getItem().title)
        .fontSize(fs(15, this.fontScale))
        .fontColor(Theme.textPrimary(isDarkMode()))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .onClick(() => {
      if (this.getItem().tid.length > 0) {
        this.onTap(this.getItem().tid);
      }
    })
  }

  private getItem(): ThreadItemData {
    return this.item;
  }
}

/**
 * 帖子列表单项（新版样式：头像+昵称+时间+标题+内容+图片+操作栏）
 */
@Component
export struct ThreadCard {
  @Prop item: ThreadItemData = {
    tid: '',
    postId: '',
    forumId: '',
    title: '',
    forumName: '',
    forumAvatar: '',
    author: '',
    authorAvatar: '',
    replyNum: 0,
    likeCount: 0,
    isLiked: false,
    abstract: '',
    repostAuthor: '',
    isSocialPost: false,
    firstImage: '',
    images: [],
    videoUrl: '',
    videoCoverUrl: '',
    createTime: '',
    isTop: false,
    isGood: false,
  };
  onTap: (tid: string) => void = () => {};
  /** Optional nested-content action, used by Weibo cards to open the original repost. */
  onAbstractTap: () => void = () => {};
  @Prop abstractIsLink: boolean = false;
  onLike: (tid: string, postId: string, liked: boolean) => void = () => {};
  // 分享回调：由父组件(Index/ThreadList)注入实现，拉起鸿蒙系统分享面板
  onShare: (data: ThreadSharePayload) => void = () => {};
  // 评论回调：由父组件(Index/ThreadList)注入实现，跳转帖子详情
  onComment: (tid: string) => void = () => {};
  // 头像点击回调：由父组件(Index/ThreadList)注入实现，跳转用户主页
  onAvatarTap: (authorId: string, author: string) => void = () => {};
  onTopicTap: (topic: string) => void = () => {};
  onMentionTap: (name: string) => void = () => {};
  /** Parent-owned image navigation; non-Weibo callers retain their existing behavior. */
  onImageTap: (urls: string[], index: number) => void = () => {};
  /**
   * 微博等非贴吧图床直接交给 ArkUI Image 加载。ImageCache 的下载策略带贴吧专用
   * Referer/Cookie，不能用于其它内容源。
   */
  @Prop skipImageCache: boolean = false;
  private videoController: VideoController = new VideoController();
  @State videoLoadFailed: boolean = false;
  @State avatarFailed: boolean = false;

  /**
   * 操作栏收紧判定（docs/TiebaPura阔直屏适配.md，2026-09-15 用户云调试反馈：阔直屏竖 2 列
   * 窄卡下分享/评论/点赞三胶囊「文字图标比按钮大」溢出）。
   * 根因：胶囊 layoutWeight(1) 均分、内容（图标 18 + 内距 6 + 文字 13 号）恒占 ~50vp，
   * 卡宽 < 240 时胶囊被压到 ~55vp 以下内容必溢出（Row 不裁剪、直接画出界）。
   * 触发档位 = 阔直屏竖 2 列（卡 ~210）；平板竖 2 列卡 ~370 / 平板横 3 列 ~408 /
   * 阔直屏横 3 列 ~258 / 手机单列均 > 240 不收紧，平板与手机观感零变化。
   * 卡宽按「屏宽 − 页面左右边距(Spacing.lg×2) − 列间距((列数−1)×Spacing.md)」÷ 列数估算
   * （不求像素准只求相对准，同 PersonalContent 分桶估算口径）。
   */
  private actionCompact(): boolean {
    if (this.cardColumns <= 1) {
      return false;
    }
    try {
      const d: display.Display = display.getDefaultDisplaySync();
      const screenW: number = this.getUIContext().px2vp(d.width);
      const cardW: number =
        (screenW - Spacing.lg * 2 - Spacing.md * (this.cardColumns - 1)) / this.cardColumns;
      return cardW < 240;
    } catch (e) {
      return false;
    }
  }
  /**
   * 图片加载失败标记：任一图加载失败时降级为作者头像缩略 + 失败提示，
   * 避免大图区域显示占位（看起来像"图片没出来"）。
   */
  /**
   * 全局只读列数标记（平板适配文档 §4.2 决策 6）：
   * 仅在多列档（> 1）才比例化卡内几何；单列（手机 / 窄窗）逐像素保持改造前取值。
   * 由各多列页**无条件**写入（单列也写 1），避免跨页残留（§6.1 D1 / D6）。
   */
  @StorageProp('cardColumns') cardColumns: number = 1;
  /** 卡片实测宽度（vp）：媒体几何改按真实卡宽分档，不再依赖全局 cardColumns——
   *  宽窗/折叠屏下搜索页、详情页等单卡全宽场景 cardColumns 可能是别的页写入的残留值，
   *  导致多图格被压成 100vp 小方块、单图被 maxHeight 裁扁（2026-10 用户反馈）。 */
  @State cardWidth: number = 0;
  @State imageFailed: boolean = false;
  /** Press feedback only affects composited properties; card layout remains stable. */
  @State contentScale: number = 1;
  @State contentOpacity: number = 1;
  /** 正在阶梯重试的图片 URL 集合：防 preload/onError/onComplete 多路径对同一 URL 重复启动重试阶梯 */
  private retryingUrls: Set<string> = new Set<string>();
  /**
   * 已下载到沙箱缓存的图片本地路径（file://...）。首次渲染走原 URL（可能命中贴吧防盗链
   * 200×200 占位），后台异步下载到沙箱缓存后写入本表并触发重新渲染，Image 切换到本地路径，
   * 彻底绕开贴吧图床对 Image 组件的防盗链 / UA 拦截。
   */
  @State cachedImageMap: Record<string, string> = {};
  /**
   * 缓存命中后检查自愈：单图渲染失败(imageFailed=true)进入降级占位后,后台异步预下载若终于命中本地缓存,
   * 由 setCachedImage 写入并主动调用本方法。命中所有图后清除 imageFailed,组件切回 Image 分支走本地路径,
   * 实现"图片加载失败"短暂闪烁后自动恢复,而不是永久占位。
   * （替代 @Watch：避免 ArkTS 严格模式下 @Watch 在嵌套 Component 中的解析问题）
   */
  private tryRecoverFromCache(): void {
    if (!this.imageFailed) {
      return;
    }
    const imgs: string[] | undefined = this.item.images;
    if (!imgs || imgs.length === 0) {
      return;
    }
    for (const u of imgs) {
      if (!this.cachedImageMap[u]) {
        return;
      }
    }
    this.imageFailed = false;
  }
  @StorageLink('fontScale') fontScale: number = 1.0;

  /**
   * onError 后重试 ImageCache.resolve（带贴吧 UA/Referer/Cookie + 镜像域候选）。
   * 命中本地缓存时由 setCachedImage 写入并触发 tryRecoverFromCache 自愈检查。
   * v1.21 实抓(0902_154709 / 0902_155150):
   *   - 新发布帖子图片 CDN 异步同步延迟可达 30s+(imgsrc/tiebapic 初次均返回占位);
   *   - v1.20 retryOrFail 中 tryLoad 遇到占位 local==='' 立即 imageFailed=true + return true,
   *     提前退出阶梯重试链 —— 这导致"图片加载失败"在第一次 resolve 失败后就显示,
   *     阶梯重试从未真正执行(0902_155150 日志验证:无 retry HEALED 也无 FINAL FAIL)。
   *   - 修正:占位时返回 false 让阶梯继续,只在所有重试都失败后才 imageFailed。
   *     阶梯序列 [0, 2s, 8s, 30s] 覆盖 0~40s 的 CDN 同步窗口。
   */
  private async retryOrFail(u: string | undefined): Promise<void> {
    if (this.skipImageCache) {
      return;
    }
    if (!u) {
      this.imageFailed = true;
      return;
    }
    // 防重入：同一 URL 只允许一条阶梯(preload / onError / onComplete 可能并发触发)
    if (this.retryingUrls.has(u)) {
      return;
    }
    this.retryingUrls.add(u);
    try {
      const tryLoad = async (): Promise<boolean> => {
        try {
          const local: string = await ImageCache.resolve(u);
          // 占位(local===''):不立即 imageFailed,留给阶梯结束再判定,
          // 给 CDN 异步同步延迟(可达 30s+)留窗口。重复重试仍然有意义。
          if (local === '') {
            ImageCache.debugLog(`card retry PLACEHOLDER continue url=${shortUrl(u)}`);
            return false;
          }
          if (local !== u && !local.startsWith('http')) {
            hilog.info(LOG_DOMAIN, TAG, 'retry healed url=%{public}s', shortUrl(u));
            ImageCache.debugLog(`card retry HEALED url=${shortUrl(u)}`);
            this.setCachedImage(u, local);
            return true;
          }
        } catch (e) {
          /* 重试仍失败,继续阶梯 */
        }
        return false;
      };
      // 阶梯重试序列:立即 + 2s + 8s + 30s,覆盖 ~40s CDN 同步窗口。
      // 第一次延迟 0 不阻塞,直接进入 tryLoad(命中本地缓存场景);后续每次延迟再试。
      const delays: number[] = [0, 2000, 8000, 30000];
      for (const d of delays) {
        if (d > 0) {
          await new Promise<void>((resolve) => setTimeout(resolve, d));
        }
        // v1.22: 仅缓存命中时提前结束。不再以 imageFailed 中断阶梯——
        // 旧 onComplete 会先把占位误判为失败并置位，反过来把重试链提前掐断。
        if (this.cachedImageMap[u]) {
          return; // 已被其它路径自愈
        }
        if (await tryLoad()) {
          return; // 已自愈
        }
      }
      // 阶梯全失败,无论最终是网络失败还是持续占位,统一标记 imageFailed。
      if (!this.cachedImageMap[u]) {
        hilog.error(LOG_DOMAIN, TAG, 'retry final fail url=%{public}s', shortUrl(u));
        ImageCache.debugLog(`card retry FINAL FAIL url=${shortUrl(u)}`);
        this.imageFailed = true;
      }
    } finally {
      this.retryingUrls.delete(u);
    }
  }

  /** 写入本地缓存路径（触发重渲染）+ 检查自愈（替代 @Watch） */
  private setCachedImage(u: string, local: string): void {
    const next: Record<string, string> = {};
    const keys: string[] = Object.keys(this.cachedImageMap);
    for (const k of keys) {
      next[k] = this.cachedImageMap[k];
    }
    next[u] = local;
    this.cachedImageMap = next;
    this.tryRecoverFromCache();
  }

  aboutToAppear(): void {
    this.preloadImages();
  }

  /** 通过 ImageCache（带贴吧 UA + Referer + Cookie）预下载图片到沙箱缓存 */
  private async preloadImages(): Promise<void> {
    if (this.skipImageCache) {
      return;
    }
    const imgs: string[] | undefined = this.item.images;
    if (!imgs || imgs.length === 0) {
      ImageCache.debugLog(`card preload SKIP imgs-empty tid=${this.item.tid}`);
      return;
    }
    ImageCache.debugLog(`card preload START tid=${this.item.tid} n=${imgs.length} u0=${shortUrl(imgs[0])}`);
    // 单图走 resolve（命中即同步返回，未命中阻塞到下载完成），多图经并发闸门预下载
    const tasks: Promise<void>[] = [];
    for (const u of imgs) {
      if (!u || this.cachedImageMap[u]) continue;
      tasks.push((async () => {
        await acquireImagePreloadSlot();
        try {
          const local: string = await ImageCache.resolve(u);
          // v1.21.1 修复：占位(local==='')不再立即 imageFailed,
          // 改为启动阶梯重试 [0, 2s, 8s, 30s],见 retryOrFail。
          // 真图(本地缓存命中或网络成功)走 setCachedImage 自愈。
          if (local !== u && !local.startsWith('http') && local !== '') {
            this.setCachedImage(u, local);
            return;
          }
          if (local === '') {
            ImageCache.debugLog(`card preload PLACEHOLDER schedule-retry url=${shortUrl(u)}`);
            // 启动阶梯重试(不阻塞当前批次其它图片预下载)
            this.retryOrFail(u);
            return;
          }
          ImageCache.debugLog(`card preload resolve-NOCACHE url=${shortUrl(u)}`);
        } catch (e) {
          ImageCache.debugLog(`card preload EXCEPTION url=${shortUrl(u)} err=${JSON.stringify(e)}`);
        } finally {
          releaseImagePreloadSlot();
        }
      })());
    }
    await Promise.all(tasks);
  }

  /** 把原 URL 解析为本地缓存路径（命中）或原 URL（未命中），并确保使用 HTTPS */
  private resolveImgUrl(u: string | undefined): string {
    if (!u) return '';
    const resolved = this.cachedImageMap[u] ?? u;
    if (resolved.startsWith('http://')) {
      return `https://${resolved.substring(7)}`;
    }
    if (resolved.startsWith('//')) {
      return `https:${resolved}`;
    }
    return resolved;
  }

  private resolveAvatarUrl(u: string | undefined): string {
    if (!u) return '';
    const trimmed = u.trim();
    if (trimmed.startsWith('http://')) {
      return `https://${trimmed.substring(7)}`;
    }
    if (trimmed.startsWith('//')) {
      return `https:${trimmed}`;
    }
    return trimmed;
  }

  private getItem(): ThreadItemData {
    return this.item;
  }

  private getImageCount(): number {
    const imgs = this.getItem().images;
    if (imgs && imgs.length > 0) {
      return Math.min(imgs.length, 9);
    }
    return 0;
  }

  /** 卡内媒体区可用宽度：实测卡宽 − 左右各 16 内边距；未测到时按屏宽估算。 */
  private mediaWidth(): number {
    if (this.cardWidth > 0) {
      return this.cardWidth - 32;
    }
    try {
      const d: display.Display = display.getDefaultDisplaySync();
      const screenW: number = this.getUIContext().px2vp(d.width);
      return screenW - Spacing.lg * 2 - 32;
    } catch (e) {
      return 328;
    }
  }

  /** 单图高度上限：窄卡（多列瀑布 ~200vp）等比小图；手机单列档保持 220 基线；
   *  宽卡（折叠屏/平板单卡全宽）放宽到 380，避免 16:10 被裁成扁条。 */
  private singleImageMaxHeight(): number {
    const w: number = this.mediaWidth();
    if (w < 300) {
      return 220;
    }
    if (w < 420) {
      return 220;
    }
    return 380;
  }

  /** 多图格是否走「固定小格」旧档：仅手机单列档（卡宽 < 420）保持改造前的 140/100 固定格高；
   *  更宽的卡一律用 1:1 正方形填满格，格宽即卡宽均分，消灭宽窗下的缝隙与小方块。 */
  private useFixedGridCells(): boolean {
    return this.mediaWidth() < 420;
  }

  private isNarrowMultiColumn(): boolean {
    return this.mediaWidth() < 300;
  }

  private updateContentPress(event?: TouchEvent): void {
    if (event === undefined) {
      return;
    }
    const pressed: boolean = event.type === TouchType.Down;
    this.getUIContext().animateTo({ curve: curves.interpolatingSpring(0, 1, 260, 28) }, (): void => {
      this.contentScale = pressed ? 0.985 : 1;
      this.contentOpacity = pressed ? 0.94 : 1;
    });
  }

  build() {
    Column() {
      // ========== 跳转详情区域：作者→标题→摘要→图片→吧标签（点击跳帖子详情）==========
      Column() {
        // 作者信息行
        Row({ space: 10 }) {
          // 作者头像（独立点击进用户主页；stopPropagation 避免触发整卡跳详情）
          Stack() {
            Text((this.getItem().author && this.getItem().author.length > 0) ? this.getItem().author.charAt(0) : '微')
              .fontSize(fs(18, this.fontScale))
              .fontWeight(FontWeight.Bold)
              .fontColor(Color.White)
            if (this.getItem().authorAvatar && this.getItem().authorAvatar!.length > 0 && !this.avatarFailed) {
              Image(this.resolveAvatarUrl(this.getItem().authorAvatar))
                .width(40)
                .height(40)
                .borderRadius(20)
                .border({ width: 0.5, color: isDarkMode() ? 'rgba(255, 255, 255, 0.12)' : 'rgba(0, 0, 0, 0.08)', radius: 20 })
                .objectFit(ImageFit.Cover)
                .clip(true)
                .onError((err: ImageError) => {
                  hilog.error(LOG_DOMAIN, 'AvatarDebug', 'ThreadCard avatar onError author=%{public}s url=%{public}s',
                    this.getItem().author, this.getItem().authorAvatar);
                  this.avatarFailed = true;
                })
                .onComplete((msg) => {
                  hilog.info(LOG_DOMAIN, 'AvatarDebug', 'ThreadCard avatar onComplete author=%{public}s url=%{public}s w=%{public}d h=%{public}d',
                    this.getItem().author, this.getItem().authorAvatar, msg?.width ?? 0, msg?.height ?? 0);
                })
            }
          }
          .width(40)
          .height(40)
          .borderRadius(20)
          .backgroundColor(Theme.brand())
          .alignContent(Alignment.Center)
          .hitTestBehavior(HitTestMode.Default)
          .onClick(() => {
            this.onAvatarTap(this.getItem().authorId ?? '', this.getItem().author);
          }, WEIBO_TAP_MAX_MOVEMENT)

          // 作者名和时间
          Column({ space: 2 }) {
            Text(this.getItem().author)
              .fontSize(fs(15, this.fontScale))
              .fontWeight(FontWeight.Medium)
              .fontColor(Theme.textPrimary(isDarkMode()))
              .hitTestBehavior(HitTestMode.Default)
              .onClick(() => {
                // 点击作者名跳用户主页（Default 允许拖拽滚动手势穿透到外层滚动组件）
                this.onAvatarTap(this.getItem().authorId ?? '', this.getItem().author);
              }, WEIBO_TAP_MAX_MOVEMENT)
            Text(this.getItem().createTime)
              .fontSize(fs(12, this.fontScale))
              .fontColor(Theme.textTertiary(isDarkMode()))
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 16 })

        // 微博正文使用同一富文本解析器；论坛标题保持原样。
        if (this.getItem().isSocialPost === true) {
          WeiboRichTextView({ text: this.getItem().title, fontSize: fs(16, this.fontScale),
            lineHeight: fs(24, this.fontScale), fontColor: Theme.textPrimary(isDarkMode()),
            maxLines: this.cardColumns > 1 ? 3 : 6,
            onTopicClick: (topic: string): void => { this.onTopicTap(topic); },
            onMentionClick: (name: string): void => { this.onMentionTap(name); }
          }).width('100%').padding({ left: 16, right: 16, top: 8 })
        } else {
        Text(this.getItem().title)
          .fontSize(fs(this.getItem().isSocialPost === true ? 16 : 17, this.fontScale))
          .fontWeight(this.getItem().isSocialPost === true ? FontWeight.Regular : FontWeight.Bold)
          .fontColor(Theme.textPrimary(isDarkMode()))
          .lineHeight(fs(this.getItem().isSocialPost === true ? 24 : 22, this.fontScale))
          .maxLines(this.getItem().isSocialPost === true ? (this.cardColumns > 1 ? 3 : 6) : 2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .padding({ left: 16, right: 16, top: 8 })
        }

        // 正文摘要：多列档降为 2 行（列窄、一屏要放下更多卡），单列逐像素维持现状 4 行
        if (this.getItem().abstract.length > 0) {
          if (this.abstractIsLink) {
            Row() {
              if (this.getItem().isSocialPost === true) {
                WeiboRichTextView({ text: `@${this.getItem().repostAuthor ?? ''}：${this.getItem().abstract}`,
                  fontSize: fs(14, this.fontScale), lineHeight: fs(21, this.fontScale),
                  fontColor: Theme.textPrimary(isDarkMode()), maxLines: this.cardColumns > 1 ? 3 : 6,
                  onTopicClick: (topic: string): void => { this.onTopicTap(topic); },
                  onMentionClick: (name: string): void => { this.onMentionTap(name); }
                }).width('100%')
              } else {
              Text() {
                if (this.getItem().repostAuthor !== undefined && this.getItem().repostAuthor!.length > 0) {
                  Span(`@${this.getItem().repostAuthor!}：`)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(Theme.brand())
                }
                Span(this.getItem().abstract)
                  .fontColor(Theme.textPrimary(isDarkMode()))
              }
              .fontSize(fs(14, this.fontScale))
              .lineHeight(fs(21, this.fontScale))
              .maxLines(this.cardColumns > 1 ? 3 : 6)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              }
            }
            .padding({ left: 10, right: 10, top: 8, bottom: 8 })
            .margin({ left: 16, right: 16, top: 6 })
            .backgroundColor(isDarkMode() ? '#14FFFFFF' : '#06000000')
            .borderRadius(Radius.md)
            .hitTestBehavior(HitTestMode.Default)
            .accessibilityText(`查看${this.getItem().repostAuthor ?? ''}的原微博`)
            .onClick((): void => { this.onAbstractTap(); }, WEIBO_TAP_MAX_MOVEMENT)
          } else {
            Text(this.getItem().abstract)
              .fontSize(fs(14, this.fontScale))
              .fontColor(Theme.textSecondary(isDarkMode()))
              .maxLines(this.cardColumns > 1 ? 2 : 4)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .padding({ left: 16, right: 16, top: 6 })
          }
        }

        // 视频优先用系统 Video 播放器承载，避免将视频帖误当作静态封面图。
        if (this.getItem().videoUrl !== undefined && this.getItem().videoUrl!.length > 0) {
          Column() {
            this.VideoPlayer()
          }
            .width('100%')
            .padding({ left: 16, right: 16, top: 10 })
        }

        // 图片区域
        if (this.getImageCount() > 0) {
          Column() {
            this.ImageGallery()
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 10 })
        }

        // 吧标签
        Row() {
          if (this.getItem().forumName.length > 0) {
            Row({ space: 4 }) {
              // 吧头像
              if (this.getItem().forumAvatar && this.getItem().forumAvatar!.length > 0) {
                Image(this.getItem().forumAvatar!)
                  .width(20)
                  .height(20)
                  .borderRadius(10)
                  .objectFit(ImageFit.Cover)
                  .clip(true)
              }
              Text(this.getItem().forumName)
                .fontSize(fs(13, this.fontScale))
                .fontColor(Theme.textSecondary(isDarkMode()))
            }
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 10 })
      }
      .width('100%')
      .hitTestBehavior(HitTestMode.Default)
      .scale({ x: this.contentScale, y: this.contentScale })
      .opacity(this.contentOpacity)
      .renderGroup(true)
      .onTouch((event?: TouchEvent): void => {
        this.updateContentPress(event);
      })
      .onClick(() => {
        // 点击卡片上半部分（内容区）跳帖子详情；底部三胶囊不在此区域，避免事件互吞
        const tid = this.getItem().tid;
        if (tid.length > 0) {
          this.onTap(tid);
        }
      }, WEIBO_TAP_MAX_MOVEMENT)

      // ========== 操作栏（独立区域）：分享/评论/点赞三胶囊，完全不在跳转详情的点击区域内 ==========
      // 窄卡收紧模式（actionCompact）：图标 15/文字 11/内距 4/高 30/圆角 15/外距 8——
      // 阔直屏竖 2 列卡 ~210vp 时胶囊 ~50vp，原尺寸内容 ~50vp 必溢出（Row 不裁剪直接画出界）
      Row({ space: this.actionCompact() ? 8 : 12 }) {
        // 分享按钮 - 圆角胶囊（玻璃光感背景不变）+ 简约黑色分享图标（与帖子详情页右上角同款 sys.symbol.share）
        Row({ space: this.actionCompact() ? 4 : 6 }) {
          SymbolGlyph($r('sys.symbol.share'))
            .fontSize(fs(this.actionCompact() ? 15 : 18, this.fontScale))
            .fontColor([Theme.textPrimary(isDarkMode())])
          Text('分享')
            .fontSize(fs(this.actionCompact() ? 11 : 13, this.fontScale))
            .fontColor(Theme.textPrimary(isDarkMode()))
        }
        .layoutWeight(1)
        .height(this.actionCompact() ? 30 : 36)
        .justifyContent(FlexAlign.Center)
        .borderRadius(this.actionCompact() ? 15 : 18)
        .backgroundColor(Theme.sheetGlass(isDarkMode()))
        .backgroundBlurStyle(BlurStyle.Regular, { scale: 0.85 })
        .border({ width: 0.5, color: Theme.manualGlassBorder() })
        .shadow(Theme.glassShadowStyle())
        .backgroundEffect(ImmBlur.cardAction())
        .systemMaterial(ImmMaterial.cardAction())
        .onClick(() => {
          const payload: ThreadSharePayload = {
            tid: this.getItem().tid,
            title: this.getItem().title,
            forumName: this.getItem().forumName,
            author: this.getItem().author,
            abstract: this.getItem().abstract,
            firstImage: this.getItem().firstImage
          };
          this.onShare(payload);
        }, WEIBO_TAP_MAX_MOVEMENT)
        
        // 评论按钮 - 玻璃胶囊背景不变 + 实心气泡三点图标 ellipsis_message_fill（与分享 sys.symbol.share 同为填充风格，避免描边图标过细）
        Row({ space: this.actionCompact() ? 4 : 6 }) {
          SymbolGlyph($r('sys.symbol.ellipsis_message_fill'))
            .fontSize(fs(this.actionCompact() ? 15 : 18, this.fontScale))
            .fontColor([Theme.textPrimary(isDarkMode())])
          Text(`${this.getItem().replyNum}`)
            .fontSize(fs(this.actionCompact() ? 11 : 13, this.fontScale))
            .fontColor(Theme.textPrimary(isDarkMode()))
        }
        .layoutWeight(1)
        .height(this.actionCompact() ? 30 : 36)
        .justifyContent(FlexAlign.Center)
        .borderRadius(this.actionCompact() ? 15 : 18)
        .backgroundColor(Theme.sheetGlass(isDarkMode()))
        .backgroundBlurStyle(BlurStyle.Regular, { scale: 0.85 })
        .border({ width: 0.5, color: Theme.manualGlassBorder() })
        .shadow(Theme.glassShadowStyle())
        .backgroundEffect(ImmBlur.cardAction())
        .systemMaterial(ImmMaterial.cardAction())
        .onClick(() => {
          const tid = this.getItem().tid;
          if (tid.length > 0) {
            this.onComment(tid);
          }
        }, WEIBO_TAP_MAX_MOVEMENT)
        
        // 点赞按钮 - 玻璃胶囊背景不变 + 简约心形轮廓/实心SymbolGlyph（匹配参考图一）
        Row({ space: this.actionCompact() ? 4 : 6 }) {
          if (this.getItem().isLiked) {
            SymbolGlyph($r('sys.symbol.heart_fill'))
              .fontSize(fs(this.actionCompact() ? 16 : 19, this.fontScale))
              .fontColor([Theme.textPrimary(isDarkMode())])
          } else {
            SymbolGlyph($r('sys.symbol.heart'))
              .fontSize(fs(this.actionCompact() ? 16 : 19, this.fontScale))
              .fontColor([Theme.textPrimary(isDarkMode())])
          }
          Text(`${this.getItem().likeCount ?? 0}`)
            .fontSize(fs(this.actionCompact() ? 11 : 13, this.fontScale))
            .fontColor(Theme.textPrimary(isDarkMode()))
        }
        .layoutWeight(1)
        .height(this.actionCompact() ? 30 : 36)
        .justifyContent(FlexAlign.Center)
        .borderRadius(this.actionCompact() ? 15 : 18)
        .backgroundColor(Theme.sheetGlass(isDarkMode()))
        .backgroundBlurStyle(BlurStyle.Regular, { scale: 0.85 })
        .border({ width: 0.5, color: Theme.manualGlassBorder() })
        .shadow(Theme.glassShadowStyle())
        .backgroundEffect(ImmBlur.cardAction())
        .systemMaterial(ImmMaterial.cardAction())
        .onClick(() => {
          const tid = this.getItem().tid;
          const postId = this.getItem().postId ?? '';
          const targetPid = postId.length > 0 ? postId : '0';
          const liked = !this.getItem().isLiked;
          if (tid.length > 0) {
            Haptic.light();
            this.onLike(tid, targetPid, liked);
          }
        }, WEIBO_TAP_MAX_MOVEMENT)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 14 })
    }
    .width('100%')
    .backgroundColor(Theme.bgCard(isDarkMode()))
    .onAreaChange((_oldValue: Area, newValue: Area): void => {
      const w: number = Number(newValue.width);
      if (w > 0 && Math.abs(w - this.cardWidth) > 1) {
        this.cardWidth = w;
      }
    })
    // 卡片圆角 26：与帖子详情页卡片（楼主卡 / 楼层卡）统一口径，不借用全局 Radius.lg（=16）。
    // 注：卡内「分享/评论/点赞」胶囊圆角 18、距卡片底 14，严格同心应为 18 + 14 = 32；
    // 26 是按统一视觉口径取的值（比 32 略收敛，胶囊与外角不再严格同心，观感更克制）。
    // 操作栏内边距与三枚胶囊尺寸一律不动。
    .borderRadius(Radius.postCard)
    // HDS 边框与内容受光：卡片跟随手指触点产生原生光感，不改变卡片尺寸或列表排版。
    .visualEffect(new hdsEffect.HdsEffectBuilder()
      .pointLight({
        illuminatedType: hdsEffect.PointLightIlluminatedType.BORDER_CONTENT
      })
      .buildEffect())
  }

  /**
   * 单图加载失败：onError 后重试一次 ImageCache.resolve（带贴吧 UA/Referer/Cookie 的下载），
   * 多数偶发失败(网络抖动/原 URL 被防盗链)能命中本地缓存自愈，不立即锁死降级。
   */
  private handleSingleImageError(): void {
    const u: string = this.getItem().images![0];
    hilog.warn(LOG_DOMAIN, TAG, 'onError single url=%{public}s', shortUrl(u));
    ImageCache.debugLog(`card onError single url=${shortUrl(u)}`);
    if (this.skipImageCache) {
      this.imageFailed = true;
      return;
    }
    this.retryOrFail(u);
  }

  /**
   * 单图加载完成：贴吧 CDN 对非移动端 UA/IP 的图床请求会返回占位图（HTTP 200 + 200/238 方图），
   * onError 不会触发（因为"加载成功"），必须靠尺寸识别。
   * v1.22: 识别到占位不立即 imageFailed（避免新帖图"先失败后恢复"的闪烁），改为确保 retryOrFail
   * 阶梯在跑：命中本地缓存(带 UA 下载成功)后自愈切真图，仅当整条阶梯(0~40s CDN 同步窗口)
   * 全部失败后才降级。命中本地真实图时走 file:// 不受影响。
   */
  private handleSingleImageComplete(loadingStatus: number, w: number, h: number): void {
    if (loadingStatus === 1 && ((w === 200 && h === 200) || (w === 238 && h === 238))) {
      ImageCache.debugLog(`card onComplete PLACEHOLDER ${w}x${h} url=${shortUrl(this.getItem().images![0])}`);
      if (!this.cachedImageMap[this.getItem().images![0]]) {
        this.retryOrFail(this.getItem().images![0]);
      }
    }
  }

  /** 多图格加载失败：重试沙箱缓存，命中后自愈（与单图同口径，各自重试、不整卡降级） */
  private handleGridImageError(img: string): void {
    hilog.warn(LOG_DOMAIN, TAG, 'onError grid url=%{public}s', shortUrl(img));
    ImageCache.debugLog(`card onError grid url=${shortUrl(img)}`);
    if (this.skipImageCache) {
      return;
    }
    this.retryOrFail(img);
  }

  /** 多图格占位图识别：同单图口径，各自走 retryOrFail 等 CDN 同步，命中缓存后自愈 */
  private handleGridImageComplete(img: string, loadingStatus: number, w: number, h: number): void {
    if (loadingStatus === 1 && ((w === 200 && h === 200) || (w === 238 && h === 238))) {
      ImageCache.debugLog(`card onComplete PLACEHOLDER ${w}x${h} grid url=${shortUrl(img)}`);
      if (!this.cachedImageMap[img]) {
        this.retryOrFail(img);
      }
    }
  }

  @Builder
  VideoPlayer() {
    WeiboVideoPlayer({ src: this.getItem().videoUrl ?? '', cover: this.getItem().videoCoverUrl ?? '',
      videoRatio: this.getItem().videoAspectRatio ?? 16 / 9 })
  }

  @Builder
  ImageGallery() {
    if (this.imageFailed) {
      // 降级：图加载失败时不渲染大图区，避免占位看起来像"没图"；改为作者头像缩略 + 提示
      Row({ space: 10 }) {
        if (this.getItem().authorAvatar && this.getItem().authorAvatar!.length > 0) {
          Image(this.getItem().authorAvatar!)
            .width(48)
            .height(48)
            .borderRadius(24)
            .objectFit(ImageFit.Cover)
            .clip(true)
            .backgroundColor(Theme.bgCard(isDarkMode()))
        }
        Text(this.getItem().authorAvatar ? '图片加载失败，点击查看' : '图片加载失败，点击查看')
          .fontSize(fs(13, this.fontScale))
          .fontColor(Theme.textSecondary(isDarkMode()))
          .layoutWeight(1)
      }
      .width('100%')
      .padding(12)
      .backgroundColor(Theme.bgCard(isDarkMode()))
      .borderRadius(Radius.md)
      .hitTestBehavior(HitTestMode.Default)
      .onClick(() => {
        this.onTap(this.getItem().tid);
      }, WEIBO_TAP_MAX_MOVEMENT)
    } else if (this.getImageCount() === 1) {
          // 单图：按实测卡宽分档。卡宽 < 420（手机单列 / 窄多列）逐像素保持旧行为；
          // 宽卡（折叠屏/平板单卡全宽）用 16:10 + 更高的高度上限，不再被 220 裁扁。
          if (this.useFixedGridCells()) {
            if (this.isNarrowMultiColumn()) {
              Image(this.resolveImgUrl(this.getItem().images![0]))
                .width('100%')
                .aspectRatio(1.6)
                .constraintSize({ maxHeight: 220 })
                .borderRadius(Radius.md)
                .objectFit(ImageFit.Cover)
                .onError(() => {
                  this.handleSingleImageError();
                })
                .onComplete((event) => {
                  if (!event) return;
                  this.handleSingleImageComplete(event.loadingStatus, event.width, event.height);
                })
                .onClick(() => {
                  this.onImageTap(this.getItem().images!, 0);
                }, WEIBO_TAP_MAX_MOVEMENT)
            } else {
              Image(this.resolveImgUrl(this.getItem().images![0]))
                .width('100%')
                .height(220)
                .borderRadius(Radius.md)
                .objectFit(ImageFit.Cover)
                .onError(() => {
                  this.handleSingleImageError();
                })
                .onComplete((event) => {
                  if (!event) return;
                  this.handleSingleImageComplete(event.loadingStatus, event.width, event.height);
                })
                .onClick(() => {
                  this.onImageTap(this.getItem().images!, 0);
                }, WEIBO_TAP_MAX_MOVEMENT)
            }
          } else {
            Image(this.resolveImgUrl(this.getItem().images![0]))
              .width('100%')
              .aspectRatio(1.6)
              .constraintSize({ maxHeight: this.singleImageMaxHeight() })
              .borderRadius(Radius.md)
              .objectFit(ImageFit.Cover)
              .onError(() => {
                this.handleSingleImageError();
              })
              .onComplete((event) => {
                if (!event) return;
                this.handleSingleImageComplete(event.loadingStatus, event.width, event.height);
              })
              .onClick(() => {
                this.onImageTap(this.getItem().images!, 0);
              }, WEIBO_TAP_MAX_MOVEMENT)
          }
        } else {
          // 多图网格（2-9张），使用 Grid 实现均匀间距
          Grid() {
            ForEach(this.getItem().images!.slice(0, this.getImageCount()), (img: string, idx: number) => {
              GridItem() {
                // 多图格几何：卡宽 < 420（手机单列 / 窄多列）保持旧档固定格高（2/4 张 140、其余 100）；
                // 宽卡用 1:1 正方形填满格（不设 maxHeight，否则宽格里被压成小方块、列间出现大缝）。
                if (this.useFixedGridCells()) {
                  if (this.isNarrowMultiColumn()) {
                    Image(this.resolveImgUrl(img))
                      .width('100%')
                      .aspectRatio(1)
                      .constraintSize({
                        maxHeight: (this.getImageCount() === 2 || this.getImageCount() === 4) ? 140 : 100
                      })
                      .borderRadius(Radius.md)
                      .objectFit(ImageFit.Cover)
                      .onError(() => {
                        this.handleGridImageError(img);
                      })
                      .onComplete((event) => {
                        if (!event) return;
                        this.handleGridImageComplete(img, event.loadingStatus, event.width, event.height);
                      })
                      .onClick(() => {
                        this.onImageTap(this.getItem().images!, idx);
                      }, WEIBO_TAP_MAX_MOVEMENT)
                  } else {
                    Image(this.resolveImgUrl(img))
                      .width('100%')
                      .height((this.getImageCount() === 2 || this.getImageCount() === 4) ? 140 : 100)
                      .borderRadius(Radius.md)
                      .objectFit(ImageFit.Cover)
                      .onError(() => {
                        this.handleGridImageError(img);
                      })
                      .onComplete((event) => {
                        if (!event) return;
                        this.handleGridImageComplete(img, event.loadingStatus, event.width, event.height);
                      })
                      .onClick(() => {
                        this.onImageTap(this.getItem().images!, idx);
                      }, WEIBO_TAP_MAX_MOVEMENT)
                  }
                } else {
                  Image(this.resolveImgUrl(img))
                    .width('100%')
                    .aspectRatio(1)
                    .borderRadius(Radius.md)
                    .objectFit(ImageFit.Cover)
                    .onError(() => {
                      this.handleGridImageError(img);
                    })
                    .onComplete((event) => {
                      if (!event) return;
                      this.handleGridImageComplete(img, event.loadingStatus, event.width, event.height);
                    })
                    .onClick(() => {
                      this.onImageTap(this.getItem().images!, idx);
                    }, WEIBO_TAP_MAX_MOVEMENT)
                }
              }
            }, (img: string, idx: number) => `${idx}`)
          }
          .columnsTemplate((this.getImageCount() === 2 || this.getImageCount() === 4) ? '1fr 1fr' : '1fr 1fr 1fr')
          .columnsGap(8)
          .rowsGap(8)
          .width('100%')
          // 关键：Grid 是可滚动容器，嵌在页面 Scroll 内会抢先接管 pan 手势判定，
          // 内容不超高时它自己滚不动、外层 Scroll 又拿不到拖动 → 多图区域"断触/滑不动"。
          // 关闭其自身滚动交互，手势全部交还外层 Scroll（纯手势开关，不影响布局与视觉）。
          .enableScrollInteraction(false)
          // 嵌套滚动策略：父容器（页面 Scroll）优先。
          // 与上面的 enableScrollInteraction(false) 是同向的防御性双保险——若该开关将来被改回
          // true，仍由 PARENT_FIRST 保证拖动优先交给外层 Scroll，不会回到"内层 Grid 抢手势"的老问题。
          .nestedScroll({
            scrollForward: NestedScrollMode.PARENT_FIRST,
            scrollBackward: NestedScrollMode.PARENT_FIRST
          })
        }
  }
}

