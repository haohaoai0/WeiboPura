import { formatWeiboTime, stripHtml } from '../common/Constants';
import { rcp } from '@kit.RemoteCommunicationKit';
import { WeiboHttpClient } from '../network/WeiboHttpClient';
import { WeiboComment, WeiboCommentsPage, WeiboHotTopic, WeiboPost, WeiboSuggestion, WeiboTimelinePage, WeiboUser } from '../model/WeiboModel';
import { WeiboAuthManager } from './WeiboAuthManager';
import { WeiboVisitorSession } from './WeiboVisitorSession';

interface WeiboApiResponse {
  ok?: number;
  msg?: string;
  url?: string;
  data?: WeiboResponseData;
}

/** The mobile status endpoint returns a post directly in its data field. */
interface WeiboStatusApiResponse {
  ok?: number;
  data?: WeiboPostJson;
}

/** Authenticated mobile configuration exposes the UID for the current Cookie. */
interface WeiboConfigResponse {
  ok?: number;
  msg?: string;
  data?: WeiboConfigData;
}

interface WeiboConfigData {
  login?: boolean;
  uid?: string;
}

/** Desktop web's authenticated friends feed is not wrapped in a `data` object. */
interface WeiboFollowingTimelineResponse {
  ok?: number;
  msg?: string;
  statuses?: WeiboPostJson[];
  max_id?: string | number;
}

interface WeiboResponseData {
  cards?: WeiboCardJson[];
  userInfo?: WeiboUserJson;
  data?: WeiboCommentJson[];
  max_id?: string;
  realtime?: WeiboHotTopicJson[];
  hotquery?: WeiboSuggestionJson[];
}

interface WeiboHotTopicJson {
  rank?: number;
  realpos?: number;
  word?: string;
  num?: number;
  label_name?: string;
  word_scheme?: string;
}

interface WeiboSuggestionJson {
  suggestion?: string;
  count?: number;
  top_flag?: number;
}

interface WeiboCardJson {
  card_type?: number;
  mblog?: WeiboPostJson;
  card_group?: WeiboCardJson[];
}

interface WeiboUserJson {
  /** Weibo returns numeric IDs on some timeline surfaces and strings on others. */
  id?: string | number;
  screen_name?: string;
  description?: string;
  avatar_hd?: string;
  profile_image_url?: string;
  cover_image_phone?: string;
  followers_count?: string | number;
  follow_count?: string | number;
  statuses_count?: string | number;
  verified?: boolean;
  verified_reason?: string;
}

interface WeiboPictureJson {
  url?: string;
  large?: WeiboPictureSizeJson;
  largest?: WeiboPictureSizeJson;
  mw2000?: WeiboPictureSizeJson;
  original?: WeiboPictureSizeJson;
}

interface WeiboPictureSizeJson {
  url?: string;
}

/** The video URL variants used by the mobile status API. */
interface WeiboVideoUrlsJson {
  mp4_1080p_60fps?: string;
  mp4_1080p_mp4?: string;
  mp4_hd_mp4?: string;
  mp4_720p_mp4?: string;
  mp4_sd_mp4?: string;
  mp4_ld_mp4?: string;
}

interface WeiboVideoMediaInfoJson {
  stream_url_hd?: string;
  stream_url?: string;
  stream_url_h5?: string;
  mp4_hd_mp4?: string;
  mp4_720p_mp4?: string;
}

interface WeiboPagePictureJson {
  url?: string;
}

interface WeiboPageInfoJson {
  type?: string;
  urls?: WeiboVideoUrlsJson;
  media_info?: WeiboVideoMediaInfoJson;
  page_pic?: WeiboPagePictureJson;
}

interface WeiboPostJson {
  /** Desktop timelines may use numbers while mobile endpoints use strings. */
  id?: string | number;
  mid?: string | number;
  text?: string;
  created_at?: string;
  source?: string;
  attitudes_count?: number;
  comments_count?: number;
  reposts_count?: number;
  attitudes_status?: number;
  user?: WeiboUserJson;
  pics?: WeiboPictureJson[];
  page_info?: WeiboPageInfoJson;
  video_url?: string;
  thumbnail_pic?: string;
  retweeted_status?: WeiboPostJson;
}

