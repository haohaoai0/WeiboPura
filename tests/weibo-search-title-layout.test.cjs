const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/pages/WeiboSearchResult.ets'), 'utf8');

test('search categories occupy the HDS bottom slot rather than overflowing the mini title slot', () => {
  const title = source.slice(source.indexOf('  SearchTitleBar()'), source.indexOf('  SearchCategoryBar()'));
  assert.ok(title.includes('.height(56)'));
  assert.ok(!title.includes('ForEach(this.tabs'));
  assert.ok(!title.includes('Scroll()'));
  assert.match(source, /stackBuilder: \(\): void => this\.SearchTitleBar\(\)/);
  assert.match(source, /bottomBuilder: \{ builder: \(\): void => this\.SearchCategoryBar\(\) \}/);
  assert.match(source, /avoidLayoutSafeArea: true/);
  const categories = source.slice(source.indexOf('  SearchCategoryBar()'), source.indexOf('  SearchContent()'));
  assert.ok(categories.includes('ForEach(this.tabs'));
  assert.ok(categories.includes('.height(34)'));
});
