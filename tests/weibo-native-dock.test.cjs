const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { createLoader, createMethodHarness } = require('./ets-loader.cjs');
const levels = { EXQUISITE: 0, GENTLE: 1, SMOOTH: 2, ADAPTIVE: 3 };
const load = createLoader({ '@kit.UIDesignKit': {
  hdsMaterial: { MaterialLevel: levels, MaterialType: { IMMERSIVE: 1 } }
}});
const { createWeiboDockStyle } = load('common/WeiboDockStyle');
const root = path.join(__dirname, '../entry/src/main/ets');

test('feed and composer use identical native material and default HDS gradient backplate', () => {
  for (const level of [0, 1, 2, 3, -1]) {
    const feed = createWeiboDockStyle(level, '#4EAA78');
    const composer = createWeiboDockStyle(level, '#4EAA78', 400);
    assert.equal(feed.systemMaterialEffect.materialType, 1);
    assert.equal(feed.systemMaterialEffect.materialLevel, level >= 0 && level < 3 ? level : 3);
    assert.equal(JSON.stringify(feed.systemMaterialEffect), JSON.stringify(composer.systemMaterialEffect));
    assert.equal(feed.barBottomMargin, composer.barBottomMargin);
    assert.equal(feed.lightColor, composer.lightColor);
    assert.equal(feed.gradientMask, undefined); // preserve native light/dark adaptive defaults
    assert.equal(composer.gradientMask, undefined);
    assert.equal(composer.barWidth.smallWidth, 400);
  }
});

test('composer lives in a real HdsTabs tabBar without a fake opaque blur shell', () => {
  const detail = fs.readFileSync(path.join(root, 'pages/WeiboPostDetail.ets'), 'utf8');
  const feed = fs.readFileSync(path.join(root, 'pages/Index.ets'), 'utf8');
  assert.match(feed, /barFloatingStyle\(createWeiboDockStyle\(/);
  assert.match(detail, /barFloatingStyle\(createWeiboDockStyle\(/);
  assert.match(detail, /HdsTabs\(\{ controller: this\.composerTabsController \}\)/);
  assert.match(detail, /\.tabBar\(this\.BottomComposer\(\)\)/);
  const composer = detail.slice(detail.indexOf('  BottomComposer()'), detail.indexOf('  ComposerAttachments()'));
  assert.doesNotMatch(composer, /backgroundBlurStyle|\.shadow\(|manualGlassBorder|rgba\(255, 255, 255, 0\.88\)/);
});

test('native capsule and backplate hide together for editor, loading and scroll state', () => {
  const calls = [];
  const h = createMethodHarness('pages/WeiboPostDetail.ets', ['syncComposerDockVisibility'], {
    HdsAnimationMode: { SCROLL_ANIMATION: 0 }
  });
  Object.assign(h, { loading: false, commentComposerHidden: false, commentEditorOpen: false, post: {},
    composerTabsController: { applyShowAnimation() { calls.push('show'); }, applyHideAnimation() { calls.push('hide'); } }
  });
  h.syncComposerDockVisibility();
  for (const field of ['loading', 'commentComposerHidden', 'commentEditorOpen']) {
    h[field] = true; h.syncComposerDockVisibility(); h[field] = false;
  }
  h.post = null; h.syncComposerDockVisibility();
  assert.deepEqual(calls, ['show', 'hide', 'hide', 'hide', 'hide']);
});
