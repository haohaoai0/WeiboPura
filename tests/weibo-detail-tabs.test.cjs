const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { createLoader, createMethodHarness } = require('./ets-loader.cjs');

test('WeiboModel exports WeiboDetailTab with Reposts, Comments, Likes', () => {
  const modelSource = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/model/WeiboModel.ets'), 'utf8');
  assert.ok(modelSource.includes('export enum WeiboDetailTab'));
  assert.ok(modelSource.includes('Reposts = 0'));
  assert.ok(modelSource.includes('Comments = 1'));
  assert.ok(modelSource.includes('Likes = 2'));
  assert.ok(modelSource.includes('export interface WeiboLikeUser'));
  assert.ok(modelSource.includes('export interface WeiboLikesPage'));
  assert.ok(modelSource.includes('export interface WeiboRepostsPage'));
});

test('WeiboService formatFollowersCount formats count strings and numbers accurately', () => {
  const load = createLoader({
    './WeiboAuthManager': { WeiboAuthManager: { getInstance: () => ({ getSessionRevision: () => 1, getCookie: () => '' }) } },
    './WeiboVisitorSession': { WeiboVisitorSession: { getInstance: () => ({ getCookie: () => '' }) } },
    '../network/WeiboHttpClient': { WeiboHttpClient: {} },
    '../common/Constants': { formatWeiboTime: t => t, stripHtml: t => t },
    '../common/WeiboText': { normalizeWeiboText: t => t, midToBid: t => t, bidToMid: t => t },
    '../common/WeiboMediaMetadata': { weiboLivePhotoTracks: () => null },
    './WeiboMedia': { prepareWeiboImage: async () => {}, WeiboUploadImage: {} },
    '@kit.RemoteCommunicationKit': { rcp: {} }
  });
  const { WeiboService } = load('service/WeiboService');
  const service = WeiboService.getInstance();

  assert.equal(service.formatFollowersCount(undefined), '0');
  assert.equal(service.formatFollowersCount(null), '0');
  assert.equal(service.formatFollowersCount(''), '0');
  assert.equal(service.formatFollowersCount(112), '112');
  assert.equal(service.formatFollowersCount('1179'), '1179');
  assert.equal(service.formatFollowersCount(12000), '1.2万');
  assert.equal(service.formatFollowersCount(250000000), '2.5亿');
});

test('WeiboService fetchPostLikes fetches mobile attitudes and extracts users', async () => {
  let requestedUrl = '', requestedReferer = '';
  const load = createLoader({
    './WeiboAuthManager': { WeiboAuthManager: { getInstance: () => ({ getSessionRevision: () => 1, getCookie: () => 'SUB=test', assertSession: () => {} }) } },
    './WeiboVisitorSession': { WeiboVisitorSession: { getInstance: () => ({ getCookie: () => '' }) } },
    '../network/WeiboHttpClient': {
      WeiboHttpClient: {
        get: async (url, cookie, referer) => {
          requestedUrl = url;
          requestedReferer = referer;
          return JSON.stringify({
            ok: 1,
            data: {
              data: [
                {
                  id: 1001,
                  user: {
                    id: 1001,
                    screen_name: '墨月萧芋',
                    profile_image_url: 'https://tvax1.sinaimg.cn/avatar1.jpg',
                    followers_count: 112,
                    verified: false
                  }
                },
                {
                  id: 1002,
                  user: {
                    idstr: '1002',
                    screen_name: '带毛老师',
                    avatar_large: 'https://tvax2.sinaimg.cn/avatar2.jpg',
                    followers_count: 142,
                    verified: true,
                    verified_type: 0
                  }
                }
              ]
            }
          });
        },
        getDesktop: async () => JSON.stringify({ ok: 1, data: [] })
      }
    },
    '../common/Constants': { formatWeiboTime: t => t, stripHtml: t => t },
    '../common/WeiboText': { normalizeWeiboText: t => t, midToBid: t => t, bidToMid: t => t },
    '../common/WeiboMediaMetadata': { weiboLivePhotoTracks: () => null },
    './WeiboMedia': { prepareWeiboImage: async () => {}, WeiboUploadImage: {} },
    '@kit.RemoteCommunicationKit': { rcp: {} }
  });
  const { WeiboService } = load('service/WeiboService');
  const service = WeiboService.getInstance();

  const res = await service.fetchPostLikes('5087532323733671', 1);
  assert.ok(requestedUrl.includes('m.weibo.cn/api/attitudes/show?id=5087532323733671&page=1'));
  assert.equal(requestedReferer, 'https://m.weibo.cn/detail/5087532323733671');
  assert.equal(res.items.length, 2);
  assert.equal(res.items[0].userName, '墨月萧芋');
  assert.equal(res.items[0].followersCount, '112');
  assert.equal(res.items[0].verified, false);
  assert.equal(res.items[1].userName, '带毛老师');
  assert.equal(res.items[1].followersCount, '142');
  assert.equal(res.items[1].verified, true);
  assert.equal(res.nextPage, 2);
});

