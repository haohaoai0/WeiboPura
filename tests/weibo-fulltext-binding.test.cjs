const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

// Source guard only: ArkUI's actual reactive refresh is verified on the phone.
const source = fs.readFileSync(path.join(__dirname,
  '../entry/src/main/ets/pages/WeiboPostDetail.ets'), 'utf8');
test('detail PostBody receives a reactive object literal, not a by-value post snapshot', () => {
  assert.match(source, /interface PostBodyParams\s*\{\s*post: WeiboPost;/);
  assert.match(source, /PostBody\(params: PostBodyParams\)/);
  assert.match(source, /this\.PostBody\(\{ post: this\.post \}\)/);
  const body = source.slice(source.indexOf('PostBody(params:'), source.indexOf('  CommentItem('));
  assert.match(body, /text: params\.post\.text/);
  assert.match(body, /if \(params\.post\.isLongText\)/);
  assert.doesNotMatch(body, /currentPost/);
  assert.doesNotMatch(source, /this\.PostBody\(this\.post\)/);
});