interface WeiboCommentJson {
  id?: string;
  text?: string;
  created_at?: string;
  like_count?: number;
  user?: WeiboUserJson;
}

/**
 * Adapter for public mobile containers and user-initiated post actions.
 * Endpoint responses are deliberately mapped to small app-owned models, so UI
 * code is insulated from undocumented response-shape changes.
 */
export class WeiboService {
  private static instance: WeiboService | null = null;
  private recentPost: WeiboPost | null = null;
  /** One detail page can consume the comment request already started by its card. */
  private recentCommentsPostId: string = '';
  private recentComments: WeiboCommentsPage | null = null;
  private pendingCommentsPostId: string = '';
  private pendingComments: Promise<WeiboCommentsPage> | null = null;

  static getInstance(): WeiboService {
    if (WeiboService.instance === null) {
      WeiboService.instance = new WeiboService();
    }
    return WeiboService.instance;
  }

  /** Warms the API 24 RCP connection while local auth/settings initialization is running. */
  preconnectTimeline(): void {
    WeiboHttpClient.preconnectMobile();
  }

  async fetchUserProfile(userId: string): Promise<WeiboUser> {
    const escapedUserId: string = encodeURIComponent(userId.trim());
    const raw: string = await this.get(`https://m.weibo.cn/api/container/getIndex?containerid=100505${escapedUserId}`);
    const response: WeiboApiResponse = this.parseResponse(raw);
    const user: WeiboUserJson | undefined = response.data?.userInfo;
    if (user === undefined) {
      throw new Error('微博没有返回用户资料');
    }
    return this.toUser(user);
  }

  /** Resolve the profile, including the HD avatar, for the account in the saved Cookie. */
  async fetchCurrentUserProfile(): Promise<WeiboUser> {
    const cookie: string = this.requireAccountCookie();
    const raw: string = await WeiboHttpClient.get('https://m.weibo.cn/api/config', cookie);
    let config: WeiboConfigResponse;
    try {
      config = JSON.parse(raw) as WeiboConfigResponse;
    } catch (error) {
      throw new Error('微博返回了无法解析的登录资料');
    }
    const data: WeiboConfigData | undefined = config.data;
    const uid: string = data?.uid?.trim() ?? '';
    if (config.ok !== 1 || data === undefined || !data.login || uid.length === 0) {
      const message: string = config.msg?.trim() ?? '';
      throw new Error(message.length > 0 ? message : '微博未接受当前登录态，请重新登录后再试');
    }
    return await this.fetchUserProfile(uid);
  }

  async fetchUserTimeline(userId: string, page: number): Promise<WeiboPost[]> {
    const escapedUserId: string = encodeURIComponent(userId.trim());
    const safePage: number = page < 1 ? 1 : page;
    const raw: string = await this.get(
      `https://m.weibo.cn/api/container/getIndex?containerid=230413${escapedUserId}&page=${safePage}&count=20`);
    const response: WeiboApiResponse = this.parseResponse(raw);
    const cards: WeiboCardJson[] = response.data?.cards ?? [];
    const posts: WeiboPost[] = [];
    for (let index: number = 0; index < cards.length; index++) {
      const card: WeiboCardJson = cards[index];
      if (card.card_type === 9 && card.mblog !== undefined) {
        posts.push(this.toPost(card.mblog));
      }
    }
    return posts;
  }

  /** Public recommendation timeline used by the first tab. */
  async fetchRecommendTimeline(page: number): Promise<WeiboPost[]> {
    const safePage: number = page < 1 ? 1 : page;
    const raw: string = await this.get(
      `https://m.weibo.cn/api/container/getIndex?containerid=102803&page=${safePage}`);
    return this.postsFromResponse(raw);
  }