test('WeiboService fetchPostLikes falls back to desktop likeList when mobile fails', async () => {
  let desktopCalled = false;
  const load = createLoader({
    './WeiboAuthManager': { WeiboAuthManager: { getInstance: () => ({ getSessionRevision: () => 1, getCookie: () => 'SUB=test', assertSession: () => {} }) } },
    './WeiboVisitorSession': { WeiboVisitorSession: { getInstance: () => ({ getCookie: () => '' }) } },
    '../network/WeiboHttpClient': {
      WeiboHttpClient: {
        get: async () => {
          throw new Error('mobile net error');
        },
        getDesktop: async (url) => {
          desktopCalled = true;
          assert.ok(url.includes('weibo.com/ajax/statuses/likeList?id=5087532323733671&page=1'));
          return JSON.stringify({
            ok: 1,
            data: [
              {
                id: '2001',
                user: {
                  idstr: '2001',
                  screen_name: 'Imagine-J',
                  profile_image_url: 'https://tvax3.sinaimg.cn/avatar3.jpg',
                  followers_count_str: '1179',
                  verified: false
                }
              }
            ]
          });
        }
      }
    },
    '../common/Constants': { formatWeiboTime: t => t, stripHtml: t => t },
    '../common/WeiboText': { normalizeWeiboText: t => t, midToBid: t => t, bidToMid: t => t },
    '../common/WeiboMediaMetadata': { weiboLivePhotoTracks: () => null },
    './WeiboMedia': { prepareWeiboImage: async () => {}, WeiboUploadImage: {} },
    '@kit.RemoteCommunicationKit': { rcp: {} }
  });
  const { WeiboService } = load('service/WeiboService');
  const service = WeiboService.getInstance();

  const res = await service.fetchPostLikes('5087532323733671', 1);
  assert.equal(desktopCalled, true);
  assert.equal(res.items.length, 1);
  assert.equal(res.items[0].userName, 'Imagine-J');
  assert.equal(res.items[0].followersCount, '1179');
});

test('WeiboService fetchPostReposts fetches mobile repostTimeline and maps to posts', async () => {
  let requestedUrl = '', requestedReferer = '';
  const load = createLoader({
    './WeiboAuthManager': { WeiboAuthManager: { getInstance: () => ({ getSessionRevision: () => 1, getCookie: () => 'SUB=test', assertSession: () => {} }) } },
    './WeiboVisitorSession': { WeiboVisitorSession: { getInstance: () => ({ getCookie: () => '' }) } },
    '../network/WeiboHttpClient': {
      WeiboHttpClient: {
        get: async (url, cookie, referer) => {
          requestedUrl = url;
          requestedReferer = referer;
          return JSON.stringify({
            ok: 1,
            data: {
              data: [
                {
                  id: 'repost-1',
                  text: '转发微博',
                  created_at: 'Wed Oct 09 15:02:00 +0800 2024',
                  source: 'Xiaomi 14',
                  user: {
                    id: 3001,
                    screen_name: 'wyd你过来',
                    profile_image_url: 'https://tvax4.sinaimg.cn/avatar4.jpg',
                    verified: true
                  }
                }
              ]
            }
          });
        },
        getDesktop: async () => JSON.stringify({ ok: 1, data: [] })
      }
    },
    '../common/Constants': { formatWeiboTime: t => t, stripHtml: t => t },
    '../common/WeiboText': { normalizeWeiboText: t => t, midToBid: t => t, bidToMid: t => t },
    '../common/WeiboMediaMetadata': { weiboLivePhotoTracks: () => null },
    './WeiboMedia': { prepareWeiboImage: async () => {}, WeiboUploadImage: {} },
    '@kit.RemoteCommunicationKit': { rcp: {} }
  });
  const { WeiboService } = load('service/WeiboService');
  const service = WeiboService.getInstance();

  const res = await service.fetchPostReposts('5087532323733671', 1);
  assert.ok(requestedUrl.includes('m.weibo.cn/api/statuses/repostTimeline?id=5087532323733671&page=1'));
  assert.equal(requestedReferer, 'https://m.weibo.cn/detail/5087532323733671');
  assert.equal(res.items.length, 1);
  assert.equal(res.items[0].id, 'repost-1');
  assert.equal(res.items[0].userName, 'wyd你过来');
  assert.equal(res.items[0].text, '转发微博');
  assert.equal(res.items[0].source, 'Xiaomi 14');
});

