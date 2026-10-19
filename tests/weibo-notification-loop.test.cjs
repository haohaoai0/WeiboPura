const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

test('Index.ets messages loop navigates with target parameters, initialTab and targetCommentId', () => {
  const indexSrc = fs.readFileSync(
    path.join(__dirname, '../entry/src/main/ets/pages/Index.ets'),
    'utf8'
  );

  // Message navigation carries full context
  assert.match(indexSrc, /openNotificationDetail\(item:\s*WeiboNotification\)/);
  assert.match(indexSrc, /targetPostId/);
  assert.match(indexSrc, /targetCommentId/);
  assert.match(indexSrc, /initialTab/);

  // Read status tracking
  assert.match(indexSrc, /markNotificationRead/);
});
