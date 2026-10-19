const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { createMethodHarness } = require('./ets-loader.cjs');
function harness() {
  const calls = [], pending = [], toasts = [];
  const service = { fetchCommentReplies: (id, cursor) => { calls.push({ id, cursor }); return new Promise(resolve => pending.push(resolve)); } };
  const auth = { getSessionRevision: () => 1, isSessionChanging: () => false };
  const instance = createMethodHarness('pages/WeiboPostDetail.ets', ['loadReplies', 'collapseReplies', 'commentThreadKey', 'isCurrentSession', 'isCurrentCommentRequest', 'isCurrentReplyRequest'], {
    WeiboAuthManager: { getInstance: () => auth }, WeiboService: { getInstance: () => service }, hilog: { info() {} }
  });
  Object.assign(instance, { comments: [], commentsEpoch: 0, replyLoadingIds: [], expandedReplyIds: [], replyCursors: new Map(), replyEpochs: new Map(), commentLikeVersion: 0,
    applyConcurrentCommentLikes() {}, getUIContext: () => ({ getPromptAction: () => ({ showToast: value => toasts.push(value.message) }) }) });
  return { instance, calls, pending, toasts };
}
test('thread render identity changes from preview through two pages and terminal state', async () => {
  const h = harness(), v = h.instance;
  const comment = { id: 'root', replyCount: 12, replies: [] }, other = { id: 'other', replies: [] };
  v.comments = [comment, other];
  const idle = v.commentThreadKey(comment), otherKey = v.commentThreadKey(other), before = v.comments;
  const first = v.loadReplies(comment);
  assert.notEqual(v.comments, before);
  assert.notEqual(v.commentThreadKey(comment), idle);
  h.pending.shift()({ items: Array.from({ length: 10 }, (_, i) => ({ id: 'child-' + i })), nextMaxId: 'next', hasMore: true }); await first;
  const page1 = v.commentThreadKey(comment);
  assert.equal(comment.replies.length, 10);
  const second = v.loadReplies(comment);
  assert.notEqual(v.commentThreadKey(comment), page1);
  h.pending.shift()({ items: [{ id: 'child-9' }, { id: 'child-10' }, { id: 'child-11' }], nextMaxId: '0', hasMore: false }); await second;
  assert.equal(comment.replies.length, 12);
  assert.notEqual(v.commentThreadKey(comment), page1);
  assert.equal(v.commentThreadKey(other), otherKey);
  assert.equal(v.replyCursors.get('root'), '0');
  assert.equal(v.replyLoadingIds.length, 0);
  assert.deepEqual(h.calls.map(c => c.cursor), ['0', 'next']);
  await v.loadReplies(comment); assert.equal(h.calls.length, 2);
  v.collapseReplies('root'); assert.equal(v.replyCursors.has('root'), false);
});
test('duplicate page with unchanged cursor remains retryable and reports no progress', async () => {
  const h = harness(), v = h.instance, comment = { id: 'root', replies: [{ id: 'child' }] };
  v.comments = [comment]; v.expandedReplyIds = ['root']; v.replyCursors.set('root', 'next');
  const request = v.loadReplies(comment);
  h.pending.shift()({ items: [{ id: 'child' }], nextMaxId: 'next', hasMore: false }); await request;
  assert.equal(v.replyCursors.get('root'), 'next');
  assert.equal(comment.replies.length, 1);
  assert.equal(v.replyLoadingIds.length, 0);
  assert.equal(h.toasts.length, 1);
});
test('ArkUI root ForEach keys use reply state rather than only immutable comment ID', () => {
  const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/pages/WeiboPostDetail.ets'), 'utf8');
  assert.ok(source.includes('(comment: WeiboComment): string => this.commentThreadKey(comment)'));
  assert.ok(source.includes("Text('已加载全部回复')"));
});
