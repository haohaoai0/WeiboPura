const test = require('node:test');
const assert = require('node:assert/strict');
const { createLoader } = require('./ets-loader.cjs');
const quiet = { error() {}, info() {}, warn() {} };
function authHarness({ persistenceError = false, webError = false } = {}) {
  const values = new Map(); const calls = [];
  const store = {
    async get(key, fallback) { return values.get(key) ?? fallback; },
    async put(key, value) { if (persistenceError) throw new Error('disk failure'); values.set(key, value); },
    async flush() { calls.push('flush'); }
  };
  const load = createLoader({
    '@kit.ArkData': { preferences: { getPreferences: async () => store } },
    '@kit.PerformanceAnalysisKit': { hilog: quiet },
    '@kit.ArkWeb': { webview: {
      WebCookieManager: { async clearAllCookies() { calls.push('webCookies'); if (webError) throw new Error('web failure'); } },
      WebStorage: { deleteAllData() { calls.push('webStorage'); } }
    } }
  });
  const auth = load('service/WeiboAuthManager').WeiboAuthManager.getInstance();
  return { auth, values, calls, load };
}
test('logout clears app session AND persistent Web login state', async () => {
  const { auth, calls, values } = authHarness(); await auth.init({});
  await auth.setCookie('SUB=account-a'); await auth.setTargetUserId('42');
  await auth.clearCookie();
  assert.equal(auth.hasCookie(), false); assert.equal(auth.getTargetUserId(), '');
  assert.equal(values.get('weibo_readonly_cookie'), '');
  assert.ok(calls.includes('webCookies')); assert.ok(calls.includes('webStorage'));
});
test('failed auth persistence is not reported as login success', async () => {
  const { auth } = authHarness({ persistenceError: true }); await auth.init({});
  await assert.rejects(auth.setCookie('SUB=account-a'), /disk failure/);
  assert.equal(auth.hasCookie(), false);
});
test('Web cleanup failure rejects logout but revokes in-memory session', async () => {
  const { auth, values } = authHarness({ webError: true }); await auth.init({});
  await auth.setCookie('SUB=account-a');
  await assert.rejects(auth.clearCookie(), /Web|web/);
  assert.equal(auth.hasCookie(), false); assert.equal(values.get('weibo_readonly_cookie'), '');
});
test('session revision changes on logout and cannot restore stale captured Cookie', async () => {
  const { auth } = authHarness(); await auth.init({}); await auth.setCookie('SUB=account-a');
  const revision = auth.getSessionRevision(); await auth.clearCookie();
  assert.notEqual(auth.getSessionRevision(), revision);
  await assert.rejects(auth.setCookie('SUB=account-a', revision), /账号|会话/);
  assert.equal(auth.hasCookie(), false);
});

function serviceHarness() {
  let revision = 1; let cookie = 'SUB=account-a'; let response = { ok: 1, data: {} };
  const calls = [];
  const auth = {
    getCookie: () => cookie, hasCookie: () => cookie.includes('SUB='), getSessionRevision: () => revision,
    assertSession(r) { if (r !== revision) throw new Error('账号会话已变更'); },
    setCurrentUserId: () => Promise.resolve(), getCurrentUserId: () => ''
  };
  const http = {};
  for (const method of ['get', 'getDesktop', 'postForm']) {
    http[method] = async (url, c, form) => {
      calls.push({ method, url, cookie: c, fields: form?.fields });
      if (response instanceof Error) throw response;
      return typeof response === 'function' ? response(url) : JSON.stringify(response);
    };
  }
  class Form { constructor(fields) { this.fields = fields; } }
  const load = createLoader({
    '@kit.RemoteCommunicationKit': { rcp: { Form, MultipartForm: Form } },
    '@kit.ArkTS': { util: { TextDecoder: class { decodeWithStream(b) { return new TextDecoder().decode(b); } } } },
    '../network/WeiboHttpClient': { WeiboHttpClient: http },
    './WeiboAuthManager': { WeiboAuthManager: { getInstance: () => auth } },
    './WeiboVisitorSession': { WeiboVisitorSession: { getInstance: () => ({ getCookie: () => '' }) } },
    './WeiboMedia': { prepareWeiboImage: async () => ({ data: new ArrayBuffer(8), mimeType: 'image/gif', fileName: 'weibo.gif' }) }
  });
  return { service: load('service/WeiboService').WeiboService.getInstance(), calls,
    respond(value) { response = value; }, switchAccount() { revision++; cookie = 'SUB=account-b'; } };
}
const postFixture = { id: 123, idstr: '90071992547409931', text: '正文[微笑]', user: { idstr: '42', screen_name: '测试' } };

test('post mapping carries actual author follow state, not timeline membership', () => {
  const { service } = serviceHarness();
  for (const following of [true, false]) {
    const post = service.toPost({ ...postFixture, user: { ...postFixture.user, following },
      retweeted_status: { ...postFixture, user: { ...postFixture.user, following: !following } } });
    assert.equal(post.isFollowed, following);
    assert.equal(post.repost.isFollowed, !following);
    const liked = createLoader()('common/WeiboPostState').withWeiboLike(post, true);
    assert.equal(liked.isFollowed, following);
  }
});

test('desktop comment attachments preserve server ordering and full-size URLs', () => {
  const { service } = serviceHarness();
  const comment = service.toComment({ idstr: 'photo-comment', text: '[图片]', url_struct: [{
    pic_ids: ['second', 'missing', 'first'], pic_infos: {
      first: { large: { url: 'https://wx1.sinaimg.cn/large/first.jpg' } },
      second: { woriginal: { url: '//wx1.sinaimg.cn/large/second.jpg' }, thumbnail: { url: 'thumb' } }
    }
  }] });
  assert.deepEqual(Array.from(comment.pictures), [
    'https://wx1.sinaimg.cn/large/second.jpg', 'https://wx1.sinaimg.cn/large/first.jpg'
  ]);
});

test('comment photos merge mobile and desktop metadata without duplicates', () => {
  const { service } = serviceHarness();
  const url = 'https://wx1.sinaimg.cn/large/photo.jpg';
  const comment = service.toComment({ pics: [], pic: { large: { url } }, url_struct: [
    { pic_infos: { one: { woriginal: { url } } } }, {},
    { pic_ids: [], pic_infos: { two: { woriginal: { url: '' }, bmiddle: { url: 'https://wx1.sinaimg.cn/bmiddle/other.jpg' } } } }
  ], comments: [{ idstr: 'reply', url_struct: [{ pic_infos: { one: { original: { url } } } }] }] });
  assert.deepEqual(Array.from(comment.pictures), [url, 'https://wx1.sinaimg.cn/bmiddle/other.jpg']);
  assert.deepEqual(Array.from(comment.replies[0].pictures), [url]);
  assert.equal(service.toComment({ text: 'plain comment', url_struct: [{}] }).pictures.length, 0);
});