  /**
   * The logged-in account's following timeline. The mobile `231093` container
   * lists followed users, while this desktop feed returns their actual posts.
   */
  async fetchFollowingTimeline(maxId: string): Promise<WeiboTimelinePage> {
    const cookie: string = this.requireAccountCookie();
    const cursor: string = maxId.trim().length > 0 ? maxId.trim() : '0';
    const raw: string = await WeiboHttpClient.getDesktop(
      `https://weibo.com/ajax/feed/friendstimeline?count=20&max_id=${encodeURIComponent(cursor)}`, cookie);
    return this.followingPageFromResponse(raw, cursor);
  }

  /**
   * Search posts through Weibo's mobile search container. It uses the same
   * account-or-visitor session as the timeline, so public results work before
   * login and a saved Cookie can return the user's normal search results.
   */
  async fetchSearchPosts(query: string, page: number): Promise<WeiboPost[]> {
    const cleanQuery: string = query.trim();
    if (cleanQuery.length === 0) {
      return [];
    }
    const safePage: number = page < 1 ? 1 : page;
    const containerId: string = `100103type%3D1%26q%3D${encodeURIComponent(cleanQuery)}`;
    const raw: string = await this.get(
      `https://m.weibo.cn/api/container/getIndex?containerid=${containerId}&page_type=searchall&page=${safePage}`);
    return this.postsFromResponse(raw);
  }

  /**
   * Resolves a single post for a routed detail page. The in-memory copy makes
   * the transition immediate; this endpoint is the fallback after recreation.
   */
  async fetchPost(postId: string): Promise<WeiboPost> {
    const id: string = postId.trim();
    if (id.length === 0) {
      throw new Error('微博信息不完整，无法打开详情');
    }
    const raw: string = await this.get(`https://m.weibo.cn/statuses/show?id=${encodeURIComponent(id)}`);
    this.parseResponse(raw);
    const response: WeiboStatusApiResponse = JSON.parse(raw) as WeiboStatusApiResponse;
    if (response.data === undefined) {
      throw new Error('微博没有返回帖子详情');
    }
    const post: WeiboPost = this.toPost(response.data);
    this.recentPost = post;
    return post;
  }

  rememberPost(post: WeiboPost): void {
    this.recentPost = post;
  }

  getRememberedPost(postId: string): WeiboPost | null {
    if (this.recentPost === null || this.recentPost.id !== postId) {
      return null;
    }
    return this.recentPost;
  }

  async fetchComments(postId: string, page: number): Promise<WeiboCommentsPage> {
    const id: string = postId.trim();
    const safePage: number = page < 1 ? 1 : page;
    if (safePage === 1 && this.recentComments !== null && this.recentCommentsPostId === id) {
      return this.recentComments;
    }
    if (safePage === 1 && this.pendingComments !== null && this.pendingCommentsPostId === id) {
      return await this.pendingComments;
    }
    const request: Promise<WeiboCommentsPage> = this.fetchCommentsPage(id, safePage);
    if (safePage !== 1) {
      return await request;
    }
    this.pendingCommentsPostId = id;
    this.pendingComments = request;
    try {
      const result: WeiboCommentsPage = await request;
      this.recentCommentsPostId = id;
      this.recentComments = result;
      return result;
    } finally {
      if (this.pendingCommentsPostId === id) {
        this.pendingCommentsPostId = '';
        this.pendingComments = null;
      }
    }
  }

  /** Starts comments during the route transition; failures remain silent until the detail page needs them. */
  prefetchComments(postId: string): void {
    const id: string = postId.trim();
    if (id.length === 0 || (this.recentComments !== null && this.recentCommentsPostId === id)
      || (this.pendingComments !== null && this.pendingCommentsPostId === id)) {
      return;
    }
    const task: Promise<WeiboCommentsPage> = this.fetchComments(id, 1);
    task.then(
      (): void => {},
      (): void => {}
    );
  }

