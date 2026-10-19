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
 * 图片缓存层：通过 HttpClient（带贴吧 UA/Referer/Cookie）预下载到沙箱，
 * 绕过贴吧图床对 Image 组件的防盗链/限速/UA 拦截（200×200 占位图）。
 *
 * 用法：
 *   const local = await ImageCache.resolve(url);
 *   Image(local) // 本地路径直接渲染，不再触发网络请求
 *
 * 首次 resolve 未命中缓存时，会：
 *   1) 通过 HttpClient 同步下载（带 Referer=贴吧 + 移动端 UA）
 *   2) 写入沙箱缓存目录（按 url 哈希命名，避免特殊字符路径问题）
 *   3) 返回 file:// 路径给 Image 渲染
 *
 * 后续命中：直接返回本地路径，跳过网络请求。
 *
 * 注意：使用同步 await 会阻塞调用方一次（首次下载），通常发生在 aboutToAppear 中，
 * 用户感受为图区短暂空白后渲染真实图。命中缓存后无延迟。
 */

import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { image } from '@kit.ImageKit';
import { HttpClient } from '../network/HttpClient';

const CACHE_DIR_NAME: string = 'img_cache';
const LOG_DOMAIN: number = 0x0A01;
const TAG: string = 'TiebaImgCache';
const MAX_URL_LOG: number = 120;
// 文件日志轮转上限：超过后改名 img_debug.log.bak 再续写，避免长期运行日志无限膨胀
const DEBUG_LOG_MAX_BYTES: number = 1024 * 1024;
// 贴吧 CDN 对非移动端 UA/IP 返回的 200×200 占位 PNG 约 3~4KB（实测 3802 字节）；
// 真实帖子缩略图通常 >5KB。缓存文件小于该阈值视为可疑占位，触发重新下载。
// （不能定太高，会误删 5~10KB 的真实缩略图。）
const MIN_VALID_CACHE_SIZE: number = 4000;
// v1.18 实抓确认的贴吧 CDN 固定占位模板字节数（同 hash 两域 imgsrc/tiebapic 均可能命中）：
//   3802 = 200×200 黑白占位（已被尺寸检测覆盖，这里直接按字节快速判占位，免解码）
//   4262 = 238×238 彩色"贴字图"（紫蓝渐变 + 白色"贴"字，新接口防盗链对失效图统一返回，
//          非 200×200 且非纯灰阶，尺寸/灰阶检测均漏检 —— 本次修复核心）
// v1.21 实抓新增（0902_154709）：贴吧 w= 缩略参数路径（forum/wh%3D960%2C120%3Bq%3D80%3Bg%3D0/...）
//   对失效图返回的非灰阶长条占位图，字节数不恒定但固定三种值（同一模板压缩结果）：
//   4762 / 5562 / 13926（被像素灰阶检测兜底，但字节级快速判能省一次解码）。
// 真实帖子照片几乎不可能恰好等于这些恒定字节数，命中即判占位。
const KNOWN_PLACEHOLDER_BYTES: number[] = [3802, 4262, 4762, 5562, 13926];
// v1.18 贴吧"贴字图"黑白占位：除 200×200 外，CDN 对失效图片还会返回非固定尺寸的
// 纯灰阶占位图（常见高 120 的长条，约 2~8KB，整图 R=G=B 无彩色）。命中缓存时对
// 小于该阈值的文件再做一次像素灰阶校验，命中占位则删除重下。
const PLACEHOLDER_VALIDATE_SIZE: number = 8000;

function shortUrl(url: string): string {
  return url.length > MAX_URL_LOG ? url.substring(0, MAX_URL_LOG) + '...' : url;
}

/** 磁盘缓存清理用：单文件条目（名称/字节数/修改时间戳） */
export interface ImageCacheClearResult {
  deletedBytes: number;
  deletedFiles: number;
  failedFiles: number;
}

interface CacheFileEntry {
  name: string;
  size: number;
  mtime: number;
}
const EXT_BY_HOST: Record<string, string> = {
  'imgsrc.baidu.com': 'jpg',
  'tiebapic.baidu.com': 'jpg',
  'static.tieba.baidu.com': 'png',
};

