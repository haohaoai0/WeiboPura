const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { createMethodHarness } = require('./ets-loader.cjs');
const root = path.resolve(__dirname, '../entry/src/main/ets');

test('all post copy paths retain follow state after like and long-text updates', () => {
  for (const [file, method, argument] of [
    ['pages/WeiboHomeTab.ets', 'copyPostWithLike', true],
    ['pages/WeiboFeed.ets', 'copyPostWithLike', true],
    ['pages/WeiboPostDetail.ets', 'copyPostWithLike', true],
    ['pages/WeiboPostDetail.ets', 'copyPostWithText', 'full text']
  ]) {
    const harness = createMethodHarness(file, [method]);
    for (const following of [true, false]) {
      const result = harness[method]({ id: 'post', isFollowed: following, likeCount: 1 }, argument);
      assert.equal(result.isFollowed, following, file + ':' + method);
    }
  }
});

test('feed list keys invalidate old builder snapshots when follow status changes', () => {
  const source = fs.readFileSync(path.join(root, 'pages/WeiboHomeTab.ets'), 'utf8');
  assert.equal((source.match(/`\$\{post\.id\}:\$\{post\.isFollowed \?\? false\}`/g) || []).length, 2);
});

const modes = { Begin: 0, Moving: 1, End: 2, Click: 3 };
function player() {
  const seeks = [];
  const h = createMethodHarness('components/WeiboVideoPlayer.ets', [
    'clearHideTimer', 'scheduleControlsHide', 'handleFullscreenChange', 'seekTo'
  ], { SliderChangeMode: modes, SeekMode: { Accurate: 0 } });
  Object.assign(h, { hideTimer: -1, playing: false, showControls: false, fullscreen: false,
    seeking: false, currentSeconds: 0, controller: { setCurrentTime: (time) => seeks.push(time) } });
  return { h, seeks };
}

test('native fullscreen enables its controller and restores embedded controls on exit', () => {
  const source = fs.readFileSync(path.join(root, 'components/WeiboVideoPlayer.ets'), 'utf8');
  assert.ok(source.includes('.controls(this.fullscreen)'));
  assert.ok(source.includes('this.handleFullscreenChange(event.fullscreen)'));
  assert.ok(source.includes('!this.failed && !this.fullscreen'));
  const { h } = player();
  h.playing = true;
  h.handleFullscreenChange(true);
  assert.equal(h.fullscreen, true);
  assert.equal(h.hideTimer, -1);
  h.playing = false;
  h.handleFullscreenChange(false);
  assert.equal(h.fullscreen, false);
  assert.equal(h.showControls, true);
});

test('dragging progress cancels auto-hide and seeks only on completion', () => {
  const { h, seeks } = player();
  h.playing = true;
  h.scheduleControlsHide();
  assert.notEqual(h.hideTimer, -1);
  h.seekTo(12, modes.Begin);
  assert.equal(h.hideTimer, -1);
  h.seekTo(20, modes.Moving);
  assert.equal(h.currentSeconds, 20);
  assert.equal(h.seeking, true);
  assert.equal(seeks.length, 0);
  h.seekTo(24, modes.End);
  assert.deepEqual(seeks, [24]);
  assert.equal(h.seeking, false);
  assert.notEqual(h.hideTimer, -1);
  h.clearHideTimer();
  h.playing = false;
  h.seekTo(7, modes.Click);
  assert.deepEqual(seeks, [24, 7]);
  assert.equal(h.showControls, true);
});