test('WeiboPostDetail formatTabTitle and switchDetailTab manage secondary tabs state', async () => {
  let likesLoaded = false, repostsLoaded = false;
  const mockService = {
    fetchPostLikes: async () => { likesLoaded = true; return { items: [{ id: 'u1', userName: 'User 1', userAvatar: '', followersCount: '10', verified: false }], nextPage: 2, hasMore: false }; },
    fetchPostReposts: async () => { repostsLoaded = true; return { items: [{ id: 'r1', text: 'repost text', userName: 'User 2', userAvatar: '', source: '', createdAt: '', pictures: [] }], nextPage: 2, hasMore: false }; }
  };
  const auth = { getSessionRevision: () => 1, isSessionChanging: () => false };
  const instance = createMethodHarness('pages/WeiboPostDetail.ets', [
    'formatTabTitle', 'switchDetailTab', 'loadLikes', 'loadReposts'
  ], {
    WeiboService: { getInstance: () => mockService },
    WeiboAuthManager: { getInstance: () => auth },
    Haptic: { light() {} },
    WeiboDetailTab: { Reposts: 0, Comments: 1, Likes: 2 }
  });

  Object.assign(instance, {
    postId: 'test-post',
    activeDetailTab: 1,
    likes: [],
    likesLoading: false,
    likesLoadingMore: false,
    likesPage: 1,
    hasMoreLikes: true,
    likesError: '',
    reposts: [],
    repostsLoading: false,
    repostsLoadingMore: false,
    repostsPage: 1,
    hasMoreReposts: true,
    repostsError: ''
  });

  // Test formatTabTitle
  assert.equal(instance.formatTabTitle('转发', 0), '转发 (0)');
  assert.equal(instance.formatTabTitle('评论', 20), '评论 (20)');
  assert.equal(instance.formatTabTitle('赞', 111), '赞 (111)');
  assert.equal(instance.formatTabTitle('赞', 15000), '赞 (1.5万)');

  // Switch to Likes tab -> triggers loadLikes
  instance.switchDetailTab(2);
  assert.equal(instance.activeDetailTab, 2);
  assert.equal(likesLoaded, true);
  await new Promise(r => setTimeout(r, 10));
  assert.equal(instance.likes.length, 1);

  // Switch to Reposts tab -> triggers loadReposts
  instance.switchDetailTab(0);
  assert.equal(instance.activeDetailTab, 0);
  assert.equal(repostsLoaded, true);
  await new Promise(r => setTimeout(r, 10));
  assert.equal(instance.reposts.length, 1);
});

test('WeiboPostDetail UI source contains DetailTabsHeader, secondary sections, and bottom composer linkage', () => {
  const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/pages/WeiboPostDetail.ets'), 'utf8');

  // Verify DetailTabsHeader with Reposts, Comments, Likes
  assert.ok(source.includes("DetailTabsHeader()"));
  assert.ok(source.includes("DetailTabItem('转发', this.post?.repostCount ?? 0, WeiboDetailTab.Reposts)"));
  assert.ok(source.includes("DetailTabItem('评论', this.post?.commentCount ?? 0, WeiboDetailTab.Comments)"));
  assert.ok(source.includes("DetailTabItem('赞', this.post?.likeCount ?? 0, WeiboDetailTab.Likes)"));

  // Verify active indicator line with Theme.brand()
  assert.ok(source.includes(".backgroundColor(Theme.brand())"));

  // Verify secondary bodies
  assert.ok(source.includes("CommentsBody()"));
  assert.ok(source.includes("LikesBody()"));
  assert.ok(source.includes("RepostsBody()"));

  // Verify like user item and repost item
  assert.ok(source.includes("LikeUserItem(user: WeiboLikeUser)"));
  assert.ok(source.includes("RepostItem(repost: WeiboPost)"));
  assert.ok(source.includes("粉丝：${user.followersCount"));

  // Verify bottom composer comment button activates Comments tab
  assert.ok(source.includes("this.activeDetailTab = WeiboDetailTab.Comments;"));
  assert.ok(source.includes("this.scrollToComments();"));

  // Verify onScrollEdge supports Comments, Likes, and Reposts
  assert.ok(source.includes("this.loadMoreLikes()"));
  assert.ok(source.includes("this.loadMoreReposts()"));

  // Verify instant-open synchronization: synchronous loadRoutePostSync and routeParam.post
  assert.ok(source.includes("loadRoutePostSync()"));
  assert.ok(source.includes("post?: WeiboPost;"));
  assert.ok(source.includes("routeParam.post ?? WeiboService.getInstance().getRememberedPost(this.postId)"));
});