  private async fetchCommentsPage(postId: string, page: number): Promise<WeiboCommentsPage> {
    const raw: string = await this.get(
      `https://m.weibo.cn/api/comments/show?id=${encodeURIComponent(postId)}&page=${page}`);
    const response: WeiboApiResponse = this.parseResponse(raw);
    const source: WeiboCommentJson[] = response.data?.data ?? [];
    const items: WeiboComment[] = [];
    for (let index: number = 0; index < source.length; index++) {
      items.push(this.toComment(source[index]));
    }
    const maxId: string = response.data?.max_id ?? '';
    return { items: items, nextMaxId: maxId, hasMore: maxId.length > 0 && maxId !== '0' };
  }

  /** Like or cancel a like. This is never called automatically. */
  async setLike(postId: string, like: boolean): Promise<void> {
    const id: string = postId.trim();
    const cookie: string = this.requireAccountCookie();
    if (id.length === 0) {
      throw new Error('微博信息不完整，无法点赞');
    }
    const form: rcp.Form = new rcp.Form({ id: id });
    form.keys = ['id'];
    const endpoint: string = like
      ? 'https://weibo.com/ajax/statuses/setLike'
      : 'https://weibo.com/ajax/statuses/cancelLike';
    const raw: string = await WeiboHttpClient.postForm(endpoint, cookie, form);
    this.parseResponse(raw);
  }

  /** Publish one user-authored comment after the user presses Send. */
  async publishComment(postId: string, content: string): Promise<void> {
    const id: string = postId.trim();
    const cleanContent: string = content.trim();
    const cookie: string = this.requireAccountCookie();
    if (id.length === 0 || cleanContent.length === 0) {
      throw new Error('评论内容不能为空');
    }
    const form: rcp.Form = new rcp.Form({ id: id, content: cleanContent });
    form.keys = ['id', 'content'];
    const raw: string = await WeiboHttpClient.postForm('https://m.weibo.cn/api/comments/create', cookie, form);
    this.parseResponse(raw);
  }

  /**
   * Public hot-search board. It is intentionally kept separate from the mobile
   * session endpoints, so it can work without the user's account cookie.
   */
  async fetchHotTopics(limit: number): Promise<WeiboHotTopic[]> {
    const raw: string = await WeiboHttpClient.getDesktop('https://weibo.com/ajax/side/hotSearch');
    const response: WeiboApiResponse = this.parseResponse(raw);
    const source: WeiboHotTopicJson[] = response.data?.realtime ?? [];
    const result: WeiboHotTopic[] = [];
    const safeLimit: number = limit > 0 ? limit : source.length;
    for (let index: number = 0; index < source.length && index < safeLimit; index++) {
      const item: WeiboHotTopicJson = source[index];
      const word: string = item.word?.trim() ?? '';
      if (word.length === 0) {
        continue;
      }
      result.push({
        rank: item.rank ?? item.realpos ?? index + 1,
        word: word,
        heat: item.num ?? 0,
        label: item.label_name ?? '',
        query: item.word_scheme ?? word,
      });
    }
    return result;
  }

  /** Public search autocomplete. A full result page still requires a user session. */
  async fetchSuggestions(query: string, limit: number): Promise<WeiboSuggestion[]> {
    const cleanQuery: string = query.trim();
    if (cleanQuery.length === 0) {
      return [];
    }
    const raw: string = await WeiboHttpClient.getDesktop(
      `https://weibo.com/ajax/side/search?q=${encodeURIComponent(cleanQuery)}`);
    const response: WeiboApiResponse = this.parseResponse(raw);
    const source: WeiboSuggestionJson[] = response.data?.hotquery ?? [];
    const result: WeiboSuggestion[] = [];
    const safeLimit: number = limit > 0 ? limit : source.length;
    for (let index: number = 0; index < source.length && index < safeLimit; index++) {
      const item: WeiboSuggestionJson = source[index];
      const word: string = item.suggestion?.trim() ?? '';
      if (word.length > 0) {
        result.push({ word: word, count: item.count ?? 0, isHot: item.top_flag === 2 });
      }
    }
    return result;
  }

