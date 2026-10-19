const test = require('node:test');
const assert = require('node:assert/strict');
const { createLoader, createMethodHarness } = require('./ets-loader.cjs');

function serviceHarness() {
  let revision = 1;
  let cookie = 'SUB=account-a';
  let response = { ok: 1, data: {} };
  const calls = [];
  const auth = {
    getCookie: () => cookie,
    hasCookie: () => cookie.includes('SUB='),
    getSessionRevision: () => revision,
    assertSession(r) { if (r !== revision) throw new Error('账号会话已变更'); }
  };
  const http = {};
  for (const method of ['get', 'getDesktop', 'postForm']) {
    http[method] = async (url, c, form) => {
      calls.push({ method, url, cookie: c, fields: form?.fields });
      if (response instanceof Error) throw response;
      return typeof response === 'function' ? response(url, c) : JSON.stringify(response);
    };
  }
  class Form { constructor(fields) { this.fields = fields; } }
  const load = createLoader({
    '@kit.RemoteCommunicationKit': { rcp: { Form, MultipartForm: Form } },
    '@kit.ArkTS': { util: { TextDecoder: class { decodeWithStream(b) { return new TextDecoder().decode(b); } } } },
    '../network/WeiboHttpClient': { WeiboHttpClient: http },
    './WeiboAuthManager': { WeiboAuthManager: { getInstance: () => auth } },
    './WeiboVisitorSession': { WeiboVisitorSession: { getInstance: () => ({ getCookie: () => 'SUB=visitor-cookie' }) } },
    './WeiboMedia': { prepareWeiboImage: async () => ({ data: new ArrayBuffer(8), mimeType: 'image/gif', fileName: 'weibo.gif' }) }
  });
  return {
    service: load('service/WeiboService').WeiboService.getInstance(),
    calls,
    respond(value) { response = value; }
  };
}

test('fetchSearchPosts formats category container IDs and carries search referer', async () => {
  const { service, calls, respond } = serviceHarness();
  respond({
    ok: 1,
    data: {
      cards: [
        {
          card_type: 9,
          mblog: { idstr: '1001', text: '综合或实时博文', user: { idstr: 'u1', screen_name: '博主1' } }
        }
      ]
    }
  });

  // 1. All (type=1)
  const allPosts = await service.fetchSearchPosts('钟文泽', 1, 1);
  assert.equal(allPosts.length, 1);
  assert.equal(allPosts[0].id, '1001');
  assert.ok(calls[calls.length - 1].url.includes('100103type%3D1%26q%3D%E9%92%9F%E6%96%87%E6%B3%BD'));

  // 2. Realtime (type=61)
  const realtimePosts = await service.fetchSearchPosts('钟文泽', 2, 61);
  assert.equal(realtimePosts.length, 1);
  assert.ok(calls[calls.length - 1].url.includes('100103type%3D61%26q%3D%E9%92%9F%E6%96%87%E6%B3%BD'));
  assert.ok(calls[calls.length - 1].url.includes('page=2'));

  // 3. Video (type=64)
  await service.fetchSearchPosts('数码评测', 1, 64);
  assert.ok(calls[calls.length - 1].url.includes('100103type%3D64%26q%3D%E6%95%B0%E7%A0%81%E8%AF%84%E6%B5%8B'));

  // 4. Image (type=63)
  await service.fetchSearchPosts('摄影作品', 1, 63);
  assert.ok(calls[calls.length - 1].url.includes('100103type%3D63%26q%3D%E6%91%84%E5%BD%B1%E4%BD%9C%E5%93%81'));
});

