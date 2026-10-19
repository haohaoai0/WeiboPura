export interface WeiboMediaSize { url?: string; }
export interface WeiboMediaPicture {
  url?: string;
  original?: WeiboMediaSize;
  largest?: WeiboMediaSize;
  mw2000?: WeiboMediaSize;
  large?: WeiboMediaSize;
  largecover?: WeiboMediaSize;
  bmiddle?: WeiboMediaSize;
  thumbnail?: WeiboMediaSize;
  type?: string;
  videoSrc?: string;
  video?: string;
}

/** Keep still/video pairing by URL, not by filtered grid index. No invented video URLs. */
export function weiboLivePhotoTracks(mobile: WeiboMediaPicture[], desktop?: Record<string, WeiboMediaPicture>): Record<string, string> {
  const result: Record<string, string> = {};
  const entries: WeiboMediaPicture[] = mobile.slice();
  if (desktop !== undefined) { for (const id of Object.keys(desktop)) { entries.push(desktop[id]); } }
  for (const item of entries) {
    // Mobile also returns ordinary mixed-media videos; only LivePhotos belong here.
    if (item.type !== undefined && item.type !== '' && item.type !== 'livephoto') { continue; }
    const raw: string = item.video ?? (item.type === 'livephoto' ? item.videoSrc ?? '' : '');
    const video: string = raw.startsWith('//') ? `https:${raw}` : raw;
    if (!/^https?:\/\//i.test(video)) { continue; }
    const urls: string[] = [item.url ?? '', item.original?.url ?? '', item.largest?.url ?? '',
      item.mw2000?.url ?? '', item.large?.url ?? '', item.largecover?.url ?? '', item.bmiddle?.url ?? '', item.thumbnail?.url ?? ''];
    for (const url of urls) { if (url.length > 0) { result[url] = video; } }
  }
  return result;
}
