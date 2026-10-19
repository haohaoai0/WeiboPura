const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { createLoader } = require('./ets-loader.cjs');

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

test('WeiboService.fetchSearchSuggestions parses matched users and topic/hot suggestions', async () => {
  const { service, calls, respond } = serviceHarness();
  respond({
    ok: 1,
    data: {
      users: [
        {
          idstr: '1682390881',
          screen_name: '钟文泽',
          profile_image_url: 'https://tvax1.sinaimg.cn/crop.0.0.1080.1080.180/avatar.jpg',
          description: '知名数码博主 微博签约自媒体',
          followers_count: 5120000,
          verified: true,
          verified_type: 0
        }
      ],
      hotquery: [
        { suggestion: '#小泽的日常#', count: 120530, top_flag: 0, topic_flag: 1 },
        { suggestion: '钟文泽 iPhone Air', count: 98200, top_flag: 2, topic_flag: 0 },
        { suggestion: '钟文泽 小米折叠屏', count: 45000, top_flag: 0, topic_flag: 0 }
      ]
    }
  });

  const bundle = await service.fetchSearchSuggestions('钟文泽', 10);
  assert.equal(calls.length, 1);
  assert.match(calls[0].url, /weibo\.com\/ajax\/side\/search\?q=%E9%92%9F%E6%96%87%E6%B3%BD/);

  // Users check
  assert.equal(bundle.users.length, 1);
  assert.equal(bundle.users[0].id, '1682390881');
  assert.equal(bundle.users[0].screenName, '钟文泽');
  assert.equal(bundle.users[0].verified, true);
  assert.equal(bundle.users[0].description, '知名数码博主 微博签约自媒体');

  // Suggestions check
  assert.equal(bundle.suggestions.length, 3);
  assert.equal(bundle.suggestions[0].word, '#小泽的日常#');
  assert.equal(bundle.suggestions[0].isTopic, true);
  assert.equal(bundle.suggestions[0].isHot, false);

  assert.equal(bundle.suggestions[1].word, '钟文泽 iPhone Air');
  assert.equal(bundle.suggestions[1].isTopic, false);
  assert.equal(bundle.suggestions[1].isHot, true);

  assert.equal(bundle.suggestions[2].word, '钟文泽 小米折叠屏');
  assert.equal(bundle.suggestions[2].isTopic, false);
  assert.equal(bundle.suggestions[2].isHot, false);
});

test('WeiboService.fetchSearchSuggestions short-circuits empty queries without request', async () => {
  const { service, calls } = serviceHarness();
  const bundle = await service.fetchSearchSuggestions('   ', 10);
  assert.equal(calls.length, 0);
  assert.equal(bundle.users.length, 0);
  assert.equal(bundle.suggestions.length, 0);
});

test('WeiboService.fetchSuggestions backward compatibility wraps fetchSearchSuggestions', async () => {
  const { service, calls, respond } = serviceHarness();
  respond({
    ok: 1,
    data: {
      hotquery: [
        { suggestion: '鸿蒙NEXT', count: 8888, top_flag: 2, topic_flag: 0 }
      ]
    }
  });

  const list = await service.fetchSuggestions('鸿蒙', 5);
  assert.equal(calls.length, 1);
  assert.equal(list.length, 1);
  assert.equal(list[0].word, '鸿蒙NEXT');
  assert.equal(list[0].isHot, true);
});

test('WeiboHotSearch Discover page implements search suggestions, user card, insert button, and history', () => {
  const hotSearchPath = path.join(__dirname, '../entry/src/main/ets/pages/WeiboHotSearch.ets');
  const src = fs.readFileSync(hotSearchPath, 'utf8');

  // Debounced search suggestion input
  assert.match(src, /onKeywordChanged/);
  assert.match(src, /fetchSearchSuggestions/);
  assert.match(src, /debounceTimer/);

  // Direct user card with profile action
  assert.match(src, /UserDirectCard/);
  assert.match(src, /onOpenUserProfile/);

  // Suggestion row with topic/hot badges and ↖ insert affordance
  assert.match(src, /SuggestionRow/);
  assert.match(src, /insertSuggestion/);
  assert.match(src, /'↖'/);

  // Search history section with persistent disk cache
  assert.match(src, /SearchHistorySection/);
  assert.match(src, /weiboSearchHistory/);
  assert.match(src, /CacheManager\.getInstance\(\)\.get\(CACHE_KEY\.WEIBO_SEARCH_HISTORY\)/);
  assert.match(src, /CacheManager\.getInstance\(\)\.put\(CACHE_KEY\.WEIBO_SEARCH_HISTORY/);

  // Exact matching user header is removed for cleaner presentation
  assert.doesNotMatch(src, /精确匹配用户/);

  // Keyword highlighting
  assert.match(src, /HighlightText/);
  assert.match(src, /splitByQuery/);
});

test('Index.ets Discover tab uses weibo_tab_discover and sys.symbol.compass', () => {
  const indexPath = path.join(__dirname, '../entry/src/main/ets/pages/Index.ets');
  const src = fs.readFileSync(indexPath, 'utf8');

  // Title and tab bar use discover string
  assert.match(src, /if \(this\.selectedTab === WeiboTab\.Discover\) \{\s*return \$r\('app\.string\.weibo_tab_discover'\);/);
  assert.match(src, /this\.hdsTabBar\(this\.symbolFor\(WeiboTab\.Discover\), \$r\('app\.string\.weibo_tab_discover'\)\)/);

  // Tab symbol uses compass
  assert.match(src, /if \(index === WeiboTab\.Discover\) \{\s*return \$r\('sys\.symbol\.compass'\);/);

  // Passes onOpenUserProfile to WeiboHotSearch
  assert.match(src, /onOpenUserProfile:\s*\(userId:\s*string,\s*userName:\s*string\):\s*void\s*=>\s*\{\s*this\.openUserProfile\(userId,\s*userName\);/);
});