test('fetchSearchUsers extracts users and deduplicates from cards and card_groups', async () => {
  const { service, calls, respond } = serviceHarness();
  respond({
    ok: 1,
    data: {
      cards: [
        {
          card_type: 11,
          user: {
            idstr: '4321',
            screen_name: '钟文泽',
            description: '科技数码博主',
            avatar_hd: 'https://avatar.hd/1.jpg',
            followers_count: '432万',
            statuses_count: 12000,
            verified: true,
            verified_reason: '知名数码博主',
            following: true
          }
        },
        {
          card_type: 11,
          card_group: [
            {
              card_type: 10,
              user: {
                idstr: '4322',
                screen_name: '钟文泽工作室',
                description: '团队官方账号',
                avatar_hd: 'https://avatar.hd/2.jpg',
                followers_count: '18万',
                following: false
              }
            },
            {
              card_type: 10,
              user: {
                idstr: '4321', // Duplicate ID
                screen_name: '钟文泽重复'
              }
            }
          ]
        }
      ]
    }
  });

  const users = await service.fetchSearchUsers('钟文泽', 1);
  assert.equal(users.length, 2);
  assert.equal(users[0].id, '4321');
  assert.equal(users[0].screenName, '钟文泽');
  assert.equal(users[0].verified, true);
  assert.equal(users[0].verifiedReason, '知名数码博主');
  assert.equal(users[0].following, true);
  assert.equal(users[1].id, '4322');
  assert.equal(users[1].screenName, '钟文泽工作室');
  assert.equal(users[1].following, false);
  assert.ok(calls[calls.length - 1].url.includes('100103type%3D3%26q%3D%E9%92%9F%E6%96%87%E6%B3%BD'));
});

test('fetchSearchComposite separates posts and extracts top highlight user for comprehensive search', async () => {
  const { service, respond } = serviceHarness();
  respond({
    ok: 1,
    data: {
      cards: [
        {
          card_type: 11,
          card_group: [
            {
              card_type: 10,
              user: {
                idstr: '9988',
                screen_name: '置顶权威博主',
                description: '数码达人',
                avatar_hd: 'https://avatar.hd/top.jpg',
                followers_count: '500万',
                following: true
              }
            }
          ]
        },
        {
          card_type: 9,
          mblog: {
            idstr: 'post_101',
            text: '热门讨论博文',
            user: { idstr: 'u2', screen_name: '普通网友' }
          }
        }
      ]
    }
  });

  const result = await service.fetchSearchComposite('钟文泽', 1, 1);
  assert.equal(result.posts.length, 1);
  assert.equal(result.posts[0].id, 'post_101');
  assert.ok(result.highlightUser !== null);
  assert.equal(result.highlightUser.id, '9988');
  assert.equal(result.highlightUser.screenName, '置顶权威博主');
  assert.equal(result.highlightUser.following, true);
});

test('fetchCommentReplies falls back to desktop buildComments when mobile hotFlowChild rejects second page', async () => {
  const { service, calls, respond } = serviceHarness();

  // Page 1 succeeds on mobile hotFlowChild
  respond((url) => {
    if (url.includes('hotFlowChild')) {
      return JSON.stringify({
        ok: 1,
        max_id: '4761565561881496',
        data: [{ idstr: 'child_1', text: '第一页回复', user: { screen_name: '网友A' } }]
      });
    }
    throw new Error('unexpected call');
  });

  const page1 = await service.fetchCommentReplies('parent_comment_1', '0');
  assert.equal(page1.items.length, 1);
  assert.equal(page1.items[0].id, 'child_1');
  assert.equal(page1.nextMaxId, '4761565561881496');
  assert.equal(page1.hasMore, true);

  // Page 2: mobile hotFlowChild returns ok: -100 (login required), triggering desktop fallback
  respond((url) => {
    if (url.includes('hotFlowChild')) {
      // Returns SSO redirect / login requirement
      return JSON.stringify({
        ok: -100,
        url: 'https://passport.weibo.com/sso/signin'
      });
    }
    if (url.includes('buildComments')) {
      // Desktop buildComments succeeds with fetch_level=1
      return JSON.stringify({
        ok: 1,
        max_id: '4761569999999999',
        data: [{ idstr: 'child_2', text: '第二页回复来自桌面端接口', user: { screen_name: '网友B' } }]
      });
    }
    throw new Error('unexpected url: ' + url);
  });

  const page2 = await service.fetchCommentReplies('parent_comment_1', '4761565561881496');
  assert.equal(page2.items.length, 1);
  assert.equal(page2.items[0].id, 'child_2');
  assert.equal(page2.items[0].text, '第二页回复来自桌面端接口');
  assert.equal(page2.nextMaxId, '4761569999999999');
  assert.equal(page2.hasMore, true);

  // Verify desktop fallback query parameters
  const lastCall = calls[calls.length - 1];
  assert.equal(lastCall.method, 'getDesktop');
  assert.ok(lastCall.url.includes('id=parent_comment_1'));
  assert.ok(lastCall.url.includes('fetch_level=1'));
  assert.ok(lastCall.url.includes('is_mix=1'));
  assert.ok(lastCall.url.includes('max_id=4761565561881496'));
});