  private async get(url: string): Promise<string> {
    const accountCookie: string = WeiboAuthManager.getInstance().getCookie();
    const visitorCookie: string = WeiboVisitorSession.getInstance().getCookie();
    const cookie: string = accountCookie.length > 0 ? accountCookie : visitorCookie;
    return WeiboHttpClient.get(url, cookie);
  }

  private postsFromResponse(raw: string): WeiboPost[] {
    const response: WeiboApiResponse = this.parseResponse(raw);
    const cards: WeiboCardJson[] = response.data?.cards ?? [];
    const posts: WeiboPost[] = [];
    this.appendPostsFromCards(cards, posts);
    return posts;
  }

  private followingPageFromResponse(raw: string, requestedMaxId: string): WeiboTimelinePage {
    const trimmed: string = raw.trim();
    if (trimmed.startsWith('<!DOCTYPE') || trimmed.startsWith('<html') || trimmed.includes('passport.weibo.com')) {
      throw new Error('微博未接受当前登录态，请重新登录后再试');
    }
    let response: WeiboFollowingTimelineResponse;
    try {
      response = JSON.parse(raw) as WeiboFollowingTimelineResponse;
    } catch (error) {
      throw new Error('微博返回了无法解析的关注动态');
    }
    if (response.ok !== 1) {
      const message: string = response.msg?.trim() ?? '';
      throw new Error(message.length > 0 ? message : '微博关注动态接口暂不可用，请稍后重试');
    }
    const source: WeiboPostJson[] = response.statuses ?? [];
    const items: WeiboPost[] = [];
    for (let index: number = 0; index < source.length; index++) {
      items.push(this.toPost(source[index]));
    }
    const cursorValue: string | number | undefined = response.max_id;
    const nextMaxId: string = cursorValue === undefined ? '' : `${cursorValue}`;
    const hasMore: boolean = items.length > 0 && nextMaxId.length > 0
      && nextMaxId !== '0' && nextMaxId !== requestedMaxId;
    return { items: items, nextMaxId: nextMaxId, hasMore: hasMore };
  }

  private appendPostsFromCards(cards: WeiboCardJson[], posts: WeiboPost[]): void {
    for (let index: number = 0; index < cards.length; index++) {
      const card: WeiboCardJson = cards[index];
      if (card.mblog !== undefined && (card.card_type === 9 || card.card_type === undefined)) {
        posts.push(this.toPost(card.mblog));
      }
      const group: WeiboCardJson[] | undefined = card.card_group;
      if (group !== undefined) {
        this.appendPostsFromCards(group, posts);
      }
    }
  }

  private requireAccountCookie(): string {
    const cookie: string = WeiboAuthManager.getInstance().getCookie();
    if (!WeiboAuthManager.getInstance().hasCookie()) {
      throw new Error('请先在“我的”中粘贴你自己的微博登录 Cookie');
    }
    return cookie;
  }

  private parseResponse(raw: string): WeiboApiResponse {
    const trimmed: string = raw.trim();
    if (trimmed.startsWith('<!DOCTYPE') || trimmed.startsWith('<html') || trimmed.includes('visitor.passport.weibo.cn')) {
      throw new Error('微博未接受当前登录态，请重新登录后再试');
    }
    let response: WeiboApiResponse;
    try {
      response = JSON.parse(raw) as WeiboApiResponse;
    } catch (error) {
      throw new Error('微博返回了无法解析的数据');
    }
    if (response.ok !== 1) {
      const message: string = response.msg?.trim() ?? '';
      const url: string = response.url ?? '';
      if (url.includes('captcha')) {
        throw new Error('微博要求验证码，请在设置中更新 Cookie 后重试');
      }
      throw new Error(message.length > 0 ? message : '微博接口暂不可用，请稍后重试');
    }
    return response;
  }