export class ImageCache {
  private static memCache: Map<string, string> = new Map();
  private static cacheDir: string | null = null;
  private static inflight: Map<string, Promise<string>> = new Map();
  private static generation: number = 0;

  /**
   * 调试文件日志：写入 <cache>/img_cache/img_debug.log。
   * 模拟器上 unsigned HAP 以 debug_hap 模式运行，hilog 输出被 SELinux 屏蔽，
   * 改用应用自有 cache 目录落盘，hdc 直接拉取分析，不受日志系统限制。
   */
  static debugLog(msg: string): void {
    try {
      const dir: string = ImageCache.getCacheDir();
      const logPath: string = `${dir}/img_debug.log`;
      // 日志轮转：超过上限时把旧日志改名保留一份
      try {
        const st: fileIo.Stat = fileIo.statSync(logPath);
        if (st.size > DEBUG_LOG_MAX_BYTES) {
          const bakPath: string = `${dir}/img_debug.log.bak`;
          try {
            fileIo.unlinkSync(bakPath);
          } catch (e) { /* 无旧备份 */ }
          fileIo.renameSync(logPath, bakPath);
        }
      } catch (e) { /* 日志文件尚不存在 */ }
      const f: fileIo.File = fileIo.openSync(logPath, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.APPEND);
      try {
        fileIo.writeSync(f.fd, `${Date.now()} ${msg}\n`);
      } finally {
        fileIo.closeSync(f);
      }
    } catch (e) { /* 日志失败不影响主流程 */ }
  }

  /** 取沙箱缓存目录路径（懒初始化） */
  private static getCacheDir(): string {
    if (ImageCache.cacheDir !== null) {
      return ImageCache.cacheDir;
    }
    try {
      const context: common.UIAbilityContext = (getContext() as common.UIAbilityContext);
      const dir: string = `${context.cacheDir}/${CACHE_DIR_NAME}`;
      try {
        fileIo.mkdirSync(dir);
      } catch (e) {
        // 已存在或权限异常；后续 openSync 失败时再处理
      }
      ImageCache.cacheDir = dir;
      return dir;
    } catch (e) {
      ImageCache.debugLog(`getCacheDir EXCEPTION err=${JSON.stringify(e)}`);
      // 返回一个兜底目录，避免上层直接崩溃；后续写入失败也会被捕获
      const fallback: string = '/data/storage/el2/base/cache/img_cache';
      ImageCache.cacheDir = fallback;
      return fallback;
    }
  }

  /** URL → 缓存文件名（用 SHA-1 截 32 位作为 hash，避免长路径和特殊字符） */
  private static urlToFileName(url: string): string {
    // 简单 hash：直接用 url 末段 + url 长度，避免依赖 crypto 模块的兼容问题
    let h: number = 5381;
    for (let i = 0; i < url.length; i++) {
      h = ((h << 5) + h + url.charCodeAt(i)) | 0;
    }
    const hex: string = (h >>> 0).toString(16);
    // 推断扩展名（默认 jpg）
    let ext: string = 'jpg';
    try {
      const u: string = url.split('?')[0];
      const lastDot: number = u.lastIndexOf('.');
      if (lastDot > 0 && lastDot > u.length - 6) {
        const candidate: string = u.substring(lastDot + 1).toLowerCase();
        if (candidate === 'jpg' || candidate === 'jpeg' || candidate === 'png' || candidate === 'webp' || candidate === 'gif') {
          ext = candidate;
        }
      }
    } catch (e) { /* 忽略 */ }
    return `img_${hex}.${ext}`;
  }

  /** 是否已经缓存（命中磁盘 + 内存；含占位图大小校验） */
  static has(url: string): boolean {
    if (ImageCache.memCache.has(url)) {
      return true;
    }
    const fileName: string = ImageCache.urlToFileName(url);
    const filePath: string = `${ImageCache.getCacheDir()}/${fileName}`;
    try {
      if (!fileIo.accessSync(filePath)) {
        return false;
      }
      const stat: fileIo.Stat = fileIo.statSync(filePath);
      if (ImageCache.isKnownPlaceholderSize(stat.size)) {
        // 已知占位模板（3802/4262 等恒定字节）的旧脏缓存：删除并视为未命中，触发重新下载
        ImageCache.debugLog(`cache KNOWN-PLACEHOLDER remove url=${shortUrl(url)} size=${stat.size}`);
        try {
          fileIo.unlinkSync(filePath);
        } catch (e) { /* 删除失败也不影响 */ }
        ImageCache.memCache.delete(url);
        return false;
      }
      return stat.size >= MIN_VALID_CACHE_SIZE;
    } catch (e) {
      return false;
    }
  }