test('comment pictures upgrade http to https and extract from diverse comment formats', () => {
  const { service } = serviceHarness();
  
  // 1. http is upgraded to https
  const httpComment = service.toComment({
    text: 'test',
    pic: 'http://wx1.sinaimg.cn/large/photo.jpg'
  });
  assert.deepEqual(Array.from(httpComment.pictures), ['https://wx1.sinaimg.cn/large/photo.jpg']);

  // 2. url_struct with url_title: '评论配图'
  const titleComment = service.toComment({
    text: 'test 评论配图',
    url_struct: [{ url_title: '评论配图', long_url: 'http://wx2.sinaimg.cn/large/photo2.jpg' }]
  });
  assert.deepEqual(Array.from(titleComment.pictures), ['https://wx2.sinaimg.cn/large/photo2.jpg']);
  assert.equal(titleComment.text, 'test');

  // 3. HTML text with <a href="...">评论配图</a> strips anchor and extracts picture if empty
  const htmlComment = service.toComment({
    text: 'V680也豪华感十足 <a href="http://wx3.sinaimg.cn/large/car.jpg">评论配图</a>'
  });
  assert.equal(htmlComment.text, 'V680也豪华感十足');
  assert.deepEqual(Array.from(htmlComment.pictures), ['https://wx3.sinaimg.cn/large/car.jpg']);
});
test('publish uses documented update endpoint and comma-separated uploaded picId', async () => {
  const h = serviceHarness(); await h.service.publishPost(' hello ', ['p1', 'p2']);
  assert.equal(h.calls[0].url, 'https://m.weibo.cn/api/statuses/update');
  assert.equal(h.calls[0].fields.content, 'hello'); assert.equal(h.calls[0].fields.picId, 'p1,p2');
});
test('ambiguous follow/unfollow failure is not replayed against other endpoints', async () => {
  for (const method of ['followUser', 'unfollowUser']) {
    const h = serviceHarness(); h.respond(new Error('timeout'));
    await assert.rejects(h.service[method]('42'), /timeout/); assert.equal(h.calls.length, 1);
  }
});
test('favorite/like history retains string IDs and user-specific state', async () => {
  const h = serviceHarness();
  h.respond({ ok: 1, data: { list: [{ mblog: postFixture }] } });
  const fav = await h.service.fetchFavorites(2); assert.equal(fav[0].id, postFixture.idstr); assert.equal(fav[0].isFavorited, true);
  h.respond({ ok: 1, data: { statuses: [postFixture] } });
  const likes = await h.service.fetchLikes('42', 3); assert.equal(likes[0].isLiked, true);
  assert.match(h.calls.at(-1).url, /\/likelist\?uid=42&page=3/);
});
test('history/messages failures propagate instead of masquerading as empty lists', async () => {
  const h = serviceHarness(); h.respond({ ok: 0, msg: '登录已过期' });
  for (const fn of [() => h.service.fetchFavorites(1), () => h.service.fetchLikes('42', 1), () => h.service.fetchNotifications('like')]) {
    await assert.rejects(fn(), /登录已过期/);
  }
});
test('notifications accept array/list envelopes and never navigate using reply-comment IDs', async () => {
  const h = serviceHarness();
  const item = { idstr: '90071992547409933', user: { idstr: '42', screen_name: '测试' }, text: '你好',
    status: postFixture, reply_comment: { idstr: 'WRONG-COMMENT' } };
  for (const data of [[item], { list: [item] }, { data: [item] }, { messages: [item] }]) {
    h.respond({ ok: 1, data }); const result = await h.service.fetchNotifications('comment', 2);
    assert.equal(result[0].targetPostId, postFixture.idstr); assert.equal(result[0].id, 'comment_90071992547409933');
  }
});
test('reply picture and comment-like forms send correct target fields', async () => {
  const h = serviceHarness(); await h.service.publishComment('post', '', 'comment', 'pic');
  const call = h.calls.at(-1); assert.match(call.url, /comments\/reply$/);
  assert.equal(call.fields.id, 'post'); assert.equal(call.fields.mid, 'post'); assert.equal(call.fields.cid, 'comment');
  assert.equal(call.fields.reply, 'comment'); assert.equal(call.fields.picId, 'pic'); assert.equal(call.fields.content, '[图片]');
  await h.service.setCommentLike('comment', true); assert.match(h.calls.at(-1).url, /likes\/update$/);
  assert.equal(h.calls.at(-1).fields.type, 'comment');
});
test('image upload rejects successful HTTP responses without a pic_id', async () => {
  const h = serviceHarness(); await assert.rejects(h.service.uploadPicture('file://test'), /图片上传失败/);
  h.respond({ ok: 1, data: { pic_id: 'pic' } }); assert.equal(await h.service.uploadPicture('file://test'), 'pic');
});
test('remembered post and comment caches do not survive session changes', async () => {
  const h = serviceHarness(); h.service.rememberPost({ id: 'p', isLiked: true });
  h.respond({ ok: 1, data: [], max_id: 0 }); await h.service.fetchComments('p', 1);
  h.switchAccount(); assert.equal(h.service.getRememberedPost('p'), null);
  await h.service.fetchComments('p', 1); assert.equal(h.calls.length, 2);
});
test('WeiboService remembers multiple recent posts in LRU cache and caches current user profile', async () => {
  const h = serviceHarness();
  h.service.rememberPost({ id: 'p1', text: 'first' });
  h.service.rememberPost({ id: 'p2', text: 'second' });
  h.service.rememberPost({ id: 'p3', text: 'third' });

  // All recent posts are retrievable, not just the latest one
  assert.equal(h.service.getRememberedPost('p1')?.text, 'first');
  assert.equal(h.service.getRememberedPost('p2')?.text, 'second');
  assert.equal(h.service.getRememberedPost('p3')?.text, 'third');
  assert.equal(h.service.getRememberedPost('unknown'), null);

  // Current user cache
  assert.equal(h.service.getCachedCurrentUser(), null);
  const responses = [
    { ok: 1, data: { login: true, uid: '123' } },
    { ok: 1, data: { userInfo: { id: '123', screen_name: 'testuser', profile_image_url: 'avatar' } } }
  ];
  h.respond(() => JSON.stringify(responses.shift() || { ok: 1, data: {} }));
  const user = await h.service.fetchCurrentUserProfile();
  assert.equal(user.screenName, 'testuser');
  assert.equal(h.service.getCachedCurrentUser()?.screenName, 'testuser');

  // Account switch clears user cache and post cache
  h.switchAccount();
  assert.equal(h.service.getCachedCurrentUser(), null);
  assert.equal(h.service.getRememberedPost('p1'), null);
});
test('old in-flight post cannot populate a new session cache', async () => {
  const h = serviceHarness(); let finish;
  h.respond(() => new Promise(resolve => { finish = resolve; }));
  const task = h.service.fetchPost('p'); h.switchAccount(); finish(JSON.stringify({ ok: 1, data: { ...postFixture, idstr: 'p' } }));
  await assert.rejects(task, /账号会话/); assert.equal(h.service.getRememberedPost('p'), null);
});

