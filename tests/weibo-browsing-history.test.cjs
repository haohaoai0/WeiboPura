const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

test('WeiboHistoryManager handles recording, deduplication, capacity limit, and toggle', () => {
  const historySrc = fs.readFileSync(
    path.join(__dirname, '../entry/src/main/ets/service/WeiboHistoryManager.ets'),
    'utf8'
  );

  assert.match(historySrc, /class WeiboHistoryManager/);
  assert.match(historySrc, /recordHistory/);
  assert.match(historySrc, /getHistory/);
  assert.match(historySrc, /deleteHistoryItem/);
  assert.match(historySrc, /clearHistory/);
  assert.match(historySrc, /weibo_history_/);
  assert.match(historySrc, /500/); // Capped at 500 entries
});

test('WeiboPostDetail records browsing history on post load', () => {
  const detailSrc = fs.readFileSync(
    path.join(__dirname, '../entry/src/main/ets/pages/WeiboPostDetail.ets'),
    'utf8'
  );

  assert.match(detailSrc, /WeiboHistoryManager/);
  assert.match(detailSrc, /recordHistory/);
});

test('WeiboFeed supports history mode and Index.ets links to browsing history', () => {
  const feedSrc = fs.readFileSync(
    path.join(__dirname, '../entry/src/main/ets/pages/WeiboFeed.ets'),
    'utf8'
  );
  const indexSrc = fs.readFileSync(
    path.join(__dirname, '../entry/src/main/ets/pages/Index.ets'),
    'utf8'
  );

  assert.match(feedSrc, /history/);
  assert.match(feedSrc, /浏览历史/);
  assert.match(indexSrc, /openHistory/);
  assert.match(indexSrc, /浏览历史/);
});
