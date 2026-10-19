import { Theme } from '../common/Theme';
import { loadWeiboEmojiAssets } from '../common/WeiboText';
import { parseWeiboText, splitEditorialParagraphs, WeiboRichToken } from '../common/WeiboRichTokens';
import { common } from '@kit.AbilityKit';

@Component
export struct WeiboRichTextView {
  @Prop @Watch('onTextChange') text: string = '';
  @Prop fontSize: number = 15;
  @Prop fontColor: ResourceColor = '#E6000000';
  @Prop lineHeight: number = 22;
  @Prop maxLines: number = 0;
  @Prop paragraphSpacing: number = 0;
  @Prop enablePanguSpacing: boolean = false;
  @Prop enableAutoRhythm: boolean = false;
  @Consume('weiboNavStack') weiboNavStack: NavPathStack;
  onTopicClick: (topic: string) => void = () => {};
  onMentionClick: (username: string) => void = () => {};
  onLinkClick?: (url: string) => void;
  @State tokens: WeiboRichToken[] = [];
  @State paragraphs: WeiboRichToken[][] = [];

  aboutToAppear(): void {
    loadWeiboEmojiAssets(this.getUIContext().getHostContext() as common.UIAbilityContext);
    this.onTextChange();
  }

  private onTextChange(): void {
    if (this.paragraphSpacing > 0) {
      const rawParas: string[] = splitEditorialParagraphs(this.text, this.enableAutoRhythm);
      this.paragraphs = rawParas.map((p: string): WeiboRichToken[] =>
        parseWeiboText(p, { pangu: this.enablePanguSpacing })
      );
      this.tokens = this.paragraphs.length > 0 ? this.paragraphs[0] : [];
    } else {
      const singleTokens: WeiboRichToken[] = parseWeiboText(this.text, { pangu: this.enablePanguSpacing });
      this.tokens = singleTokens;
      this.paragraphs = [singleTokens];
    }
  }

  private openUrl(url: string): void {
    if (!/^https?:\/\//i.test(url)) { return; }
    if (this.onLinkClick !== undefined) {
      this.onLinkClick(url);
    } else {
      this.weiboNavStack.pushPathByName('WeiboBrowser', url);
    }
  }

  build() {
    if (this.paragraphSpacing > 0 && this.paragraphs.length > 1) {
      Column({ space: this.paragraphSpacing }) {
        ForEach(this.paragraphs, (paraTokens: WeiboRichToken[], pIdx: number): void => {
          Text() {
            ForEach(paraTokens, (token: WeiboRichToken, idx: number): void => {
              if (token.type === 'emoji' && token.emojiUrl !== undefined) {
                ImageSpan(token.emojiUrl).width(this.fontSize + 4).height(this.fontSize + 4)
                  .verticalAlign(ImageSpanAlignment.CENTER)
              } else if (token.type === 'topic') {
                Span(token.text).fontColor(Theme.brand()).fontWeight(FontWeight.Medium)
                  .onClick((): void => { this.onTopicClick(token.value ?? token.text); })
              } else if (token.type === 'mention') {
                Span(token.text).fontColor(Theme.brand()).fontWeight(FontWeight.Medium)
                  .onClick((): void => { this.onMentionClick(token.value ?? token.text); })
              } else if (token.type === 'link') {
                Span(' 网页链接 ↗ ').fontColor(Theme.brand())
                  .onClick((): void => { this.openUrl(token.value ?? token.text); })
              } else {
                Span(token.text).fontColor(this.fontColor)
              }
            }, (token: WeiboRichToken, idx: number): string => `${pIdx}_${idx}_${token.text}`)
          }
          .fontSize(this.fontSize)
          .fontColor(this.fontColor)
          .lineHeight(this.lineHeight)
          .width('100%')
        }, (_tokens: WeiboRichToken[], pIdx: number): string => `${pIdx}`)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    } else {
      Text() {
        ForEach(this.tokens, (token: WeiboRichToken, idx: number): void => {
          if (token.type === 'emoji' && token.emojiUrl !== undefined) {
            ImageSpan(token.emojiUrl).width(this.fontSize + 4).height(this.fontSize + 4)
              .verticalAlign(ImageSpanAlignment.CENTER)
          } else if (token.type === 'topic') {
            Span(token.text).fontColor(Theme.brand()).fontWeight(FontWeight.Medium)
              .onClick((): void => { this.onTopicClick(token.value ?? token.text); })
          } else if (token.type === 'mention') {
            Span(token.text).fontColor(Theme.brand()).fontWeight(FontWeight.Medium)
              .onClick((): void => { this.onMentionClick(token.value ?? token.text); })
          } else if (token.type === 'link') {
            Span(' 网页链接 ↗ ').fontColor(Theme.brand())
              .onClick((): void => { this.openUrl(token.value ?? token.text); })
          } else {
            Span(token.text).fontColor(this.fontColor)
          }
        }, (token: WeiboRichToken, idx: number): string => `${idx}_${token.text}`)
      }
      .fontSize(this.fontSize)
      .fontColor(this.fontColor)
      .lineHeight(this.lineHeight)
      .maxLines(this.maxLines > 0 ? this.maxLines : undefined)
      .textOverflow(this.maxLines > 0 ? { overflow: TextOverflow.Ellipsis } : undefined)
      .width('100%')
    }
  }
}