  private toUser(source: WeiboUserJson): WeiboUser {
    const hdAvatar: string = source.avatar_hd?.trim() ?? '';
    const avatar: string = hdAvatar.length > 0 ? hdAvatar : (source.profile_image_url?.trim() ?? '');
    const rawId: string | number | undefined = source.id;
    const rawFollowersCount: string | number | undefined = source.followers_count;
    const rawFollowingCount: string | number | undefined = source.follow_count;
    const rawStatusesCount: string | number | undefined = source.statuses_count;
    const userId: string = rawId === undefined ? '' : `${rawId}`;
    const followersCount: string = rawFollowersCount === undefined ? '' : `${rawFollowersCount}`;
    const followingCount: number = rawFollowingCount === undefined ? 0 : Number(rawFollowingCount);
    const statusesCount: number = rawStatusesCount === undefined ? 0 : Number(rawStatusesCount);
    return {
      id: userId,
      screenName: source.screen_name ?? '',
      description: source.description ?? '',
      avatarUrl: avatar,
      coverUrl: source.cover_image_phone ?? '',
      followersCount: followersCount,
      followingCount: followingCount,
      statusesCount: statusesCount,
      verified: source.verified ?? false,
      verifiedReason: source.verified_reason ?? '',
    };
  }

  private toPost(source: WeiboPostJson): WeiboPost {
    const author: WeiboUser = this.toUser(source.user ?? {});
    const pictures: string[] = [];
    const pictureSource: WeiboPictureJson[] = source.pics ?? [];
    for (let index: number = 0; index < pictureSource.length; index++) {
      const picture: WeiboPictureJson = pictureSource[index];
      // The mobile endpoint normally returns the original file in `original`.
      // Keep high-quality fallbacks for cards whose original field is omitted.
      const imageUrl: string = picture.original?.url
        ?? picture.largest?.url
        ?? picture.mw2000?.url
        ?? picture.large?.url
        ?? picture.url
        ?? '';
      if (imageUrl.length > 0) {
        pictures.push(imageUrl);
      }
    }
    const pageInfo: WeiboPageInfoJson | undefined = source.page_info;
    const mediaInfo: WeiboVideoMediaInfoJson | undefined = pageInfo?.media_info;
    const videoUrls: WeiboVideoUrlsJson | undefined = pageInfo?.urls;
    const videoUrl: string = mediaInfo?.stream_url_hd
      ?? mediaInfo?.stream_url
      ?? videoUrls?.mp4_1080p_60fps
      ?? videoUrls?.mp4_1080p_mp4
      ?? videoUrls?.mp4_hd_mp4
      ?? mediaInfo?.mp4_hd_mp4
      ?? videoUrls?.mp4_720p_mp4
      ?? mediaInfo?.mp4_720p_mp4
      ?? videoUrls?.mp4_sd_mp4
      ?? videoUrls?.mp4_ld_mp4
      ?? source.video_url
      ?? '';
    const videoCoverUrl: string = pageInfo?.page_pic?.url ?? source.thumbnail_pic ?? '';
    const repostSource: WeiboPostJson | undefined = source.retweeted_status;
    const rawPostId: string | number | undefined = source.id ?? source.mid;
    const postId: string = rawPostId === undefined ? '' : `${rawPostId}`;
    return {
      id: postId,
      userId: author.id,
      userName: author.screenName,
      userAvatar: author.avatarUrl,
      text: stripHtml(source.text ?? ''),
      pictures: pictures,
      videoUrl: videoUrl,
      videoCoverUrl: videoCoverUrl,
      createdAt: formatWeiboTime(source.created_at ?? ''),
      source: stripHtml(source.source ?? ''),
      likeCount: source.attitudes_count ?? 0,
      commentCount: source.comments_count ?? 0,
      repostCount: source.reposts_count ?? 0,
      isLiked: source.attitudes_status === 1,
      repost: repostSource === undefined ? null : this.toPost(repostSource),
    };
  }

  private toComment(source: WeiboCommentJson): WeiboComment {
    const author: WeiboUser = this.toUser(source.user ?? {});
    return {
      id: source.id ?? '',
      userId: author.id,
      userName: author.screenName,
      userAvatar: author.avatarUrl,
      text: stripHtml(source.text ?? ''),
      createdAt: formatWeiboTime(source.created_at ?? ''),
      likeCount: source.like_count ?? 0,
    };
  }
}
