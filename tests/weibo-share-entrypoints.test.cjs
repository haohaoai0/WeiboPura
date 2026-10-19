const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const page = name => fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/pages', name + '.ets'), 'utf8');

for (const name of ['WeiboUserProfile', 'WeiboSearch', 'WeiboSearchResult']) {
  test(`${name} connects every visible ThreadCard share action`, () => {
    const source = page(name);
    const cards = source.split('ThreadCard({').slice(1);
    assert.ok(cards.length > 0);
    for (const card of cards) {
      assert.match(card.split('skipImageCache:')[0], /onShare:/);
    }
    assert.ok(source.includes('ShareUtil.shareLink('));
    assert.ok(source.includes('https://m.weibo.cn/detail/'));
  });
}

test('detail exposes its share handler through an accessible title bar action', () => {
  const source = page('WeiboPostDetail');
  const title = source.slice(source.indexOf('  DetailTitleBar()'), source.indexOf('  private isGifOrLive'));
  assert.ok(title.includes("$r('sys.symbol.share')"));
  assert.ok(title.includes(".accessibilityText($r('app.string.weibo_share'))"));
  assert.ok(title.includes('.enabled(this.post !== null)'));
  assert.ok(title.includes('this.sharePost();'));
});
