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
}

export interface WeiboPost {
  id: string;
  userId: string;
  userName: string;
  userAvatar: string;
  text: string;
  pictures: string[];
  /** A directly playable MP4 stream supplied by the mobile status endpoint. */
  videoUrl: string;
  /** Poster image for the video stream; used while the player is preparing. */
  videoCoverUrl: string;
  createdAt: string;
  source: string;
  likeCount: number;
  commentCount: number;
  repostCount: number;
  isLiked: boolean;
  repost: WeiboPost | null;
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
}

export interface WeiboCommentsPage {
  items: WeiboComment[];
  nextMaxId: string;
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
}
