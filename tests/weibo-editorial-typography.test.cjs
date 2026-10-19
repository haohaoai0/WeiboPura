const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { createLoader } = require('./ets-loader.cjs');

function textHarness() {
  const load = createLoader({
    '@kit.AbilityKit': { common: {} },
    '@kit.ArkTS': { util: { TextDecoder: class { decodeWithStream() { return JSON.stringify({ data: { emoticon: { ZH_CN: {} } } }); } } } },
    '../network/WeiboHttpClient': { WeiboHttpClient: {} }
  });
  const text = load('common/WeiboText');
  const tokens = load('common/WeiboRichTokens');
  return { ...text, ...tokens };
}

test('applyPanguSpacing inserts micro-spaces between CJK and Latin/Digits without doubling', () => {
  const h = textHarness();
  assert.equal(h.applyPanguSpacing('换一台iPhone Duo。'), '换一台 iPhone Duo。');
  assert.equal(h.applyPanguSpacing('小米18 Fold'), '小米 18 Fold');
  assert.equal(h.applyPanguSpacing('办了eSIM卡'), '办了 eSIM 卡');
  assert.equal(h.applyPanguSpacing('已经有 空格 的文字'), '已经有 空格 的文字');
});

test('parseWeiboText with pangu: true formats plain text while protecting topics, mentions, URLs, and emojis', () => {
  const h = textHarness();
  const input = '在iPhone上发布了#小泽出去玩#话题，@钟文泽 感觉[微笑]体验很好https://weibo.com/test。';
  const tokens = h.parseWeiboText(input, { pangu: true });
  
  const topicToken = tokens.find(t => t.type === 'topic');
  assert.ok(topicToken);
  assert.equal(topicToken.text, '#小泽出去玩#');

  const mentionToken = tokens.find(t => t.type === 'mention');
  assert.ok(mentionToken);
  assert.equal(mentionToken.text, '@钟文泽');

  const linkToken = tokens.find(t => t.type === 'link');
  assert.ok(linkToken);
  assert.equal(linkToken.value, 'https://weibo.com/test');

  const textTokens = tokens.filter(t => t.type === 'text');
  assert.ok(textTokens.some(t => t.text.includes('在 iPhone 上')));
});

test('splitEditorialParagraphs respects explicit newlines and splits long continuous posts into comfortable paragraphs', () => {
  const h = textHarness();
  
  // Explicit newlines
  const explicit = h.splitEditorialParagraphs('第一段文字。\n\n第二段文字。\n第三段文字。');
  assert.deepEqual(Array.from(explicit), ['第一段文字。', '第二段文字。', '第三段文字。']);

  // Short post (< 100 chars) stays 1 paragraph
  const shortText = '这是一条简短的微博，没有复杂的长篇大论。';
  assert.deepEqual(Array.from(h.splitEditorialParagraphs(shortText)), [shortText]);

  // Real on-device Zhong Wenze continuous post
  const zwz = '我问我妈，今年要不要给她换一台 iPhone Duo。然后我把小米 18 Fold 拿给她，说尺寸大小跟这个差不多。我妈接过去感受了一下，说她还是喜欢 iPhone Air，不换 Duo 了。不得不说，iPhone Air 的体验满意度太高了，我身边好几个朋友都用 Air 评价非常好。我当时在 iPhone Air 上办了 eSIM，本想着评测之后就去营业厅换回实体卡，没想到这一用就是一年，到现在还天天高强度使用。手感带来的体验改善，要比很多功能升级还明显。';
  const paragraphs = Array.from(h.splitEditorialParagraphs(zwz, true));
  assert.ok(paragraphs.length >= 3, `Expected at least 3 paragraphs for long post, got ${paragraphs.length}`);
  assert.ok(paragraphs[0].includes('iPhone Duo。'));
  assert.ok(paragraphs[paragraphs.length - 1].includes('手感带来的体验改善'));
});

test('normalizeWeiboText preserves <br> and <p> linebreaks from server HTML', () => {
  const h = textHarness();
  const html = '第一行内容<br>第二行内容<br/>第三行内容<p>第四行内容</p>';
  const normalized = h.normalizeWeiboText(html);
  assert.ok(normalized.includes('\n'), 'HTML line breaks must be converted to newlines');
  const lines = normalized.split('\n').filter(Boolean);
  assert.equal(lines.length, 4);
});

test('WeiboRichTextView component supports paragraphSpacing, enablePanguSpacing, enableAutoRhythm', () => {
  const richViewSrc = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/components/WeiboRichTextView.ets'), 'utf-8');
  assert.ok(richViewSrc.includes('paragraphSpacing: number = 0'), 'Must expose paragraphSpacing prop');
  assert.ok(richViewSrc.includes('enablePanguSpacing: boolean = false'), 'Must expose enablePanguSpacing prop');
  assert.ok(richViewSrc.includes('enableAutoRhythm: boolean = false'), 'Must expose enableAutoRhythm prop');
  assert.ok(richViewSrc.includes('Column({ space: this.paragraphSpacing })'), 'Must render Column when paragraphSpacing > 0');
});

test('WeiboPostDetail applies Option A editorial typography to post body', () => {
  const detailSrc = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/pages/WeiboPostDetail.ets'), 'utf-8');
  assert.ok(detailSrc.includes('paragraphSpacing: 13'), 'Detail post body must use 13vp paragraph spacing');
  assert.ok(detailSrc.includes('enablePanguSpacing: true'), 'Detail post body must enable Pangu spacing');
  assert.ok(detailSrc.includes('enableAutoRhythm: true'), 'Detail post body must enable auto rhythm');
  assert.ok(detailSrc.includes('lineHeight: fs(29, this.fontScale)'), 'Detail post body must use 29vp golden leading');
  assert.ok(detailSrc.includes('fontSize: fs(16.5, this.fontScale)'), 'Detail post body must use 16.5vp font size');
});