  /** 字节数是否命中已知贴吧 CDN 占位模板（3802/4262 等恒定值） */
  private static isKnownPlaceholderSize(size: number): boolean {
    for (const s of KNOWN_PLACEHOLDER_BYTES) {
      if (size === s) {
        return true;
      }
    }
    return false;
  }

  /** 返回缓存的 file:// 路径；如果未命中返回 null */
  static getCachedPath(url: string): string | null {
    if (ImageCache.memCache.has(url)) {
      return ImageCache.memCache.get(url) as string;
    }
    const fileName: string = ImageCache.urlToFileName(url);
    const filePath: string = `${ImageCache.getCacheDir()}/${fileName}`;
    try {
      if (fileIo.accessSync(filePath)) {
        // 占位图防护：贴吧 200×200 占位 PNG 约 3~9KB。缓存文件过小说明是
        // 旧版本误存的占位图，删除并返回 null 触发重新下载（带镜像域重试）。
        const stat: fileIo.Stat = fileIo.statSync(filePath);
        // v1.18 新增：4262B 的 238×238 彩色"贴字图"占位（>4KB 逃过 SMALL 检查）
        // 恒等于 CDN 模板字节数，命中即删。
        if (ImageCache.isKnownPlaceholderSize(stat.size) || stat.size < MIN_VALID_CACHE_SIZE) {
          ImageCache.debugLog(`cache ${ImageCache.isKnownPlaceholderSize(stat.size) ? 'KNOWN-PLACEHOLDER' : 'SMALL'} size=${stat.size} remove-and-redownload url=${shortUrl(url)}`);
          try {
            fileIo.unlinkSync(filePath);
          } catch (e) { /* 删除失败也不影响重下 */ }
          ImageCache.memCache.delete(url);
          return null;
        }
        const fileUri: string = `file://${filePath}`;
        ImageCache.memCache.set(url, fileUri);
        return fileUri;
      }
    } catch (e) { /* 不存在 */ }
    return null;
  }