function searchResultHarness(service) {
  const auth = { getSessionRevision: () => 1, isSessionChanging: () => false };
  const instance = createMethodHarness('pages/WeiboSearchResult.ets', [
    'switchTab', 'isContentEmpty', 'toggleFollowUser', 'executeSearch'
  ], {
    WeiboAuthManager: { getInstance: () => auth },
    WeiboService: { getInstance: () => service },
    WeiboSearchType: { All: 1, Realtime: 61, User: 3, Video: 64, Image: 63 },
    Haptic: { light() {} },
    $r: id => id
  });
  Object.assign(instance, {
    query: '钟文泽',
    currentTab: 0,
    tabs: ['综合', '实时', '用户', '视频', '图片'],
    tabTypes: [1, 61, 3, 64, 63],
    posts: [{ id: 'p1' }],
    users: [],
    highlightUser: null,
    currentPage: 1,
    hasMore: true,
    errorMessage: '',
    moreError: '',
    searchEpoch: 0,
    loading: false,
    isLoadingMore: false,
    isRefreshing: false,
    getUIContext: () => ({
      getPromptAction: () => ({ showToast() {} })
    })
  });
  return instance;
}

test('WeiboSearchResult switchTab resets state and re-executes search for new category', async () => {
  let executedQuery = '';
  let executedPage = 0;
  let executedType = 0;
  const mockService = {
    fetchSearchComposite: async (q, p, type) => {
      executedQuery = q;
      executedPage = p;
      executedType = type;
      return { posts: [{ id: `post_type_${type}` }], users: [], highlightUser: null, hasMore: true };
    },
    fetchSearchUsers: async () => []
  };

  const instance = searchResultHarness(mockService);
  assert.equal(instance.currentTab, 0);

  // Switch to 实时 (index 1)
  instance.switchTab(1);
  await new Promise(resolve => setTimeout(resolve, 10));
  assert.equal(instance.currentTab, 1);
  assert.equal(instance.currentPage, 1);
  assert.equal(executedQuery, '钟文泽');
  assert.equal(executedPage, 1);
  assert.equal(executedType, 61);
  assert.equal(instance.posts.length, 1);
  assert.equal(instance.posts[0].id, 'post_type_61');
});

test('WeiboSearchResult isContentEmpty validates posts vs users based on selected tab', () => {
  const instance = searchResultHarness({});

  // Tab 0 (综合): posts non-empty -> not empty
  instance.currentTab = 0;
  instance.posts = [{ id: 'p1' }];
  instance.users = [];
  assert.equal(instance.isContentEmpty(), false);

  // Tab 0 (综合): posts empty and highlightUser null -> empty
  instance.posts = [];
  instance.highlightUser = null;
  assert.equal(instance.isContentEmpty(), true);

  // Tab 0 (综合): posts empty but highlightUser present -> not empty
  instance.highlightUser = { id: 'u1' };
  assert.equal(instance.isContentEmpty(), false);

  // Tab 2 (用户): users non-empty -> not empty
  instance.currentTab = 2;
  instance.posts = [];
  instance.users = [{ id: 'u1' }];
  assert.equal(instance.isContentEmpty(), false);

  // Tab 2 (用户): users empty -> empty
  instance.users = [];
  assert.equal(instance.isContentEmpty(), true);
});
