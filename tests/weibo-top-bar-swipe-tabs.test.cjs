const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { stripTypeScriptTypes } = require('node:module');
const root = path.join(__dirname, '../entry/src/main/ets');
const source = fs.readFileSync(path.join(root, 'common/WeiboTabSwipe.ets'), 'utf8');
let clock = 0;
const context = { TouchType: { Down: 0, Move: 1, Up: 2, Cancel: 3 },
  GestureJudgeResult: { CONTINUE: 0, REJECT: 1 }, hilog: { info() {} }, Date: { now: () => clock } };
vm.createContext(context);
vm.runInContext(stripTypeScriptTypes(source.replace(/^import .*;\r?\n/gm, '').replaceAll('export class', 'class').replaceAll('export const', 'const')) + '\nthis.Swipe = WeiboTabSwipe; this.Tracker = WeiboTabTouchTracker;', context);
function swipe(points, elapsed = 300, velocityX = 0) {
  const s = new context.Swipe(); s.begin(200, 200, 0);
  for (const [x, y] of points) s.move(200 + x, 200 + y);
  const [x, y] = points.at(-1);
  return s.end(200 + x, 200 + y, elapsed, velocityX);
}
const touch = (type, x, y, n = 1) => ({type, touches: Array(n).fill({}), changedTouches: [{id: 0, windowX: x, windowY: y}]});
const pan = (x, y, velocityX = 0) => ({fingerList: [{id: 0, globalX: x, globalY: y}], velocityX});
const info = {tag: 'weibo-tab-swipe'};
function begin() { clock = 0; const t = new context.Tracker('test'); t.track(touch(0, 200, 200)); return t; }
test('clear left/right swipes switch once; small fast jitter never switches', () => {
  assert.equal(swipe([[-16, 1], [-110, 9]]), 1);
  assert.equal(swipe([[16, 1], [110, 9]]), -1);
  assert.equal(swipe([[16, 1], [35, 2]], 70), 0);
  assert.equal(swipe([[16, 1], [100, 2]], 1200), -1);
  const s = new context.Swipe(); s.begin(200, 200, 0);
  assert.equal(s.end(90, 201, 300), 1);
  assert.equal(s.end(90, 201, 301), 0);
});
test('vertical-first and diagonal-first scrolling cannot become a swipe at release', () => {
  assert.equal(swipe([[2, 16], [100, 18]], 100, 2000), 0);
  assert.equal(swipe([[14, 14], [120, 11]], 100, 2000), 0);
  assert.equal(swipe([[20, 90], [110, 300]]), 0);
});
test('owned thumb arcs and deliberate short flicks no longer require repeated swipes', () => {
  assert.equal(swipe([[16, 8], [60, 30]], 200), -1);
  assert.equal(swipe([[-16, 6], [-55, 29]], 200), 1);
  assert.equal(swipe([[18, 1], [90, 35], [120, 4]]), -1);
  assert.equal(swipe([[16, 1], [30, 3]], 45, 800), -1);
  assert.equal(swipe([[-16, 1], [-30, 3]], 45, -800), 1);
  assert.equal(swipe([[16, 1], [20, 3]], 45, 2000), 0);
  assert.equal(swipe([[16, 1], [30, 3]], 45, -800), 0);
  assert.equal(swipe([[16, 1], [30, 3]], 500, 100), 0);
});
test('native updates provide bounded drag feedback; the next gesture needs no cooldown', () => {
  const t = begin();
  assert.equal(t.update(pan(240, 204), true, true), 0);
  t.judge(info, pan(216, 204), true); t.claim();
  const open = t.update(pan(240, 205), true, true);
  const edge = t.update(pan(240, 205), false, true);
  assert.ok(open > 0 && open < 40 && edge < open);
  clock = 50; assert.equal(t.finish(pan(230, 205, 800)), -1);
  t.track(touch(0, 200, 200));
  t.judge(info, pan(184, 201), true); t.claim();
  clock = 100; assert.equal(t.finish(pan(170, 205, -800)), 1);
});
test('raw touch Up cannot commit; a winning native pan is required', () => {
  const t = begin(); clock = 300;
  assert.equal(t.track(touch(1, 90, 200)), undefined);
  assert.equal(t.track(touch(2, 90, 200, 0)), undefined);
  assert.equal(t.finish(pan(90, 200)), 0);
});
test('native judge before raw Move uses current native coordinates, not stale tracker', () => {
  const t = begin();
  assert.equal(t.judge(info, pan(184, 201), true), 0);
  t.claim(); clock = 300;
  assert.equal(t.finish(pan(90, 201)), 1);
  assert.equal(t.finish(pan(90, 201)), 0);
  const v = begin();
  assert.equal(v.judge(info, pan(184, 225), true), 1);
});
test('raw Up before native End preserves ownership and commits once', () => {
  const t = begin();
  assert.equal(t.judge(info, pan(184, 201), true), 0); t.claim();
  clock = 300; t.track(touch(2, 90, 201, 0));
  assert.equal(t.finish(pan(90, 201)), 1);
  assert.equal(t.finish(pan(90, 201)), 0);
});
test('short native-owned drag consumes gesture without switching tab', () => {
  const t = begin();
  assert.equal(t.judge(info, pan(184, 201), true), 0); t.claim();
  clock = 300; assert.equal(t.finish(pan(170, 201)), 0);
});
test('cancel, multi-touch, missing down, disabled and lost native arena never commit', () => {
  for (const cancel of [t => t.cancel(), t => t.track(touch(3, 180, 200)), t => t.track(touch(1, 180, 200, 2))]) {
    const t = begin(); t.judge(info, pan(184, 201), true); t.claim(); cancel(t);
    clock = 300; assert.equal(t.finish(pan(90, 201)), 0);
  }
  const t = begin();
  assert.equal(t.judge(info, pan(184, 201), false), 1);
  const missing = new context.Tracker('test');
  assert.equal(missing.judge(info, pan(184, 201), true), 1);
  const lost = begin(); lost.judge(info, pan(184, 201), true);
  clock = 300; assert.equal(lost.finish(pan(90, 201)), 0);
});
test('navigation and media clicks bound movement even if the pan is rejected', () => {
  assert.match(source, /WEIBO_TAP_MAX_MOVEMENT: number = 12/);
  for (const file of ['pages/WeiboHomeTab.ets', 'pages/WeiboPostDetail.ets', 'pages/WeiboSearchResult.ets', 'components/CommonComponents.ets']) {
    const s = fs.readFileSync(path.join(root, file), 'utf8');
    assert.ok(s.includes(', WEIBO_TAP_MAX_MOVEMENT)'), file);
  }
  const detail = fs.readFileSync(path.join(root, 'pages/WeiboPostDetail.ets'), 'utf8');
  assert.match(detail, /beginCommentReply\(comment\); }, WEIBO_TAP_MAX_MOVEMENT/);
  assert.match(detail, /openImagePreview\(pictures, 0, pictureVideos\); }, WEIBO_TAP_MAX_MOVEMENT/);
  assert.match(detail, /minHeight: Math\.max\(240, this\.detailViewportHeight/);
});
test('all three page integrations use native exclusive pan as sole switch callback', () => {
  for (const [file, label, count] of [['Index', 'Home', 2], ['WeiboSearchResult', 'Search', 1], ['WeiboPostDetail', 'Detail', 1]]) {
    const s = fs.readFileSync(path.join(root, `pages/${file}.ets`), 'utf8');
    assert.equal((s.match(new RegExp(`this.on${label}TabPanEnd\\(event(?:, this\\.\\w+)?\\)`, 'g')) || []).length, count);
    assert.ok(s.includes(file === 'Index' ? 'tracker.finish(event)' : 'this.tabTouchTracker.finish(event)'));
    assert.ok(s.includes('.onActionUpdate('));
    assert.ok(s.includes('.translate({ x: this.tabDragOffset })'));
    assert.ok(!/is(HomeMode|DetailTab|Tab)Switching/.test(s));
    assert.equal((s.match(/\.tag\('weibo-tab-swipe'\)/g) || []).length, count);
    assert.ok(s.includes('.onActionCancel('));
    assert.ok(s.includes('.onGestureJudgeBegin('));
    assert.ok(!s.includes('.parallelGesture('));
    assert.ok(!s.includes(`on${label}TabTouch`));
    assert.ok(!s.includes('DetailTitleTabItem'));
    if (file === 'Index') assert.ok(s.includes('.scrollable(this.selectedTab !== WeiboTab.Home)'));
  }
});
