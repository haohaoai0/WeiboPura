const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

test('WeiboService parses embedded hot comment from status response', () => {
  const servicePath = path.join(__dirname, '../entry/src/main/ets/service/WeiboService.ets');
  const src = fs.readFileSync(servicePath, 'utf8');

  // hotComment parsing from comments or hot_comments or comment_summary
  assert.match(src, /let hotComment:\s*WeiboComment \| null = null;/);
  assert.match(src, /source\.comments \?\? source\.hot_comments \?\? source\.comment_summary/);
  assert.match(src, /hotComment:\s*hotComment/);
});

test('WeiboHomeTab implements responsive wide card, HotCommentBox, and responsive media grid', () => {
  const homeTabPath = path.join(__dirname, '../entry/src/main/ets/pages/WeiboHomeTab.ets');
  const src = fs.readFileSync(homeTabPath, 'utf8');

  // Responsive wide card for foldables
  assert.match(src, /PostCard\(post: WeiboPost\): void/);
  assert.match(src, /\.constraintSize\(\{\s*maxWidth:\s*840\s*\}\)/);

  // Embedded HotCommentBox
  assert.match(src, /HotCommentBox\(comment:\s*WeiboComment,\s*post:\s*WeiboPost\):\s*void/);
  assert.match(src, /post\.hotComment !== null && post\.hotComment !== undefined/);
  assert.match(src, /this\.HotCommentBox\(post\.hotComment,\s*post\)/);

  // Responsive picture grid and left alignment
  assert.match(src, /isLargeScreen\(\):\s*boolean/);
  assert.match(src, /pictureCellHeight\(count:\s*number\):\s*number/);
  assert.match(src, /pictureGridWidth\(count:\s*number\):\s*number/);
  assert.match(src, /pictureGridHeight\(count:\s*number\):\s*number/);
  assert.match(src, /Text\('长图'\)/);
  assert.match(src, /\.alignItems\(HorizontalAlign\.Start\)/);
  assert.match(src, /\.alignSelf\(ItemAlign\.Start\)/);
});

test('WeiboPostDetail implements responsive media grid, 长图 badge, and responsive maxWidth: 840', () => {
  const detailPath = path.join(__dirname, '../entry/src/main/ets/pages/WeiboPostDetail.ets');
  const src = fs.readFileSync(detailPath, 'utf8');

  // Responsive picture grid and left alignment
  assert.match(src, /isLargeScreen\(\):\s*boolean/);
  assert.match(src, /pictureCellHeight\(pictures:\s*string\[\]\):\s*number/);
  assert.match(src, /pictureGridWidth\(pictures:\s*string\[\]\):\s*number/);
  assert.match(src, /pictureGridHeight\(pictures:\s*string\[\]\):\s*number/);
  assert.match(src, /Text\('长图'\)/);
  assert.match(src, /\.alignItems\(HorizontalAlign\.Start\)/);
  assert.match(src, /\.alignSelf\(ItemAlign\.Start\)/);

  // Detail reading column maxWidth: 840
  assert.match(src, /\.constraintSize\(\{\s*maxWidth:\s*840\s*\}\)/);
});

test('WeiboHotSearch persists search history via CacheManager and removes exact match header', () => {
  const hotSearchPath = path.join(__dirname, '../entry/src/main/ets/pages/WeiboHotSearch.ets');
  const src = fs.readFileSync(hotSearchPath, 'utf8');

  // CacheManager persistence
  assert.match(src, /loadSearchHistory\(\)/);
  assert.match(src, /CacheManager\.getInstance\(\)\.get\(CACHE_KEY\.WEIBO_SEARCH_HISTORY\)/);
  assert.match(src, /CacheManager\.getInstance\(\)\.put\(CACHE_KEY\.WEIBO_SEARCH_HISTORY/);

  // No exact match user header
  assert.doesNotMatch(src, /Text\('精确匹配用户'\)/);
  assert.doesNotMatch(src, /精确匹配用户/);
});
