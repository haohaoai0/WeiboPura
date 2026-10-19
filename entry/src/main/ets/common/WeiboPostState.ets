import { WeiboPost } from '../model/WeiboModel';

/** Immutable UI state update retaining all media metadata. */
export function withWeiboLike(source: WeiboPost, liked: boolean): WeiboPost {
  return {
    id: source.id, userId: source.userId, userName: source.userName, userAvatar: source.userAvatar,
    text: source.text, isLongText: source.isLongText, pictures: source.pictures, pictureVideos: source.pictureVideos,
    videoUrl: source.videoUrl, videoCoverUrl: source.videoCoverUrl, videoAspectRatio: source.videoAspectRatio,
    isFavorited: source.isFavorited, isFollowed: source.isFollowed, createdAt: source.createdAt, source: source.source,
    likeCount: source.isLiked === liked ? source.likeCount : Math.max(0, source.likeCount + (liked ? 1 : -1)),
    commentCount: source.commentCount, repostCount: source.repostCount, isLiked: liked, repost: source.repost,
    hotComment: source.hotComment
  };
}

/** Immutable UI state update retaining all media metadata when author follow state changes. */
export function withWeiboFollow(source: WeiboPost, followed: boolean): WeiboPost {
  return {
    id: source.id, userId: source.userId, userName: source.userName, userAvatar: source.userAvatar,
    text: source.text, isLongText: source.isLongText, pictures: source.pictures, pictureVideos: source.pictureVideos,
    videoUrl: source.videoUrl, videoCoverUrl: source.videoCoverUrl, videoAspectRatio: source.videoAspectRatio,
    isFavorited: source.isFavorited, isFollowed: followed, createdAt: source.createdAt, source: source.source,
    likeCount: source.likeCount, commentCount: source.commentCount, repostCount: source.repostCount,
    isLiked: source.isLiked, repost: source.repost, hotComment: source.hotComment
  };
}
