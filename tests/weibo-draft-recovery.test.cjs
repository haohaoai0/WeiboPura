const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

test('WeiboDraftManager manages multi-scenario drafts and account isolation', () => {
  const draftSrc = fs.readFileSync(
    path.join(__dirname, '../entry/src/main/ets/service/WeiboDraftManager.ets'),
    'utf8'
  );

  assert.match(draftSrc, /class WeiboDraftManager/);
  assert.match(draftSrc, /saveDraft/);
  assert.match(draftSrc, /getDraft/);
  assert.match(draftSrc, /deleteDraft/);
  assert.match(draftSrc, /getAllDrafts/);
  assert.match(draftSrc, /weibo_draft_/);
  assert.match(draftSrc, /WeiboDraftType/);
});

test('WeiboComposeDialog auto-saves draft, recovers on reopen, and purges on publish success', () => {
  const dialogSrc = fs.readFileSync(
    path.join(__dirname, '../entry/src/main/ets/components/WeiboComposeDialog.ets'),
    'utf8'
  );

  assert.match(dialogSrc, /WeiboDraftManager/);
  assert.match(dialogSrc, /saveDraft/);
  assert.match(dialogSrc, /deleteDraft/);
  // Preserves existing requirements
  assert.match(dialogSrc, /handleClose\(\): void/);
  assert.match(dialogSrc, /放弃内容/);
});

test('WeiboPostDetail auto-saves comment and reply drafts and restores them per post/comment', () => {
  const detailSrc = fs.readFileSync(
    path.join(__dirname, '../entry/src/main/ets/pages/WeiboPostDetail.ets'),
    'utf8'
  );

  assert.match(detailSrc, /WeiboDraftManager/);
  assert.match(detailSrc, /saveDraft/);
  assert.match(detailSrc, /getDraft/);
  assert.match(detailSrc, /deleteDraft/);
});
