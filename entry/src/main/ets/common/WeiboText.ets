import { stripHtml } from './Constants';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';

interface EmojiAsset { phrase: string; url: string; }
interface EmojiLocale { ZH_CN: Record<string, EmojiAsset[]>; }
interface EmojiData { emoticon: EmojiLocale; }
interface EmojiResponse { data: EmojiData; }
let bundledAssetsLoaded: boolean = false;

/** Bundled real CDN mappings from Flare's public emoji.json; works without a catalog request. */
export function loadWeiboEmojiAssets(context: common.UIAbilityContext): void {
  if (bundledAssetsLoaded) { return; }
  try {
    const bytes: Uint8Array = context.resourceManager.getRawFileContentSync('weibo-emoji.json');
    const text: string = new util.TextDecoder('utf-8').decodeWithStream(bytes);
    const response: EmojiResponse = JSON.parse(text) as EmojiResponse;
    const groups: Record<string, EmojiAsset[]> = response.data.emoticon.ZH_CN;
    for (const group of Object.keys(groups)) {
      for (const asset of groups[group]) {
        if (/^\[[^\]]+\]$/.test(asset.phrase) && isWeiboEmojiUrl(asset.url)) {
          emojiAssets.set(asset.phrase.substring(1, asset.phrase.length - 1), asset.url);
        }
      }
    }
    bundledAssetsLoaded = true;
  } catch (_error) {
    // Keep the original bracket label if the catalog cannot be loaded.
  }
}

/** Only server-provided assets are registered; never invent CDN hashes. */
const emojiAssets: Map<string, string> = new Map();

export function getWeiboEmoji(name: string): string | undefined {
  return emojiAssets.get(name);
}

export function getWeiboEmojiNames(): string[] {
  const names: string[] = [];
  emojiAssets.forEach((_url: string, name: string): void => { names.push(name); });
  return names;
}

function isWeiboEmojiUrl(url: string): boolean {
  return /^https?:\/\/(?:[a-z0-9-]+\.)*(?:sinaimg\.cn|sinajs\.cn)\//i.test(url);
}

function attribute(tag: string, name: string): string {
  const match: RegExpExecArray | null = new RegExp(`${name}\\s*=\\s*["']([^"']*)["']`, 'i').exec(tag);
  return match === null ? '' : match[1];
}

const BASE62_CHARS: string = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';

export function midToBid(mid: string): string {
  const clean: string = mid.trim();
  if (!/^\d+$/.test(clean)) {
    return clean;
  }
  let bid: string = '';
  for (let i: number = clean.length - 7; i > -7; i -= 7) {
    const offset: number = i < 0 ? 0 : i;
    const len: number = i < 0 ? clean.length % 7 : 7;
    const sub: string = clean.substring(offset, offset + len);
    let n: number = parseInt(sub, 10);
    let s: string = '';
    while (n > 0) {
      s = BASE62_CHARS.charAt(n % 62) + s;
      n = Math.floor(n / 62);
    }
    while (i >= 0 && s.length < 4) {
      s = '0' + s;
    }
    bid = s + bid;
  }
  return bid;
}

export function bidToMid(bid: string): string {
  const clean: string = bid.trim();
  if (/^\d+$/.test(clean)) {
    return clean;
  }
  let mid: string = '';
  for (let i: number = clean.length - 4; i > -4; i -= 4) {
    const offset: number = i < 0 ? 0 : i;
    const len: number = i < 0 ? clean.length % 4 : 4;
    const sub: string = clean.substring(offset, offset + len);
    let n: number = 0;
    for (let j: number = 0; j < sub.length; j++) {
      const idx: number = BASE62_CHARS.indexOf(sub.charAt(j));
      if (idx >= 0) {
        n = n * 62 + idx;
      }
    }
    let s: string = n.toString();
    while (i >= 0 && s.length < 7) {
      s = '0' + s;
    }
    mid = s + mid;
  }
  return mid;
}

/** Preserve emoji labels, line breaks, and short links before flattening untrusted HTML. */
export function normalizeWeiboText(html: string): string {
  // Convert line breaks and paragraph boundaries to newlines before stripping HTML tags
  const withLineBreaks: string = html.replace(/<br\s*\/?>/gi, '\n').replace(/<p\b[^>]*>/gi, '\n').replace(/<\/p>/gi, '\n');
  // Strip inline expand spans (e.g. <span class="expand">展开</span>)
  const withoutExpandSpans: string = withLineBreaks.replace(/<span\b[^>]*>[\s\S]*?<\/span>/gi, (tag: string): string => {
    const text: string = stripHtml(tag).trim();
    if (/^(?:展开|查看全文|全文)$/i.test(text)) {
      return '';
    }
    return tag;
  });
  const withEmoji: string = withoutExpandSpans.replace(/<img\b[^>]*>/gi, (tag: string): string => {
    const label: string = attribute(tag, 'alt');
    const source: string = attribute(tag, 'src');
    if (/^\[[^\]]+\]$/.test(label) && isWeiboEmojiUrl(source)) {
      emojiAssets.set(label.substring(1, label.length - 1), source);
    }
    return label;
  });
  const withLinks: string = withEmoji.replace(/<a\b[^>]*>[\s\S]*?<\/a>/gi, (tag: string): string => {
    const rawHref: string = stripHtml(attribute(tag, 'href'));
    const href: string = rawHref.startsWith('//') ? `https:${rawHref}` : rawHref;
    const label: string = stripHtml(tag).trim();
    // Strip inline expand links so they don't produce trailing fake links
    if (/^(?:展开|查看全文|全文)$/i.test(label)) {
      return '';
    }
    // Strip redundant internal video/status anchors labeled 网页链接
    if (label === '网页链接' && (/(?:video\.weibo\.com|weibo\.(?:com|cn)\/(?:status|detail|tv\/show))/i.test(href) || href.includes('sinaimg.cn'))) {
      return '';
    }
    // Strip 评论配图 anchor so it does not render redundant text "评论配图 网页链接 ↗"
    if (label === '评论配图' || label.includes('评论配图')) {
      return '';
    }
    const semanticLink: boolean = label.startsWith('@') || /^#[^#]+#$/.test(label);
    if (/^https?:\/\//i.test(href) && !semanticLink && !label.includes(href)) {
      return `${label.length > 0 && label !== '网页链接' ? label + ' ' : ''}${href} `;
    }
    return label;
  });
  return stripHtml(withLinks).replace(/[\u200b\ufeff]+/g, '').replace(/\s*评论配图\s*$/i, '').trim();
}
