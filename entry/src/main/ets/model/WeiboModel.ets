/*
 * Weibo data models.
 *
 * These models intentionally describe only the fields consumed by the UI.  The
 * mobile endpoint may add fields at any time, so callers must treat omitted
 * fields as empty values.
 */

export interface WeiboUser {
  id: string;
  screenName: string;
  description: string;
  avatarUrl: string;
  coverUrl: string;
  followersCount: string;
  followingCount: number;
  statusesCount: number;
  verified: boolean;
  verifiedReason: string;
  following: boolean;
}

export interface WeiboPost {
  id: string;
  userId: string;
  userName: string;
  userAvatar: string;
  text: string;
  /** True when the timeline only contains a shortened body that can be expanded. */
  isLongText: boolean;
  pictures: string[];
  /** Still-image URL -> server-provided LivePhoto video track. */
  pictureVideos?: Record<string, string>;
  /** A directly playable MP4 stream supplied by the mobile status endpoint. */
  videoUrl: string;
  /** Poster image for the video stream; used while the player is preparing. */
  videoCoverUrl: string;
  videoAspectRatio?: number;
  createdAt: string;
  source: string;
  likeCount: number;
  commentCount: number;
  repostCount: number;
  isLiked: boolean;
  isFavorited?: boolean;
  isFollowed?: boolean;
  repost: WeiboPost | null;
  /** High-quality selected comment preview displayed in responsive feed card. */
  hotComment?: WeiboComment | null;
}

/** One cursor-based page from the logged-in account's following feed. */
export interface WeiboTimelinePage {
  items: WeiboPost[];
  nextMaxId: string;
  hasMore: boolean;
}

export interface WeiboComment {
  id: string;
  userId: string;
  userName: string;
  userAvatar: string;
  text: string;
  createdAt: string;
  likeCount: number;
  isLiked?: boolean;
  replyCount?: number;
  replies?: WeiboComment[];
  pictures?: string[];
}

export interface WeiboNotification {
  id: string;
  senderId: string;
  senderName: string;
  senderAvatar: string;
  type: 'mention' | 'comment' | 'like';
  title: string;
  content: string;
  targetSnippet: string;
  targetPostId: string;
  targetCommentId?: string;
  createdAt: string;
}

/** Detail page secondary tab selection. */
export enum WeiboDetailTab {
  Reposts = 0,
  Comments = 1,
  Likes = 2,
}

/** A user who liked a status. */
export interface WeiboLikeUser {
  id: string;
  userName: string;
  userAvatar: string;
  followersCount: string;
  verified: boolean;
  verifiedType?: number;
}

export interface WeiboLikesPage {
  items: WeiboLikeUser[];
  nextPage: number;
  hasMore: boolean;
}

export interface WeiboRepostsPage {
  items: WeiboPost[];
  nextPage: number;
  hasMore: boolean;
}

/** Server comment order; new detail pages always start with Hot. */
export enum WeiboCommentSort {
  Hot = 0,
  Latest = 1,
}

export interface WeiboCommentsPage {
  items: WeiboComment[];
  nextMaxId: string;
  hasMore: boolean;
}

/** Search categories corresponding to Weibo mobile container types. */
export enum WeiboSearchType {
  All = 1,
  Realtime = 61,
  User = 3,
  Video = 64,
  Image = 63,
}

export interface WeiboSearchCompositeResult {
  posts: WeiboPost[];
  users: WeiboUser[];
  highlightUser: WeiboUser | null;
  hasMore: boolean;
}

/** A real-time entry from the public Weibo hot-search board. */
export interface WeiboHotTopic {
  rank: number;
  word: string;
  heat: number;
  label: string;
  query: string;
}

/** A public query suggestion from Weibo's desktop search sidebar. */
export interface WeiboSuggestion {
  word: string;
  count: number;
  isHot: boolean;
  isTopic?: boolean;
}

/** Search suggestion bundle with matched users and query completions. */
export interface WeiboSearchSuggestionBundle {
  users: WeiboUser[];
  suggestions: WeiboSuggestion[];
}
