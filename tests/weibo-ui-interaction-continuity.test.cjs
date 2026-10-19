const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

test('WeiboPostDetail preserves replyTarget on editor close and unregisters specific keyboard listener', () => {
  const detailPath = path.join(__dirname, '../entry/src/main/ets/pages/WeiboPostDetail.ets');
  const src = fs.readFileSync(detailPath, 'utf8');

  // closeCommentEditor keeps replyTargetComment intact
  assert.match(src, /private closeCommentEditor\(\): void \{/);
  assert.doesNotMatch(src, /private closeCommentEditor\(\): void \{\s*this\.commentEditorOpen = false;[^}]*this\.replyTargetComment = null;/);

  // onKeyboardHeightChange is a named method unbinding specifically
  assert.match(src, /private onKeyboardHeightChange = \(heightPx: number\): void/);
  assert.match(src, /win\.on\('keyboardHeightChange', this\.onKeyboardHeightChange\);/);
  assert.match(src, /win\.off\('keyboardHeightChange', this\.onKeyboardHeightChange\);/);

  // WeiboPostDetailRouteParam carries user intent
  assert.match(src, /initialTab\?: WeiboDetailTab;/);
  assert.match(src, /autoFocusComment\?: boolean;/);
  assert.match(src, /targetCommentId\?: string;/);

  // loadPost unblocks loading immediately after post arrives
  assert.match(src, /this\.post = post;\s*\/\/ 正文数据到达后立即解除全屏 loading/);
});

test('WeiboComposeDialog guards unsaved content and uses 44vp close target', () => {
  const dialogPath = path.join(__dirname, '../entry/src/main/ets/components/WeiboComposeDialog.ets');
  const src = fs.readFileSync(dialogPath, 'utf8');

  // handleClose confirms before discard
  assert.match(src, /handleClose\(\): void/);
  assert.match(src, /this\.content\.trim\(\)\.length > 0 \|\| this\.selectedImages\.length > 0/);
  assert.match(src, /showAlertDialog\(\{/);
  assert.match(src, /放弃内容/);

  // Close button touch target 44vp
  assert.match(src, /\.width\(44\)\s*\.height\(44\)/);
});

test('WeiboService synchronizes mutations globally through AppStorage keys', () => {
  const servicePath = path.join(__dirname, '../entry/src/main/ets/service/WeiboService.ets');
  const src = fs.readFileSync(servicePath, 'utf8');

  assert.match(src, /AppStorage\.setOrCreate<string>\('weibo_sync_like',\s*`\$\{id\}:\$\{like\}:\$\{Date\.now\(\)\}`\);/);
  assert.match(src, /AppStorage\.setOrCreate<string>\('weibo_sync_favorite',\s*`\$\{postId\.trim\(\)\}:\$\{favorite\}:\$\{Date\.now\(\)\}`\);/);
  assert.match(src, /AppStorage\.setOrCreate<string>\('weibo_sync_follow',\s*`\$\{id\}:true:\$\{Date\.now\(\)\}`\);/);
  assert.match(src, /AppStorage\.setOrCreate<string>\('weibo_sync_follow',\s*`\$\{id\}:false:\$\{Date\.now\(\)\}`\);/);
});

test('WeiboSearchResult preserves category snapshots and unifies search history', () => {
  const resultPath = path.join(__dirname, '../entry/src/main/ets/pages/WeiboSearchResult.ets');
  const src = fs.readFileSync(resultPath, 'utf8');

  // Tab snapshot caching
  assert.match(src, /interface SearchTabSnapshot/);
  assert.match(src, /this\.tabSnapshots\.set\(this\.currentTab,/);
  assert.match(src, /const snapshot: SearchTabSnapshot \| undefined = this\.tabSnapshots\.get\(index\);/);

  // Search history persistence
  assert.match(src, /saveSearchHistory\(word: string\): void/);
  assert.match(src, /CacheManager\.getInstance\(\)\.put\(CACHE_KEY\.WEIBO_SEARCH_HISTORY/);

  // Navigation split synchronization
  assert.match(src, /syncWeiboSplitNavigation\(this\.weiboNavStack\);/);
});

test('ImagePreview handles system back, status bar restore, and isolates zoom scale from UI chrome', () => {
  const previewPath = path.join(__dirname, '../entry/src/main/ets/pages/ImagePreview.ets');
  const src = fs.readFileSync(previewPath, 'utf8');

  // System back gesture intercepts and calls closePreview
  assert.match(src, /onBackPress\(\): boolean \{\s*this\.closePreview\(\);\s*return true;\s*\}/);

  // closePreview restores status bar
  assert.match(src, /this\.restoreStatusBar\(\);/);

  // Swiper owns previewScale, root stack only has previewOpacity
  assert.match(src, /Swiper\(\)[\s\S]*?\.scale\(\{\s*x:\s*this\.previewScale,\s*y:\s*this\.previewScale\s*\}\)/);
  assert.doesNotMatch(src, /\.renderGroup\(true\)\s*\}\s*\.width\('100%'\)\s*\.height\('100%'\)\s*\.backgroundColor\(Color\.Black\)\s*\.opacity\(this\.previewOpacity\)\s*\.scale\(/);
});

test('WeiboBrowser uses overlay loading and syncs navigation layout', () => {
  const browserPath = path.join(__dirname, '../entry/src/main/ets/pages/WeiboBrowser.ets');
  const src = fs.readFileSync(browserPath, 'utf8');

  // Stack overlay prevents 24vp content jumping
  assert.match(src, /Stack\(\{\s*alignContent:\s*Alignment\.Top\s*\}\)/);
  assert.match(src, /syncWeiboSplitNavigation\(this\.weiboNavStack\);/);
});

test('WeiboVideoPlayer pauses automatically when scrolled out of view', () => {
  const playerPath = path.join(__dirname, '../entry/src/main/ets/components/WeiboVideoPlayer.ets');
  const src = fs.readFileSync(playerPath, 'utf8');

  assert.match(src, /\.onVisibleAreaChange\(\[0\.0\],/);
  assert.match(src, /this\.controller\.pause\(\);/);
});