  /**
   * 通过 HttpClient（带贴吧移动端 UA + Referer + Cookie）下载图片到沙箱缓存。
   * 命中缓存立即返回；未命中时阻塞到下载完成。
   * 任何异常都返回原 URL，让 Image 自行尝试（不会更差）。
   */
  static async resolve(url: string): Promise<string> {
    const generation: number = ImageCache.generation;
    if (!url || url.length === 0) return url;
    // 非 http(s):// 直接返回（file://, data:, internal: 等）
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      return url;
    }
    try {
      const cached: string | null = ImageCache.getCachedPath(url);
      if (cached !== null) {
        // v1.18 命中缓存的小文件可能是旧版本误存的贴吧"贴字图"黑白占位（非 200×200，
        // 旧逻辑漏检）。做一次像素灰阶校验：命中占位则删除并落到下方下载流程重下。
        try {
          const fileName: string = ImageCache.urlToFileName(url);
          const filePath: string = `${ImageCache.getCacheDir()}/${fileName}`;
          const st: fileIo.Stat = fileIo.statSync(filePath);
          if (st.size < PLACEHOLDER_VALIDATE_SIZE) {
            const fd: fileIo.File = fileIo.openSync(filePath, fileIo.OpenMode.READ_ONLY);
            try {
              const fileBuf: ArrayBuffer = new ArrayBuffer(st.size);
              fileIo.readSync(fd.fd, fileBuf);
              const placeholder: boolean = await ImageCache.isPlaceholderImage(fileBuf);
              if (generation !== ImageCache.generation) { return url; }
              if (placeholder) {
                ImageCache.debugLog(`cache PLACEHOLDER-by-decoder remove url=${shortUrl(url)} size=${st.size}`);
                try {
                  fileIo.unlinkSync(filePath);
                } catch (e) { /* 删除失败不影响 */ }
                ImageCache.memCache.delete(url);
                // 落到下方下载流程
              } else {
                ImageCache.memCache.set(url, cached);
                return cached;
              }
            } finally {
              fileIo.closeSync(fd);
            }
          } else {
            return cached;
          }
        } catch (e) {
          return cached;
        }
      }
    } catch (e) {
      ImageCache.debugLog(`resolve getCachedPath EXCEPTION url=${shortUrl(url)} err=${JSON.stringify(e)}`);
    }
    // 同一个 URL 同时多次 resolve 时，复用同一个 Promise
    const existing: Promise<string> | undefined = ImageCache.inflight.get(url);
    if (existing !== undefined) {
      return existing;
    }
    if (generation !== ImageCache.generation) { return url; }
    const task: Promise<string> = ImageCache.downloadAndCache(url, generation);
    ImageCache.inflight.set(url, task);
    try {
      const result: string = await task;
      return result;
    } catch (e) {
      ImageCache.debugLog(`resolve task EXCEPTION url=${shortUrl(url)} err=${JSON.stringify(e)}`);
      return url;
    } finally {
      if (ImageCache.inflight.get(url) === task) { ImageCache.inflight.delete(url); }
    }
  }

  /**
   * 生成候选下载 URL：原 URL + 贴吧图床镜像域。
   * imgsrc.baidu.com 与 tiebapic.baidu.com 是同一张图（同一 hash 路径）的官方镜像，
   * 新发布的帖子图片 URL 可能只在某个域/某个 CDN 节点被防盗链拦截或返回占位图，
   * 换镜像域再试一次能显著提高命中率。其它域不生成候选，保持原 URL 单次尝试。
   * v1.21 实抓(0902_154709)贴吧部分 hash 在 imgsrc/tiebapic 两域镜像同步延迟，
   * 老域 hiphotos.baidu.com 反而先返回真图(贴吧旧 CDN 节点，部分老帖同步慢但同步完成)，
   * 加入第三镜像候选，提一次命中率。
   */
  private static mirrorCandidates(url: string): string[] {
    const candidates: string[] = [url];
    if (url.includes('imgsrc.baidu.com')) {
      candidates.push(url.replace('imgsrc.baidu.com', 'tiebapic.baidu.com'));
    } else if (url.includes('tiebapic.baidu.com')) {
      candidates.push(url.replace('tiebapic.baidu.com', 'imgsrc.baidu.com'));
    }
    // hiphotos.baidu.com(贴吧旧图床)作为第三镜像,跳过已是 hiphotos 的 URL 避免冗余。
    // 部分老帖/新帖在 hiphotos 上反而比 imgsrc/tiebapic 更早完成 CDN 同步,命中可走通。
    if (!url.includes('hiphotos.baidu.com')) {
      let hiphotosUrl: string = '';
      if (url.includes('imgsrc.baidu.com')) {
        hiphotosUrl = url.replace('imgsrc.baidu.com', 'hiphotos.baidu.com');
      } else if (url.includes('tiebapic.baidu.com')) {
        hiphotosUrl = url.replace('tiebapic.baidu.com', 'hiphotos.baidu.com');
      } else {
        // 兜底：若原 URL 不在已知两镜像域中,通用构造 hiphotos 占位串(失败则落入外层 null)
        hiphotosUrl = url.replace(/^https?:\/\/[^/]+/, 'https://hiphotos.baidu.com');
      }
      if (hiphotosUrl.length > 0 && hiphotosUrl !== url) {
        candidates.push(hiphotosUrl);
      }
    }
    // v1.22 实抓(0902_1825x)终极兜底：贴吧 /forum/w%3D... / wh%3D... 缩略路径(贴吧新版
    // 接口给关注用户帖子的图床 URL)对模拟器 UA / 未登录态会返回 1~9 字节近空响应,
    // imgsrc/tiebapic/hiphotos 三镜像一律失败,卡片走"图片加载失败"降级。
    // 但同 HASH 的 /forum/pic/item/HASH.{ext} 直链原图不受此防盗链影响(同 hilog 实抓
    // 大量 cached OK: 363585 / 440304 / 605032 bytes 等真实图)。从 w/wh URL 抽出 HASH
    // 拼直链作为第四候选,旧逻辑全失败时仍能命中真实图。
    const hashMatch: RegExpMatchArray | null = url.match(/\/sign=[^/]+\/(\w+)\.(jpg|jpeg|png|webp|gif)(?:\?|$)/i);
    if (hashMatch) {
      const hash: string = hashMatch[1];
      const ext: string = hashMatch[2].toLowerCase();
      const directUrls: string[] = [
        `https://imgsrc.baidu.com/forum/pic/item/${hash}.${ext}`,
        `https://tiebapic.baidu.com/forum/pic/item/${hash}.${ext}`,
      ];
      for (const u of directUrls) {
        if (!candidates.includes(u)) {
          candidates.push(u);
        }
      }
    }
    return candidates;
  }

  private static async downloadAndCache(url: string, generation: number): Promise<string> {
    // 磁盘缓存统一以「原 URL」为 key 命名；镜像候选下载成功同样写入该文件，
    // 后续 getCachedPath(原 URL) 可直接命中，无需二次下载。
    const filePath: string = `${ImageCache.getCacheDir()}/${ImageCache.urlToFileName(url)}`;
    ImageCache.debugLog(`resolve start url=${shortUrl(url)} candidates=${ImageCache.mirrorCandidates(url).length}`);
    // v1.18 区分「网络失败」与「确认占位图」：所有候选都返回占位（贴吧 200×200 / 纯灰阶"贴字图"）
    // 时返回 '' 通知调用方不要直连原 URL（否则 Image 仍会拉到同一张占位图并显示）。
    let sawPlaceholder: boolean = false;
    for (const candidate of ImageCache.mirrorCandidates(url)) {
      try {
        const buf: ArrayBuffer | null = await ImageCache.downloadBuf(candidate);
        if (generation !== ImageCache.generation) { return url; }
        if (buf === null) {
          hilog.warn(LOG_DOMAIN, TAG, 'candidate fail url=%{public}s', shortUrl(candidate));
          ImageCache.debugLog(`candidate FAIL url=${shortUrl(candidate)}`);
          continue; // 网络失败，尝试下一个镜像
        }
        // 占位图识别（含像素灰阶校验）：命中则丢弃该候选，试下一个镜像
        const placeholder: boolean = await ImageCache.isPlaceholderImage(buf);
        if (generation !== ImageCache.generation) { return url; }
        if (placeholder) {
          sawPlaceholder = true;
          ImageCache.debugLog(`candidate PLACEHOLDER url=${shortUrl(candidate)} bytes=${buf.byteLength}`);
          continue;
        }
        const file: fileIo.File = fileIo.openSync(filePath, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
        try {
          fileIo.writeSync(file.fd, buf);
        } finally {
          fileIo.closeSync(file);
        }
        const fileUri: string = `file://${filePath}`;
        ImageCache.memCache.set(url, fileUri);
        hilog.info(LOG_DOMAIN, TAG, 'cached ok url=%{public}s bytes=%{public}d', shortUrl(url), buf.byteLength);
        ImageCache.debugLog(`cached OK url=${shortUrl(url)} bytes=${buf.byteLength} cand=${shortUrl(candidate)}`);
        ImageCache.pruneIfNeeded();
        return fileUri;
      } catch (e) {
        hilog.error(LOG_DOMAIN, TAG, 'candidate exception url=%{public}s err=%{public}s', shortUrl(candidate), JSON.stringify(e));
        ImageCache.debugLog(`candidate EXCEPTION url=${shortUrl(candidate)} err=${JSON.stringify(e)}`);
        // 单个候选异常继续下一个
      }
    }
    hilog.error(LOG_DOMAIN, TAG, 'ALL candidates failed url=%{public}s', shortUrl(url));
    ImageCache.debugLog(`ALL candidates FAILED url=${shortUrl(url)} placeholder=${sawPlaceholder}`);
    if (sawPlaceholder) {
      return ''; // 确认占位：不返回原 URL，避免 Image 直连再次拉到同一张"贴字图"
    }
    return url;
  }

  /**
   * 解码图片字节并判断是否为贴吧占位图（含"贴字图"黑白/彩色占位）。
   * 判定规则（v1.18 增强）：
   *  1) 字节数精确命中 CDN 已知占位模板（3802/4262 等恒定值，免解码直接判占位）；
   *  2) 精确尺寸 200×200（贴吧经典黑白占位 PNG）；
   *  3) 精确尺寸 238×238（v1.18 实抓：彩色"贴字图"占位，紫蓝渐变+白色"贴"字，
   *     imgsrc/tiebapic 镜像对失效/防盗链图统一返回 4262B 固定文件，非灰阶曾漏检）；
   *  4) 纯灰阶图：整图 R=G=B 的像素占比 ≥98%（非固定尺寸的其它黑白占位变体）。
   * 解码失败（非图片/损坏）也按占位处理返回 true，避免把坏文件写入缓存。
   * 说明：贴吧帖子配图几乎均为彩色照片，恰好 238×238 正方形或整图灰阶的概率极低；
   * 即使个别图片被误判，也只是少显示一张图（走降级），不会显示错误占位，可接受。
   */
  private static async isPlaceholderImage(buf: ArrayBuffer): Promise<boolean> {
    // 字节数命中已知占位模板 → 直接判占位，省解码
    if (ImageCache.isKnownPlaceholderSize(buf.byteLength)) {
      ImageCache.debugLog(`PLACEHOLDER by-bytes size=${buf.byteLength}`);
      return true;
    }
    // v1.22 实抓(0902_1825x)：贴吧 /forum/w%3D... / wh%3D... 缩略路径在模拟器 UA/未登录态下
    // 被服务器直接截断返回 1~9 字节的近空响应（不是任何已知占位模板,不解码也走不到
    // "解码失败判占位"分支而被忽略）。任一真实图片格式头部 ≥67B(PNG) / ≥100B(JPEG/WebP/GIF)；
    // 小于 100B 必然不是合法图片,直接判占位,避免后续误认为"真实小图"放行。
    if (buf.byteLength < 100) {
      ImageCache.debugLog(`PLACEHOLDER by-tiny-size size=${buf.byteLength}`);
      return true;
    }
    try {
      const src: image.ImageSource = image.createImageSource(buf);
      try {
        const info: image.ImageInfo = await src.getImageInfo();
        if (info.size.width === 200 && info.size.height === 200) {
          return true;
        }
        if (info.size.width === 238 && info.size.height === 238) {
          return true;
        }
        const w: number = info.size.width;
        const h: number = info.size.height;
        const total: number = w * h;
        // 仅对中等尺寸图做像素检测，避免超大图解码耗时（贴吧占位图都很小）
        if (total <= 0 || total > 600 * 600) {
          return false;
        }
        const pixmap: image.PixelMap = await src.createPixelMap();
        try {
          const buf4: ArrayBuffer = new ArrayBuffer(total * 4);
          await pixmap.readPixelsToBuffer(buf4);
          const arr: Uint8Array = new Uint8Array(buf4);
          // 采样上限 512 点（步长自适应），避免全量遍历
          const step: number = Math.max(1, Math.floor(total / 512));
          let gray: number = 0;
          let samples: number = 0;
          for (let i = 0; i < total * 4; i += 4 * step) {
            if (arr[i] === arr[i + 1] && arr[i + 1] === arr[i + 2]) {
              gray++;
            }
            samples++;
          }
          return samples > 0 && gray / samples >= 0.98;
        } finally {
          pixmap.release();
        }
      } finally {
        src.release();
      }
    } catch (e) {
      ImageCache.debugLog(`decoder EXCEPTION err=${JSON.stringify(e)}`);
      return true;
    }
  }

  /** 下载单个候选 URL：成功返回图片字节；失败返回 null
   * v1.18+ 统一走 HttpClient.getBinary（rcp 单例 Session，跨请求复用连接/HTTP2），
   * 避免每张图都新建 http 连接；UA/Referer 显式传入，Cookie 由 buildHeaders 自动注入。
   */
  private static async downloadBuf(url: string): Promise<ArrayBuffer | null> {
    try {
      const buf: ArrayBuffer = await HttpClient.getBinary(url, {
        'User-Agent': 'Mozilla/5.0 (Linux; Android 13; HarmonyOS 5.0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36 tieba/12.5.0',
        'Accept': 'image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8',
        'Accept-Language': 'zh-CN,zh;q=0.9',
        'Referer': 'https://tieba.baidu.com/',
      });
      // v1.18 占位图判定统一上移到 downloadAndCache（isPlaceholderImage 含尺寸 + 纯灰阶
      // 像素检测），downloadBuf 只负责网络层：HTTP 2xx 即返回字节，由外层决定是否缓存。
      return buf;
    } catch (e) {
      hilog.error(LOG_DOMAIN, TAG, 'request exception url=%{public}s err=%{public}s', shortUrl(url), JSON.stringify(e));
      ImageCache.debugLog(`REQUEST EXCEPTION url=${shortUrl(url)} err=${JSON.stringify(e)}`);
      return null;
    }
  }

  // ---- 磁盘缓存清理：总大小/文件数超限时按 mtime 删除最旧文件，防止 img_cache 无限膨胀 ----
  private static cacheWriteCounter: number = 0;
  private static readonly PRUNE_INTERVAL: number = 20;      // 每写 N 个文件检查一次
  private static readonly MAX_CACHE_BYTES: number = 300 * 1024 * 1024; // 300MB
  private static readonly MAX_CACHE_FILES: number = 1500;

  /** 定期清理磁盘缓存：超过阈值删除最旧的图片文件（仅清理磁盘，不影响 memCache） */
  private static pruneIfNeeded(): void {
    ImageCache.cacheWriteCounter++;
    if (ImageCache.cacheWriteCounter % ImageCache.PRUNE_INTERVAL !== 0) {
      return;
    }
    try {
      const dir: string = ImageCache.getCacheDir();
      const names: string[] = fileIo.listFileSync(dir);
      if (names.length === 0) {
        return;
      }
      let total: number = 0;
      const entries: CacheFileEntry[] = [];
      for (const name of names) {
        try {
          const st: fileIo.Stat = fileIo.statSync(`${dir}/${name}`);
          entries.push({ name: name, size: st.size, mtime: st.mtime });
          total += st.size;
        } catch (e) { /* 单个文件 stat 失败忽略 */ }
      }
      if (entries.length <= ImageCache.MAX_CACHE_FILES && total <= ImageCache.MAX_CACHE_BYTES) {
        return;
      }
      // 最旧在前逐个删除，直到两项指标都低于阈值
      entries.sort((a, b) => a.mtime - b.mtime);
      for (const entry of entries) {
        if (entries.length <= ImageCache.MAX_CACHE_FILES && total <= ImageCache.MAX_CACHE_BYTES) {
          break;
        }
        try {
          fileIo.unlinkSync(`${dir}/${entry.name}`);
          total -= entry.size;
          entries.length--;
        } catch (e) { /* 删除失败忽略 */ }
      }
      ImageCache.debugLog(`prune done files=${entries.length} total=${total}`);
    } catch (e) { /* 清理失败不影响主流程 */ }
  }

  static getCacheSize(): string {
    try {
      const dir: string = ImageCache.getCacheDir();
      const names: string[] = fileIo.listFileSync(dir);
      let total: number = 0;
      for (const name of names) {
        try {
          const st: fileIo.Stat = fileIo.statSync(`${dir}/${name}`);
          total += st.size;
        } catch (_e) {}
      }
      if (total < 1024 * 1024) {
        return `${(total / 1024).toFixed(1)} KB`;
      }
      return `${(total / (1024 * 1024)).toFixed(1)} MB`;
    } catch (_e) {
      return '0 KB';
    }
  }

  static clearAllCache(): ImageCacheClearResult {
    ImageCache.generation++;
    ImageCache.memCache.clear();
    ImageCache.inflight.clear();
    const result: ImageCacheClearResult = { deletedBytes: 0, deletedFiles: 0, failedFiles: 0 };
    const dir: string = ImageCache.getCacheDir();
    // Listing failure propagates; do not claim that an inaccessible cache is empty.
    const names: string[] = fileIo.listFileSync(dir);
    for (const name of names) {
      try {
        const path: string = `${dir}/${name}`;
        const stat: fileIo.Stat = fileIo.statSync(path);
        fileIo.unlinkSync(path);
        result.deletedBytes += stat.size;
        result.deletedFiles++;
      } catch (_error) { result.failedFiles++; }
    }
    return result;
  }
}