function mediaHarness({ chunkSize = 3, eof = false, size = 30 } = {}) {
  const data = Uint8Array.from({ length: size }, (_, i) => i + 1);
  data.set(Buffer.from('GIF89a').subarray(0, size));
  let position = 0; let closed = 0;
  const io = { OpenMode: { READ_ONLY: 0 }, WhenceType: { SEEK_SET: 0 },
    open: async () => ({ fd: 1 }), stat: async () => ({ size }), close: async () => { closed++; },
    lseek(_fd, p) { position = p; },
    async read(_fd, out, { length }) {
      if (eof && position >= 9) return 0;
      const count = Math.min(length, chunkSize, data.length - position);
      new Uint8Array(out).set(data.subarray(position, position + count)); position += count; return count;
    }
  };
  const load = createLoader({ '@kit.CoreFileKit': { fileIo: io }, '@kit.ImageKit': { image: {
    createImageSource() { throw new Error('GIF must not be decoded/repacked as JPEG'); }
  } } });
  return { prepare: load('service/WeiboMedia').prepareWeiboImage, data, closed: () => closed };
}
test('GIF stays byte-identical with file-pointer semantics and short reads including header', async () => {
  for (const chunkSize of [1, 2, 3, 7, 100]) {
    const h = mediaHarness({ chunkSize }); const result = await h.prepare('picker://gif');
    assert.equal(result.mimeType, 'image/gif'); assert.deepEqual(new Uint8Array(result.data), h.data); assert.equal(h.closed(), 1);
  }
});
test('GIF unexpected EOF fails instead of sending partially filled buffer', async () => {
  const h = mediaHarness({ eof: true }); await assert.rejects(h.prepare('picker://gif'), /读取不完整/); assert.equal(h.closed(), 1);
});
test('LivePhoto tracks pair all still sizes and reject ordinary videos/unsafe schemes', () => {
  const fn = createLoader()('common/WeiboMediaMetadata').weiboLivePhotoTracks;
  const tracks = fn([
    { type: 'livephoto', videoSrc: '//video.example/a.mp4', large: { url: 'https://img/a.jpg' }, original: { url: 'https://img/original.jpg' } },
    { type: 'video', video: 'https://video.example/ordinary.mp4', url: 'ordinary' },
    { type: 'livephoto', videoSrc: 'javascript:bad', url: 'unsafe' }
  ], { p: { video: 'https://video.example/b.mp4', largest: { url: 'desktop' } } });
  assert.equal(tracks['https://img/a.jpg'], 'https://video.example/a.mp4');
  assert.equal(tracks['https://img/original.jpg'], 'https://video.example/a.mp4');
  assert.equal(tracks.desktop, 'https://video.example/b.mp4'); assert.equal(tracks.ordinary, undefined); assert.equal(tracks.unsafe, undefined);
});
test('mention lookup selects exact screen_name not the first fuzzy search result', async () => {
  const h = serviceHarness(); h.respond({ ok: 1, data: { cards: [{ card_group: [
    { user: { id: 'wrong', screen_name: '测试博主粉丝' } }, { user: { idstr: 'right', screen_name: '测试博主' } }
  ] }] } });
  assert.equal(await h.service.resolveUserIdByName('测试博主'), 'right');
});
function imageCacheHarness() {
  const files = new Map([['/cache/img_cache/ok', 200], ['/cache/img_cache/fail', 500]]); const writes = [];
  const io = { OpenMode: { READ_WRITE: 1, CREATE: 2, TRUNC: 4, APPEND: 8 },
    listFileSync: () => [...files.keys()].map(x => x.split('/').at(-1)),
    statSync(p) { if (!files.has(p)) throw new Error('missing'); return { size: files.get(p) }; },
    unlinkSync(p) { if (p.endsWith('/fail')) throw new Error('permission denied'); files.delete(p); },
    openSync: p => ({ fd: p }), writeSync(fd, data) { writes.push(fd); files.set(fd, data.byteLength || data.length); }, closeSync() {}, mkdirSync() {}
  };
  const load = createLoader({ '@kit.CoreFileKit': { fileIo: io }, '@kit.PerformanceAnalysisKit': { hilog: quiet },
    '../network/HttpClient': { HttpClient: {} }, '@kit.ImageKit': { image: {} }
  }, { getContext: () => ({ cacheDir: '/cache' }) });
  return { cache: load('cache/ImageCache').ImageCache, files, writes };
}
test('cache cleanup counts only successful unlink and exposes partial failure', () => {
  const h = imageCacheHarness(); const result = h.cache.clearAllCache();
  assert.equal(result.deletedBytes, 200); assert.equal(result.deletedFiles, 1); assert.equal(result.failedFiles, 1);
  assert.equal(h.files.get('/cache/img_cache/fail'), 500);
});
test('download completing after cache cleanup cannot recreate disk/memory cache', async () => {
  const h = imageCacheHarness(); let finish; h.cache.debugLog = () => {};
  h.cache.downloadBuf = () => new Promise(resolve => { finish = resolve; }); h.cache.isPlaceholderImage = async () => false;
  const task = h.cache.downloadAndCache('https://img.example/a.jpg', 0);
  h.cache.clearAllCache(); finish(new ArrayBuffer(10000)); await task;
  assert.equal(h.writes.length, 0); assert.equal(h.cache.memCache.size, 0);
});

