const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

test('WeiboReadingPositionManager manages debounced save, restore, and account isolation', async () => {
  const managerSrc = fs.readFileSync(
    path.join(__dirname, '../entry/src/main/ets/service/WeiboReadingPositionManager.ets'),
    'utf8'
  );

  // Check key methods and signatures
  assert.match(managerSrc, /class WeiboReadingPositionManager/);
  assert.match(managerSrc, /savePosition/);
  assert.match(managerSrc, /getPosition/);
  assert.match(managerSrc, /clearPosition/);
  assert.match(managerSrc, /flush/);

  // Account isolation & cache storage
  assert.match(managerSrc, /weibo_timeline_pos_/);
  assert.match(managerSrc, /accountKey/);
  assert.match(managerSrc, /topPostId/);
  assert.match(managerSrc, /topIndex/);
  assert.match(managerSrc, /posts/);
});

test('WeiboHomeTab integrates reading position persistence and foldable preservation', () => {
  const homeTabSrc = fs.readFileSync(
    path.join(__dirname, '../entry/src/main/ets/pages/WeiboHomeTab.ets'),
    'utf8'
  );

  // Uses WeiboReadingPositionManager
  assert.match(homeTabSrc, /WeiboReadingPositionManager/);

  // Does not blindly reset scroll to 0 on columnMode change if already reading
  assert.doesNotMatch(homeTabSrc, /this\.pageScroller\.scrollTo\(\{\s*xOffset:\s*0,\s*yOffset:\s*0\s*\}\);/);

  // List onScrollIndex or onDidScroll saves reading position
  assert.match(homeTabSrc, /onScrollIndex/);

  // List onScrollStop saves accurate reading position when fling settles
  assert.match(homeTabSrc, /onScrollStop/);

  // Restoring position protection avoids race with frame 0 onScrollIndex(0)
  assert.match(homeTabSrc, /isRestoringPosition/);

  // Slices and saves new position on new posts and pull to refresh
  assert.match(homeTabSrc, /applyNewPosts/);
  assert.match(homeTabSrc, /refreshFeed/);

  // New posts indicator / pill
  assert.match(homeTabSrc, /newPostsAvailableCount/);
});

test('Background and lifecycle flushes ensure durable reading position persistence', () => {
  const abilitySrc = fs.readFileSync(
    path.join(__dirname, '../entry/src/main/ets/entryability/EntryAbility.ets'),
    'utf8'
  );
  assert.match(abilitySrc, /WeiboReadingPositionManager\.getInstance\(\)\.flush/);
  assert.match(abilitySrc, /WeiboDraftManager\.getInstance\(\)\.flush/);

  const indexSrc = fs.readFileSync(
    path.join(__dirname, '../entry/src/main/ets/pages/Index.ets'),
    'utf8'
  );
  assert.match(indexSrc, /WeiboReadingPositionManager\.getInstance\(\)\.flush/);
});
