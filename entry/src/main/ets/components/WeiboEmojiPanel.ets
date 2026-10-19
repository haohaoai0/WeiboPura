import { common } from '@kit.AbilityKit';
import { getWeiboEmoji, getWeiboEmojiNames, loadWeiboEmojiAssets } from '../common/WeiboText';
import { Theme, isDarkMode, Radius } from '../common/Theme';

@Component
export struct WeiboEmojiPanel {
  onSelect: (name: string) => void = () => {};
  @State names: string[] = [];
  @State isDark: boolean = isDarkMode();

  aboutToAppear(): void {
    loadWeiboEmojiAssets(this.getUIContext().getHostContext() as common.UIAbilityContext);
    this.names = getWeiboEmojiNames();
  }

  build() {
    Column({ space: 4 }) {
      Text('微博表情').fontSize(14).fontColor(Theme.textSecondary(this.isDark)).padding(8)
      Grid() {
        ForEach(this.names, (name: string): void => {
          GridItem() {
            Button() {
              Image(getWeiboEmoji(name) ?? '').width(28).height(28).objectFit(ImageFit.Contain)
            }.width(44).height(44).backgroundColor(Color.Transparent)
              .accessibilityText(`[${name}]`).onClick((): void => { this.onSelect(name); })
          }
        }, (name: string): string => name)
      }.columnsTemplate('1fr 1fr 1fr 1fr 1fr 1fr').rowsGap(4).height(220).width('100%')
    }.width('100%').padding(8).backgroundColor(Theme.bgCard(this.isDark)).borderRadius(Radius.md)
  }
}