function textHarness() {
  const fs = require('node:fs');
  const load = createLoader({ '@kit.ArkTS': { util: { TextDecoder: class { decodeWithStream(b) { return new TextDecoder().decode(b); } } } } });
  const text = load('common/WeiboText');
  text.loadWeiboEmojiAssets({ resourceManager: { getRawFileContentSync: () =>
    new Uint8Array(fs.readFileSync(require('node:path').resolve(__dirname, '../entry/src/main/resources/rawfile/weibo-emoji.json'))) } });
  return { ...text, parse: load('common/WeiboRichTokens').parseWeiboText };
}
test('bundled emoji catalog loads real classics and unknown phrases remain readable text', () => {
  const h = textHarness(); assert.ok(h.getWeiboEmojiNames().length > 100);
  assert.match(h.getWeiboEmoji('微笑'), /^https?:\/\/.*(?:sinaimg|sinajs)\.cn\//);
  const tokens = h.parse('#话题# @用户 [微笑] [不存在的表情]');
  assert.deepEqual(Array.from(tokens, x => x.type), ['topic', 'text', 'mention', 'text', 'emoji', 'text', 'text']);
});
test('HTML normalization preserves emoji, topics, mentions and real link destinations without accepting hostile emoji hosts', () => {
  const h = textHarness();
  const normalized = h.normalizeWeiboText('<a href="https://m.weibo.cn/n/用户">@用户</a> <a href="https://m.weibo.cn/search?q=x">#话题#</a> <a href="https://example.com/path?a=1&amp;b=2">阅读文章</a> <img alt="[微笑]" src="https://face.t.sinajs.cn/t4/appstyle/expression/ext/normal/00/test.png">');
  const tokens = h.parse(normalized); assert.ok(tokens.some(x => x.type === 'topic')); assert.ok(tokens.some(x => x.type === 'mention'));
  assert.ok(tokens.some(x => x.type === 'link' && x.value === 'https://example.com/path?a=1&b=2'));
  h.normalizeWeiboText('<img alt="[恶意表情]" src="https://evil.example/path.sinaimg.cn/p.png">');
  assert.equal(h.getWeiboEmoji('恶意表情'), undefined);
});
test('URL tokens exclude sentence punctuation and preserve surrounding text', () => {
  const h = textHarness(); const input = '看 https://t.cn/Abc。 下一条 https://example.com/test, ok';
  const tokens = h.parse(input); const links = tokens.filter(x => x.type === 'link');
  assert.equal(links[0].value, 'https://t.cn/Abc'); assert.equal(links[1].value, 'https://example.com/test');
  assert.equal(tokens.map(x => x.text).join(''), input);
});
function httpHarness() {
  let revision = 1; let fetchImpl; const calls = [];
  const cookie = 'SUB=account-a';
  const auth = { getCookie: () => cookie, getSessionRevision: () => revision,
    assertSession(r) { if (r !== revision) throw new Error('账号会话已变更'); } };
  class Form { constructor(fields) { this.fields = fields; } }
  class MultipartForm extends Form {}
  class Request { constructor(url, method) { this.url = url; this.method = method; } }
  const load = createLoader({ '@kit.RemoteCommunicationKit': { rcp: { Form, MultipartForm, Request,
    createSession: () => ({ fetch: async req => { calls.push(req); return fetchImpl(req); } }) } },
    '../service/WeiboAuthManager': { WeiboAuthManager: { getInstance: () => auth } }
  });
  const client = load('network/WeiboHttpClient').WeiboHttpClient; client.waitForRequestSlot = async () => {};
  return { client, calls, cookie, Form, MultipartForm,
    fetch(fn) { fetchImpl = fn; }, changeSession() { revision++; } };
}
const httpResponse = body => ({ statusCode: 200, toString: async () => JSON.stringify(body) });
test('mobile multipart mutation has ST form+header and extended upload timeout', async () => {
  const h = httpHarness(); h.fetch(req => httpResponse(req.method === 'GET' ? { data: { login: true, st: 'csrf' } } : { ok: 1 }));
  const form = new h.MultipartForm({ type: 'json', pic: 'image' }); form.keys = ['type', 'pic'];
  await h.client.postForm('https://m.weibo.cn/api/statuses/uploadPic', h.cookie, form);
  const post = h.calls.at(-1); assert.equal(form.fields.st, 'csrf'); assert.ok(form.keys.includes('st'));
  assert.equal(post.headers['X-XSRF-TOKEN'], 'csrf'); assert.equal(post.configuration.transfer.timeout.transferMs, 120000);
});
test('session change during config prevents sending mutation', async () => {
  const h = httpHarness(); h.fetch(() => ({ statusCode: 200, toString: async () => { h.changeSession(); return JSON.stringify({ data: { st: 'csrf' } }); } }));
  await assert.rejects(h.client.postForm('https://m.weibo.cn/api/statuses/update', h.cookie, new h.Form({ content: 'test' })), /账号会话/);
  assert.equal(h.calls.filter(x => x.method === 'POST').length, 0);
});
test('session change during response body decoding rejects stale reads', async () => {
  const h = httpHarness(); h.fetch(() => ({ statusCode: 200, toString: async () => { h.changeSession(); return '{}'; } }));
  await assert.rejects(h.client.get('https://m.weibo.cn/api/config', h.cookie), /账号会话/);
});
test('failed Web cleanup cannot be bypassed by another login capture', async () => {
  const { auth } = authHarness({ webError: true }); await auth.init({}); await auth.setCookie('SUB=old');
  await assert.rejects(auth.clearCookie()); await assert.rejects(auth.setCookie('SUB=old'), /账号会话/);
});
test('auth rejects empty SUB and suffix matches like NOTSUB', async () => {
  const { auth } = authHarness(); await auth.init({});
  for (const c of ['SUB=', 'NOTSUB=fake']) await assert.rejects(auth.setCookie(c), /有效微博/);
});

test('image save completes partial writes without duplicating or truncating bytes', async () => {
  const saved = []; const load = createLoader({ '@kit.CoreFileKit': { fileIo: { write: async (_fd, bytes) => {
    const part = new Uint8Array(bytes).slice(0, 2); saved.push(...part); return part.length;
  } } } });
  const input = Uint8Array.from([71, 73, 70, 56, 57, 97, 10, 20, 30]);
  await load('common/WeiboImageWrite').writeWeiboImage(4, input.buffer); assert.deepEqual(saved, Array.from(input));
});
test('image save detects a zero-byte write rather than reporting success', async () => {
  const load = createLoader({ '@kit.CoreFileKit': { fileIo: { write: async () => 0 } } });
  await assert.rejects(load('common/WeiboImageWrite').writeWeiboImage(4, new ArrayBuffer(3)), /保存不完整/);
});
test('mobile portrait media dimensions override landscape poster dimensions', () => {
  const { service } = serviceHarness(); const post = service.toPost({ idstr: 'long-id', user: {}, page_info: {
    page_pic: { url: 'https://example.com/p.jpg', width: 1920, height: 1080 },
    media_info: { stream_url_h5: 'https://example.com/v.mp4', video_width: 1080, video_height: 1920,
      big_pic_info: { pic_big: { width: 1920, height: 1080 } } }
  } });
  assert.equal(post.videoAspectRatio, 1080 / 1920); assert.equal(post.videoUrl, 'https://example.com/v.mp4');
});
test('mobile page picture dimensions provide fallback video aspect ratio', () => {
  const { service } = serviceHarness(); const post = service.toPost({ idstr: 'id', user: {}, page_info: {
    page_pic: { url: 'https://example.com/p.jpg', width: '720', height: '1280' }, media_info: { stream_url: 'https://example.com/v.mp4' }
  } }); assert.equal(post.videoAspectRatio, 720 / 1280);
});
test('immutable like update retains LivePhoto, aspect ratio, favorite and repost fields', () => {
  const load = createLoader({}); const update = load('common/WeiboPostState').withWeiboLike;
  const original = { id: 'id', pictures: ['still'], pictureVideos: { still: 'track' }, videoAspectRatio: 9 / 16,
    isFavorited: true, isLiked: false, likeCount: 0, repost: { id: 'original' } };
  const liked = update(original, true); assert.equal(liked.likeCount, 1); assert.equal(original.isLiked, false);
  assert.equal(liked.pictureVideos, original.pictureVideos); assert.equal(liked.videoAspectRatio, 9 / 16);
  assert.equal(liked.isFavorited, true); assert.equal(liked.repost, original.repost);
});

test('recommendation/following use one bounded native scroll owner', () => {
  const fs = require('node:fs'); const src = fs.readFileSync(require('node:path').resolve(__dirname, '../entry/src/main/ets/pages/WeiboHomeTab.ets'), 'utf8');
  assert.match(src, /(?:WaterFlow|List)\(\{\s*scroller:\s*this\.pageScroller/);
  const start = src.indexOf('  TimelineScroller()'); const end = src.indexOf('  RefreshableTimeline()', start);
  const builder = src.slice(start, end);
  assert.doesNotMatch(builder, /Scroll\(this\.pageScroller\)[\s\S]*this\.WaterfallTimeline\(\)/,
    'Scroll container must not be nested inside another vertical Scroll');
});

test('floating chrome reserves scroll content offsets without clipping the WaterFlow viewport', () => {
  const fs = require('node:fs');
  const src = fs.readFileSync(require('node:path').resolve(__dirname, '../entry/src/main/ets/pages/WeiboHomeTab.ets'), 'utf8');
  const start = src.indexOf('  WaterfallTimeline(): void');
  const end = src.indexOf('  Timeline()', start);
  assert.ok(start >= 0 && end > start, 'native WaterFlow builder must be found');
  const builder = src.slice(start, end);
  assert.match(builder, /\.contentStartOffset\(this\.topInset\)/);
  assert.match(builder, /\.contentEndOffset\(this\.bottomInset\)/);
  assert.doesNotMatch(builder, /\.padding\([^\n]*(?:top:\s*this\.topInset|bottom:\s*this\.bottomInset)/,
    'chrome spacing must scroll with content rather than clip a permanent blank viewport band');
  assert.match(builder, /\.padding\(\{ left: 0, right: 0 \}\)/);
});

test('home media and card actions do not block ancestor scrolling hit tests', () => {
  const fs = require('node:fs');
  const src = fs.readFileSync(require('node:path').resolve(__dirname, '../entry/src/main/ets/pages/WeiboHomeTab.ets'), 'utf8');
  const start = src.indexOf('  SocialMedia(post: WeiboPost)');
  const end = src.indexOf('  LoadMoreButton()', start);
  assert.ok(start >= 0 && end > start, 'home card builders must be found');
  const cards = src.slice(start, end);
  assert.doesNotMatch(cards, /HitTestMode\.Block/,
    'Block excludes the WaterFlow ancestor from hit testing when a drag starts on a card action');
  assert.ok((cards.match(/hitTestBehavior\(HitTestMode\.Default\)/g) || []).length >= 5);
  assert.match(cards, /url: 'pages\/ImagePreview'/, 'tap-to-preview must remain');
  assert.match(cards, /pictureVideos: media\.pictureVideos/, 'live-photo preview tracks must remain');
  assert.match(cards, /this\.openUserProfile\(post\.userId, post\.userName\)/);
  assert.match(cards, /this\.toggleLike\(post, !post\.isLiked\)/);
  assert.match(cards, /this\.openOriginalPost\(post\)/);
  assert.match(cards, /\.onClick\(\(\): void => \{ this\.openPost\(post\); \}, WEIBO_TAP_MAX_MOVEMENT\)/);
});

function homeRefreshHarness() {
  const fs = require('node:fs'); const vm = require('node:vm');
  const src = fs.readFileSync(require('node:path').resolve(__dirname, '../entry/src/main/ets/pages/WeiboHomeTab.ets'), 'utf8');
  const start = src.indexOf('  private async refreshFeed('); const end = src.indexOf('  private playExitAnimation(', start);
  const method = src.slice(start, end).replace('private async refreshFeed(): Promise<void>', 'async refreshFeed()');
  const Controller = vm.runInNewContext('(class { ' + method + ' })');
  const instance = new Controller(); instance.refreshing = true; instance.refreshInFlight = false;
  instance.posts = []; instance.scheduleSavePosition = () => {};
  instance.pageScroller = { scrollTo() {}, scrollToIndex() {}, scrollEdge() {} }; return instance;
}
test('pull refresh starts even when native two-way binding has already set refreshing=true', async () => {
  const instance = homeRefreshHarness(); let calls = 0;
  instance.loadFirstPage = async preserve => { assert.equal(preserve, true); calls++; };
  await instance.refreshFeed(); assert.equal(calls, 1); assert.equal(instance.refreshing, false);
});
test('concurrent refresh is guarded by request lifecycle and clears after failure', async () => {
  const instance = homeRefreshHarness(); let release; let calls = 0;
  instance.loadFirstPage = () => { calls++; return new Promise((_, reject) => { release = () => reject(new Error('offline')); }); };
  const first = instance.refreshFeed(); const duplicate = instance.refreshFeed();
  assert.equal(calls, 1); await duplicate; release(); await assert.rejects(first, /offline/);
  assert.equal(instance.refreshing, false); assert.equal(instance.refreshInFlight, false);
});

test('comments default to server heat order and preserve desktop comment fields', async () => {
  const h = serviceHarness(); h.respond({ ok: 1, data: [{ idstr: 'c1', text: '热评', like_counts: 30, liked: 1, total_number: 2 }], max_id: 'cursor-heat' });
  const result = await h.service.fetchComments('p', 1);
  const url = new URL(h.calls[0].url); assert.equal(url.pathname, '/ajax/statuses/buildComments');
  assert.equal(url.searchParams.get('flow'), '0'); assert.equal(result.items[0].likeCount, 30);
  assert.equal(result.items[0].isLiked, true); assert.equal(result.nextMaxId, 'cursor-heat'); assert.equal(result.hasMore, true);
});
test('heat and real-time comment first pages never share caches or in-flight requests', async () => {
  const h = serviceHarness(); h.respond(url => JSON.stringify({ ok: 1, data: [{ idstr: new URL(url).searchParams.get('flow') === '1' ? 'latest' : 'heat' }], max_id: 'next' }));
  const [heat, latest] = await Promise.all([h.service.fetchComments('p', 1, 0), h.service.fetchComments('p', 1, 1)]);
  assert.equal(heat.items[0].id, 'heat'); assert.equal(latest.items[0].id, 'latest'); assert.equal(h.calls.length, 2);
  await h.service.fetchComments('p', 1, 1); assert.equal(h.calls.length, 2);
});
test('comment pagination retains selected server order and exact large cursor', async () => {
  const h = serviceHarness(); h.respond(() => '{"ok":1,"data":[{"id":90071992547409933,"text":"评论"}],"max_id":90071992547409935}');
  const first = await h.service.fetchComments('p', 1, 1);
  assert.equal(first.items[0].id, '90071992547409933'); assert.equal(first.nextMaxId, '90071992547409935');
  h.respond({ ok: 1, data: [], max_id: 0 }); const next = await h.service.fetchComments('p', 2, 1, first.nextMaxId);
  const url = new URL(h.calls.at(-1).url); assert.equal(url.searchParams.get('flow'), '1'); assert.equal(url.searchParams.get('max_id'), first.nextMaxId); assert.equal(next.hasMore, false);
});
test('invalidating comments disassociates pending prefetch so it cannot resurrect stale cache', async () => {
  const h = serviceHarness(); let complete;
  h.respond(() => new Promise(resolve => { complete = resolve; })); const old = h.service.fetchComments('p', 1, 0);
  h.service.invalidateComments('p'); h.respond({ ok: 1, data: [{ idstr: 'fresh' }], max_id: 0 });
  const fresh = await Promise.race([h.service.fetchComments('p', 1, 0),
    new Promise((_, reject) => setTimeout(() => reject(new Error('invalidated pending request was reused')), 200))]);
  assert.equal(fresh.items[0].id, 'fresh');
  complete(JSON.stringify({ ok: 1, data: [{ idstr: 'stale' }], max_id: 0 })); await old;
  const cached = await h.service.fetchComments('p', 1, 0); assert.equal(cached.items[0].id, 'fresh'); assert.equal(h.calls.length, 2);
});

function detailHarness(fetchComments, extraMethods = []) {
  const { createMethodHarness } = require('./ets-loader.cjs');
  const auth = { getSessionRevision: () => 1, isSessionChanging: () => false };
  const service = { fetchComments };
  const instance = createMethodHarness('pages/WeiboPostDetail.ets', [
    'isCurrentSession', 'isCurrentCommentRequest', 'isCurrentReplyRequest', 'reconcileCommentLike', 'applyConcurrentCommentLikes',
    'loadComments', 'loadMoreComments', 'switchCommentSort', ...extraMethods
  ], { WeiboAuthManager: { getInstance: () => auth }, WeiboService: { getInstance: () => service },
    hilog: { info() {} },
    WeiboCommentSort: { Hot: 0, Latest: 1 }, Haptic: { light() {} }, $r: id => id,
    Curve: { EaseOut: 0 }, ScrollState: { Scroll: 1, Fling: 2 } });
  Object.assign(instance, { postId: 'p', comments: [], commentsSort: 0, commentsEpoch: 0, commentsPage: 1,
    commentsNextMaxId: '0', commentsError: '', commentsNoProgressPages: 0, commentsLoading: false, loadingMoreComments: false, hasMoreComments: true,
    replyLoadingIds: [], expandedReplyIds: [], replyCursors: new Map(), replyEpochs: new Map(), commentLikingIds: [],
    commentLikeMutations: new Map(), commentLikeVersion: 0,
    getUIContext: () => ({ getPromptAction: () => ({ showToast() {} }), animateTo: (_, action) => action() }) });
  return { instance, service, auth };
}
test('detail sort switching discards a late heat first page without clearing latest loading state', async () => {
  const calls = []; const h = detailHarness((post, page, sort, cursor) => new Promise(resolve => calls.push({ post, page, sort, cursor, resolve })));
  const first = h.instance.loadComments(); h.instance.switchCommentSort(1);
  assert.equal(calls.length, 2); assert.equal(calls[1].sort, 1); assert.equal(h.instance.comments.length, 0);
  calls[0].resolve({ items: [{ id: 'old-heat' }], nextMaxId: 'old', hasMore: true }); await first;
  assert.equal(h.instance.commentsLoading, true); assert.equal(h.instance.comments.length, 0);
  calls[1].resolve({ items: [{ id: 'latest' }], nextMaxId: 'new', hasMore: true }); await new Promise(setImmediate);
  assert.equal(h.instance.comments[0].id, 'latest'); assert.equal(h.instance.commentsNextMaxId, 'new');
  assert.equal(h.instance.commentsPage, 1); assert.equal(h.instance.commentsLoading, false);
});
test('late pagination from another order cannot append or mutate the new cursor', async () => {
  const calls = []; const h = detailHarness((post, page, sort, cursor) => new Promise(resolve => calls.push({ page, sort, cursor, resolve })));
  h.instance.comments = [{ id: 'heat1' }]; h.instance.commentsNextMaxId = 'heat-next';
  const paging = h.instance.loadMoreComments(); h.instance.switchCommentSort(1);
  assert.equal(calls[0].cursor, 'heat-next'); assert.equal(calls[0].sort, 0);
  calls[0].resolve({ items: [{ id: 'heat2' }], nextMaxId: 'heat-next2', hasMore: true }); await paging;
  assert.equal(h.instance.comments.length, 0); assert.equal(h.instance.commentsLoading, true);
  calls[1].resolve({ items: [{ id: 'latest' }], nextMaxId: 'latest-next', hasMore: true }); await new Promise(setImmediate);
  assert.equal(h.instance.comments.length, 1); assert.equal(h.instance.commentsPage, 1); assert.equal(h.instance.commentsNextMaxId, 'latest-next');
});

function composerScrollState() { return new (createLoader()('common/CommentComposerScrollState').CommentComposerScrollState)(); }
test('comment composer ignores jitter, hides on reading forward, and reveals on reverse drag', () => {
  const state = composerScrollState(); assert.equal(state.update(5, true, false), false);
  assert.equal(state.update(-4, true, false), false); assert.equal(state.update(8, true, false), false);
  assert.equal(state.update(16, true, false), true); assert.equal(state.update(-5, true, false), true);
  assert.equal(state.update(-7, true, false), false);
});
test('composer stays visible before comments and while editing/picking/sending', () => {
  const state = composerScrollState(); assert.equal(state.update(100, false, false), false);
  assert.equal(state.update(24, true, false), true); assert.equal(state.update(100, true, true), false);
  assert.equal(state.update(20, true, false), false); assert.equal(state.update(4, true, false), true);
  state.reset(); assert.equal(state.update(0, true, false), false);
});

function editorHarness(fetchComments = async () => ({ items: [], nextMaxId: '0', hasMore: false })) {
  const h = detailHarness(fetchComments, ['setComposerVisible', 'beginCommentReply', 'openCommentEditor', 'closeCommentEditor', 'sendComment', 'insertCommentToken', 'cancelCommentReply']);
  Object.assign(h.auth, { getCookie: () => 'SUB=test-account', assertSession() {} });
  Object.assign(h.instance, { commentComposerHidden: true, commentEditorOpen: false, composerScrollState: composerScrollState(),
    commentDraft: '', commentImage: '', commentSending: false, pickingCommentImage: false, showCommentEmoji: false,
    commentPictureId: '', commentPictureCookie: '', commentUploadHint: '', replyTargetComment: null,
    commentSelectionStart: 0, commentSelectionEnd: 0, commentEditorController: { caretPosition() {}, stopEditing() {} }, focusCommentEditor() {} });
  return h;
}
test('replying opens the expanded editor with the real target and restores hidden composer', () => {
  const h = editorHarness(); h.instance.commentDraft = '保留草稿';
  h.instance.beginCommentReply({ id: 'target-comment', userName: 'cccc' });
  assert.equal(h.instance.commentEditorOpen, true); assert.equal(h.instance.commentComposerHidden, false);
  assert.equal(h.instance.replyTargetComment.id, 'target-comment'); assert.equal(h.instance.commentDraft, '保留草稿');
});
test('mention/emoji insertion replaces the selected range rather than losing or appending to the draft', () => {
  const h = editorHarness(); h.instance.commentEditorOpen = true; h.instance.commentDraft = 'abcdef';
  h.instance.commentSelectionStart = 2; h.instance.commentSelectionEnd = 4; h.instance.insertCommentToken('@');
  assert.equal(h.instance.commentDraft, 'ab@ef'); assert.equal(h.instance.commentSelectionStart, 3);
  assert.equal(h.instance.commentSelectionEnd, 3);
});
test('failed picture reply keeps expanded editor, target, text, and uploaded picture for retry', async () => {
  const h = editorHarness(); let uploads = 0;
  h.service.uploadPicture = async () => { uploads++; return 'uploaded-pic'; };
  h.service.publishComment = async () => { throw new Error('发送失败'); };
  Object.assign(h.instance, { commentEditorOpen: true, commentDraft: '回复内容', commentImage: 'file://picture', replyTargetComment: { id: 'reply-cid' } });
  await h.instance.sendComment(); await h.instance.sendComment();
  assert.equal(uploads, 1); assert.equal(h.instance.commentEditorOpen, true); assert.equal(h.instance.commentDraft, '回复内容');
  assert.equal(h.instance.commentImage, 'file://picture'); assert.equal(h.instance.replyTargetComment.id, 'reply-cid');
  assert.equal(h.instance.commentSending, false); assert.equal(h.instance.commentUploadHint, '');
});
test('successful reply closes editor only after real publish and reloads the selected comment order', async () => {
  const reads = []; const h = editorHarness(async (p, page, sort) => { reads.push(sort); return { items: [], nextMaxId: '0', hasMore: false }; });
  let publishArgs; h.service.publishComment = async (...args) => { publishArgs = args; assert.equal(h.instance.commentEditorOpen, true); };
  Object.assign(h.instance, { commentEditorOpen: true, commentDraft: '回复内容', replyTargetComment: { id: 'reply-cid' }, commentsSort: 1, commentsLoading: true });
  await h.instance.sendComment(); assert.deepEqual(publishArgs, ['p', '回复内容', 'reply-cid', '']);
  assert.equal(h.instance.commentEditorOpen, false); assert.equal(h.instance.commentDraft, ''); assert.equal(h.instance.replyTargetComment, null);
  assert.deepEqual(reads, [1]); assert.equal(h.instance.commentSending, false);
});

test('stale child replies cannot restore expansion/cursor or clear a newer same-comment loading flag', async () => {
  const h = detailHarness(async () => ({ items: [], nextMaxId: '0', hasMore: false }), ['loadReplies']);
  const pending = []; h.service.fetchCommentReplies = () => new Promise(resolve => pending.push(resolve));
  const oldComment = { id: 'c', replies: [] }; const old = h.instance.loadReplies(oldComment);
  h.instance.commentsEpoch++; h.instance.replyLoadingIds = [];
  const currentComment = { id: 'c', replies: [] }; const current = h.instance.loadReplies(currentComment);
  pending[0]({ items: [{ id: 'stale-child' }], nextMaxId: 'stale-cursor', hasMore: true }); await old;
  assert.equal(h.instance.replyCursors.size, 0); assert.equal(h.instance.expandedReplyIds.length, 0);
  assert.equal(h.instance.replyLoadingIds.includes('c'), true); assert.equal(oldComment.replies.length, 0);
  pending[1]({ items: [{ id: 'fresh-child' }], nextMaxId: 'fresh-cursor', hasMore: true }); await current;
  assert.equal(currentComment.replies[0].id, 'fresh-child'); assert.equal(h.instance.replyCursors.get('c'), 'fresh-cursor');
});

test('detail scrolling integrates region detection and protects the editor from auto-hiding', () => {
  const h = detailHarness(async () => ({ items: [], nextMaxId: '0', hasMore: false }), ['onDetailScroll', 'setComposerVisible']);
  let offset = 0; Object.assign(h.instance, { detailScroller: { currentOffset: () => ({ yOffset: offset }) },
    detailViewportBottom: 600, commentsSectionTop: 700, composerScrollState: composerScrollState(), commentComposerHidden: false,
    commentEditorOpen: false, commentInputFocused: false, pickingCommentImage: false, commentSending: false, showCommentEmoji: false });
  h.instance.onDetailScroll(100, 1); assert.equal(h.instance.commentComposerHidden, false);
  offset = 200; h.instance.onDetailScroll(24, 1); assert.equal(h.instance.commentComposerHidden, true);
  h.instance.commentEditorOpen = true; h.instance.onDetailScroll(100, 2); assert.equal(h.instance.commentComposerHidden, false);
});

test('more menu can change reply into root comment without discarding text/image', () => {
  const h = editorHarness(); Object.assign(h.instance, { commentEditorOpen: true, commentDraft: '保留文字', commentImage: 'file://p', replyTargetComment: { id: 'c' } });
  h.instance.cancelCommentReply(); assert.equal(h.instance.replyTargetComment, null);
  assert.equal(h.instance.commentDraft, '保留文字'); assert.equal(h.instance.commentImage, 'file://p'); assert.equal(h.instance.commentEditorOpen, true);
});
test('reply target cannot be changed while sending or selecting a picture', () => {
  for (const protectedField of ['commentSending', 'pickingCommentImage']) {
    const h = editorHarness(); h.instance.replyTargetComment = { id: 'c' }; h.instance[protectedField] = true;
    h.instance.cancelCommentReply(); assert.equal(h.instance.replyTargetComment.id, 'c');
  }
});
test('child replies retain exact numeric comment IDs/cursors before JSON number conversion', async () => {
  const h = serviceHarness(); h.respond(() => '{"ok":1,"data":[{"id":90071992547409933,"text":"楼中楼"}],"max_id":90071992547409935}');
  const result = await h.service.fetchCommentReplies('parent');
  assert.equal(result.items[0].id, '90071992547409933'); assert.equal(result.nextMaxId, '90071992547409935');
});

test('native detail source defaults to heat and binds an immersive multiline editor with keyboard avoidance', () => {
  const src = require('node:fs').readFileSync(require('node:path').resolve(__dirname, '../entry/src/main/ets/pages/WeiboPostDetail.ets'), 'utf8');
  assert.match(src, /@State commentsSort: WeiboCommentSort = WeiboCommentSort\.Hot/);
  assert.ok(src.includes('this.commentEditorOpen'));
  assert.ok(src.includes('TextArea({ text: this.commentDraft'));
  assert.ok(src.includes('placeholder: this.replyTargetComment === null'));
  assert.ok(src.includes('keyboardHeight'));
  assert.ok(src.includes("backgroundColor('#66000000')"));
  // 回复入口：点击评论本身进入回复，不再有独立「回复」按钮（用户明确要求）
  assert.ok(!src.includes("Button('回复')"), '评论项不应再有独立回复按钮');
  assert.ok(src.includes('.onClick((): void => { this.beginCommentReply(comment); }, WEIBO_TAP_MAX_MOVEMENT)'),
    '点击评论本身应进入回复');
  assert.ok(src.includes('accessibilityText(`回复 ${comment.userName}`)'),
    '评论项需保留可访问的回复语义');
});

test('immersive top and bottom chrome stay transparent floating shells', () => {
  const fs = require('node:fs'), path = require('node:path');
  const index = fs.readFileSync(path.resolve(__dirname, '../entry/src/main/ets/pages/Index.ets'), 'utf8');
  const style = index.slice(index.indexOf('private titleBarStyle'), index.indexOf('private bindBuiltInTabScrollers'));
  assert.ok(style.includes('scrollEffectStyle'), 'titleBarStyle should still declare a scroll-effect state');
  assert.ok(!style.includes('backgroundColor: Theme.bg('),
    '滚动后的顶栏不得填实色 Theme.bg，否则顶部会盖出一块实心色块');
  assert.equal((style.match(/ohos_id_color_background_transparent/g) || []).length, 2,
    'originalStyle 与 scrollEffectStyle 都要用透明系统色，维持透明悬浮顶栏');
  const home = fs.readFileSync(path.resolve(__dirname, '../entry/src/main/ets/pages/WeiboHomeTab.ets'), 'utf8');
  assert.ok(home.includes('if (this.pageScroller.currentOffset().yOffset <= 0)'),
    '列表在顶部时必须显示悬浮 Dock，否则只剩 bottomInset 预留的空白带');
});

test('duplicate-only comment page with advancing cursor does not claim all comments are loaded', async () => {
  const h = detailHarness(async () => ({ items: [{ id: 'same' }], nextMaxId: 'cursor-3', hasMore: true }));
  h.instance.comments = [{ id: 'same' }]; h.instance.commentsNextMaxId = 'cursor-2';
  await h.instance.loadMoreComments(); assert.equal(h.instance.hasMoreComments, true);
  assert.equal(h.instance.commentsNextMaxId, 'cursor-3'); assert.equal(h.instance.comments.length, 1);
});
test('bounded duplicate-page automatic loading still allows manual continuation and recovery', async () => {
  let requests = 0; const h = detailHarness(async () => { requests++; return { items: [{ id: 'same' }], nextMaxId: `cursor-${requests}`, hasMore: true }; });
  h.instance.comments = [{ id: 'same' }]; h.instance.commentsNextMaxId = 'start';
  for (let i = 0; i < 5; i++) await h.instance.loadMoreComments(true);
  assert.equal(requests, 3); assert.equal(h.instance.hasMoreComments, true);
  await h.instance.loadMoreComments(); assert.equal(requests, 4);
  h.service.fetchComments = async () => { requests++; return { items: [{ id: 'new' }], nextMaxId: `cursor-${requests}`, hasMore: true }; };
  await h.instance.loadMoreComments(); assert.equal(h.instance.comments.length, 2);
  await h.instance.loadMoreComments(true); assert.equal(requests, 6);
});
test('successful in-flight like reconciles current same-ID row after sort switching and invalidates cache', async () => {
  const h = detailHarness(async () => ({ items: [], nextMaxId: '0', hasMore: false }), ['toggleCommentLike']);
  let finish, invalidations = 0; const writes = []; h.service.invalidateComments = id => { assert.equal(id, 'p'); invalidations++; };
  h.service.setCommentLike = (id, liked) => { writes.push({ id, liked }); return new Promise(resolve => { finish = resolve; }); };
  const original = { id: 'c', isLiked: false, likeCount: 5 }; h.instance.comments = [original];
  const action = h.instance.toggleCommentLike(original); h.instance.commentsEpoch++;
  const current = { id: 'c', isLiked: false, likeCount: 20 }; h.instance.comments = [current];
  finish(); await action; assert.equal(current.isLiked, true); assert.equal(current.likeCount, 21); assert.equal(invalidations, 1);
  const unlike = h.instance.toggleCommentLike(current); assert.equal(writes[1].liked, false); finish(); await unlike;
  assert.equal(current.isLiked, false); assert.equal(current.likeCount, 20);
});
test('like reconciliation does not double count a newer already-liked row', async () => {
  const h = detailHarness(async () => ({ items: [], nextMaxId: '0', hasMore: false }), ['toggleCommentLike']);
  let finish; h.service.invalidateComments = () => {}; h.service.setCommentLike = () => new Promise(resolve => { finish = resolve; });
  const original = { id: 'child', isLiked: false, likeCount: 2 }; const action = h.instance.toggleCommentLike(original);
  const child = { id: 'child', isLiked: true, likeCount: 10 }; h.instance.comments = [{ id: 'parent', replies: [child] }];
  finish(); await action; assert.equal(child.isLiked, true); assert.equal(child.likeCount, 10);
});
test('collapsing a pending reply page cannot be undone or clear a newer re-expansion request', async () => {
  const h = detailHarness(async () => ({ items: [], nextMaxId: '0', hasMore: false }), ['loadReplies', 'collapseReplies']);
  const pending = []; h.service.fetchCommentReplies = () => new Promise(resolve => pending.push(resolve));
  const comment = { id: 'c', replies: [{ id: 'existing' }] }; h.instance.expandedReplyIds = ['c']; h.instance.replyCursors.set('c', 'next');
  const old = h.instance.loadReplies(comment); h.instance.collapseReplies('c');
  assert.equal(h.instance.expandedReplyIds.length, 0); assert.equal(h.instance.replyLoadingIds.length, 0);
  const current = h.instance.loadReplies(comment); pending[0]({ items: [{ id: 'stale' }], nextMaxId: 'stale', hasMore: true }); await old;
  assert.equal(h.instance.expandedReplyIds.length, 0); assert.equal(h.instance.replyCursors.size, 0); assert.equal(h.instance.replyLoadingIds.includes('c'), true);
  pending[1]({ items: [{ id: 'fresh' }], nextMaxId: 'fresh', hasMore: true }); await current;
  assert.equal(comment.replies[0].id, 'fresh'); assert.equal(h.instance.replyCursors.get('c'), 'fresh');
});

test('late sorted page read started before like acknowledgement cannot undo the successful like', async () => {
  let finishPage; const h = detailHarness(() => new Promise(resolve => { finishPage = resolve; }), ['toggleCommentLike']);
  let finishLike; h.service.invalidateComments = () => {}; h.service.setCommentLike = () => new Promise(resolve => { finishLike = resolve; });
  const old = { id: 'c', isLiked: false, likeCount: 1 }; h.instance.comments = [old];
  const action = h.instance.toggleCommentLike(old); h.instance.switchCommentSort(1);
  finishLike(); await action;
  finishPage({ items: [{ id: 'c', isLiked: false, likeCount: 20 }], nextMaxId: 'next', hasMore: true }); await new Promise(setImmediate);
  assert.equal(h.instance.comments[0].isLiked, true); assert.equal(h.instance.comments[0].likeCount, 21);
});
test('reads started after a like acknowledgement trust fresh server state, not sticky local overrides', async () => {
  const h = detailHarness(async () => ({ items: [{ id: 'c', isLiked: false, likeCount: 100 }], nextMaxId: '0', hasMore: false }), ['toggleCommentLike']);
  h.service.invalidateComments = () => {}; h.service.setCommentLike = async () => {};
  const row = { id: 'c', isLiked: false, likeCount: 1 }; h.instance.comments = [row]; await h.instance.toggleCommentLike(row);
  h.instance.switchCommentSort(1); await new Promise(setImmediate);
  assert.equal(h.instance.comments[0].isLiked, false); assert.equal(h.instance.comments[0].likeCount, 100);
});

test('comment reply editor uses floating frosted capsule design and sage green theme', () => {
  const fs = require('node:fs'), path = require('node:path');
  const detailSrc = fs.readFileSync(path.resolve(__dirname, '../entry/src/main/ets/pages/WeiboPostDetail.ets'), 'utf8');
  const themeSrc = fs.readFileSync(path.resolve(__dirname, '../entry/src/main/ets/common/Theme.ets'), 'utf8');
  const settingsStoreSrc = fs.readFileSync(path.resolve(__dirname, '../entry/src/main/ets/service/AppSettingsStore.ets'), 'utf8');

  // 1. 悬浮胶囊卡片设计规范验证
  assert.ok(detailSrc.includes('QUICK_REACTION_EMOJIS'), '需定义快捷反应表情列表');
  assert.ok(detailSrc.includes("'😆'") && detailSrc.includes("'😮'") && detailSrc.includes("'🥺'")
    && detailSrc.includes("'😭'") && detailSrc.includes("'😋'") && detailSrc.includes("'😚'")
    && detailSrc.includes("'🙂'") && detailSrc.includes("'🥴'") && detailSrc.includes("'😍'"),
    '需包含全部 9 颗高频表情');
  assert.ok(detailSrc.includes('.borderRadius(26)'), '悬浮卡片需具备 26vp 大圆角');
  assert.ok(detailSrc.includes('backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)'), '需使用超厚度磨砂材质');
  assert.ok(detailSrc.includes("backgroundColor('#66000000')"), '需具备沉浸式半透明遮罩以呈现悬浮卡');

  // 2. 鼠尾草/薄荷绿调全域替换与无红调验证
  assert.ok(themeSrc.includes("DEFAULT_APP_ACCENT: string = '#4EAA78'") || settingsStoreSrc.includes("DEFAULT_APP_ACCENT: string = '#4EAA78'"),
    '默认主题色需为鼠尾草绿 #4EAA78');
  assert.ok(!themeSrc.includes("return '#E6162D'"), 'Theme 默认返回值不得再是旧红调 #E6162D');
  assert.ok(themeSrc.includes("static badgePin(isDark: boolean): string { return isDark ? '#4EAA78' : '#5BB574'; }"),
    '置顶徽章需切换为绿调');
});

test('persistent comment bar uses Option A floating glass capsule design', () => {
  const fs = require('node:fs'), path = require('node:path');
  const detailSrc = fs.readFileSync(path.resolve(__dirname, '../entry/src/main/ets/pages/WeiboPostDetail.ets'), 'utf8');
  assert.ok(detailSrc.includes('.tabBar(this.BottomComposer())'), '评论胶囊必须位于原生 HDS 悬浮槽位');
  assert.ok(detailSrc.includes('.barHeight(56)'), '底栏高度需对齐 HDS 悬浮 Tab');
  assert.ok(detailSrc.includes('.barFloatingStyle(createWeiboDockStyle('), '材质和渐变背板必须与信息流共用配置');
  const composer = detailSrc.slice(detailSrc.indexOf('  BottomComposer()'), detailSrc.indexOf('  ComposerAttachments()'));
  assert.ok(!composer.includes('backgroundBlurStyle'), '不得用普通毛玻璃冒充原生悬浮材质');
  assert.ok(!composer.includes('.shadow('), '投影交给 HDS，避免自绘双重阴影');
  assert.ok(!detailSrc.includes("border({ width: { top: 0.5 }"), '不得使用贴底通栏硬分割线');
});

test('long post detection and video link stripping work accurately', () => {
  const fs = require('node:fs'), path = require('node:path');
  const serviceSrc = fs.readFileSync(path.resolve(__dirname, '../entry/src/main/ets/service/WeiboService.ets'), 'utf8');
  const textSrc = fs.readFileSync(path.resolve(__dirname, '../entry/src/main/ets/common/WeiboText.ets'), 'utf8');
  assert.ok(serviceSrc.includes("expand"), 'isLongPost 需识别 span expand 标签');
  assert.ok(serviceSrc.includes("hasVideo"), 'postText 需识别视频并剔除附带的视频短链');
  assert.ok(textSrc.includes("withoutExpandSpans"), 'normalizeWeiboText 需清洗展开 span 避免残留');
});
