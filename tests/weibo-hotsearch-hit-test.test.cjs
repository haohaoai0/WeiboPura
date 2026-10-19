const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

// Source guard, not a substitute for checking focus and keyboard on the device.
test('Discover hides the native title overlay instead of only clearing its title text', () => {
  const src = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/pages/Index.ets'), 'utf8');
  assert.match(src, /\.hideTitleBar\(this\.privacyReady && this\.privacyAccepted && this\.selectedTab === WeiboTab\.Discover\)/);
  assert.doesNotMatch(src, /\.hideTitleBar\(false\)/);
});
