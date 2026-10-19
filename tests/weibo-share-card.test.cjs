const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

test('WeiboShareCardDialog implements fixed-width card, Fluo branding, and share actions', () => {
  const dialogSrc = fs.readFileSync(
    path.join(__dirname, '../entry/src/main/ets/components/WeiboShareCardDialog.ets'),
    'utf8'
  );

  assert.match(dialogSrc, /struct WeiboShareCardDialog/);
  assert.match(dialogSrc, /post:\s*WeiboPost/);
  // Fixed card width
  assert.match(dialogSrc, /\.width\(360\)/);
  // Fluo branding
  assert.match(dialogSrc, /Fluo/);
  // Scheme 2 (流光青绿卡片) elements
  assert.match(dialogSrc, /精选摘录/);
  assert.match(dialogSrc, /“/);
  assert.match(dialogSrc, /Fluo · 沉浸阅读/);
  assert.match(dialogSrc, /m\.weibo\.cn/);
  // Repost support
  assert.match(dialogSrc, /this\.post\.repost/);
  // Actions
  assert.match(dialogSrc, /saveCardImage/);
  assert.match(dialogSrc, /shareCardImage/);
});

test('WeiboShareCard prototype file exists and contains approved Scheme 2', () => {
  const protoPath = path.join(__dirname, '../docs/prototypes/share-card-prototype.html');
  assert.ok(fs.existsSync(protoPath), 'share-card-prototype.html must exist');
  const protoSrc = fs.readFileSync(protoPath, 'utf8');
  assert.match(protoSrc, /方案 B：流光青绿卡片/);
  assert.match(protoSrc, /Fluo/);
});

test('WeiboPostDetail provides entry point for generating share card', () => {
  const detailSrc = fs.readFileSync(
    path.join(__dirname, '../entry/src/main/ets/pages/WeiboPostDetail.ets'),
    'utf8'
  );

  assert.match(detailSrc, /WeiboShareCardDialog/);
  assert.match(detailSrc, /openShareCard/);
});
