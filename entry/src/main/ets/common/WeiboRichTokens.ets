import { getWeiboEmoji } from './WeiboText';

export interface WeiboRichToken {
  type: 'text' | 'topic' | 'mention' | 'link' | 'emoji';
  text: string;
  value?: string;
  emojiUrl?: string;
}

export interface ParseWeiboTextOptions {
  pangu?: boolean;
}

/** Inserts a breathing micro-space between CJK characters and Latin/Digits (Pangu spacing). */
export function applyPanguSpacing(input: string): string {
  if (!input) {
    return '';
  }
  let result: string = input.replace(/([\u4e00-\u9fa5])([a-zA-Z0-9])/g, '$1 $2');
  result = result.replace(/([a-zA-Z0-9])([\u4e00-\u9fa5])/g, '$1 $2');
  result = result.replace(/ {2,}/g, ' ');
  return result;
}

/** Splits long text into rhythmic, comfortable paragraphs for modern editorial typography. */
export function splitEditorialParagraphs(input: string, enableAutoRhythm: boolean = true): string[] {
  const trimmed: string = input.trim();
  if (trimmed.length === 0) {
    return [];
  }
  if (trimmed.includes('\n')) {
    const rawParagraphs: string[] = trimmed
      .split(/\r?\n+/)
      .map((p: string): string => p.trim())
      .filter((p: string): boolean => p.length > 0);
    if (rawParagraphs.length > 1 || !enableAutoRhythm) {
      return rawParagraphs;
    }
  }
  if (!enableAutoRhythm || trimmed.length < 100) {
    return [trimmed];
  }
  const sentences: string[] = [];
  const regex: RegExp = /[^。！？!?]+[。！？!?]["”']?/g;
  let lastIndex: number = 0;
  let match: RegExpExecArray | null = regex.exec(trimmed);
  while (match !== null) {
    sentences.push(match[0].trim());
    lastIndex = regex.lastIndex;
    match = regex.exec(trimmed);
  }
  if (lastIndex < trimmed.length) {
    const remainder: string = trimmed.substring(lastIndex).trim();
    if (remainder.length > 0) {
      sentences.push(remainder);
    }
  }
  if (sentences.length <= 2) {
    return [trimmed];
  }
  const paragraphs: string[] = [];
  let current: string = '';
  for (let i: number = 0; i < sentences.length; i++) {
    const s: string = sentences[i];
    current += s;
    const nextSentence: string | undefined = sentences[i + 1];
    const isConclusion: boolean = i === sentences.length - 2 && nextSentence !== undefined && nextSentence.length <= 35;
    if (i === sentences.length - 1) {
      paragraphs.push(current);
      current = '';
    } else if (current.length >= 45 || isConclusion) {
      paragraphs.push(current);
      current = '';
    }
  }
  if (current.length > 0) {
    paragraphs.push(current);
  }
  return paragraphs;
}

/** Parse normalized plain text, never execute server HTML. */
export function parseWeiboText(input: string, options?: ParseWeiboTextOptions): WeiboRichToken[] {
  const pattern: RegExp = /(#[^#\n\r]+#)|(@[a-zA-Z0-9_\u4e00-\u9fa5-]+)|(https?:\/\/[^\s<>"'\u4e00-\u9fa5，。！？；、（）【】]+)|(\[[^\]\n]+\])/g;
  const tokens: WeiboRichToken[] = [];
  let lastIndex: number = 0;
  let match: RegExpExecArray | null = pattern.exec(input);
  const pangu: boolean = options?.pangu ?? false;

  while (match !== null) {
    if (match.index > lastIndex) {
      let rawText: string = input.substring(lastIndex, match.index);
      if (pangu) {
        rawText = applyPanguSpacing(rawText);
      }
      tokens.push({ type: 'text', text: rawText });
    }
    let text: string = match[0];
    let consumed: number = text.length;
    if (text.startsWith('#')) {
      tokens.push({ type: 'topic', text: text, value: text.substring(1, text.length - 1) });
    } else if (text.startsWith('@')) {
      tokens.push({ type: 'mention', text: text, value: text.substring(1) });
    } else if (/^https?:/.test(text)) {
      // Sentence punctuation is not part of a URL. Keep it in the next text span.
      text = text.replace(/[.,!?;:]+$/, '');
      consumed = text.length;
      tokens.push({ type: 'link', text: text, value: text });
    } else {
      const name: string = text.substring(1, text.length - 1);
      const url: string | undefined = getWeiboEmoji(name);
      tokens.push({ type: url === undefined ? 'text' : 'emoji', text: text, value: name, emojiUrl: url });
    }
    lastIndex = match.index + consumed;
    pattern.lastIndex = lastIndex;
    match = pattern.exec(input);
  }
  if (lastIndex < input.length) {
    let rawText: string = input.substring(lastIndex);
    if (pangu) {
      rawText = applyPanguSpacing(rawText);
    }
    tokens.push({ type: 'text', text: rawText });
  }
  return tokens;
}
