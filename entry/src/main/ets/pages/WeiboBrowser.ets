import { webview } from '@kit.ArkWeb';
import { HdsNavDestination } from '@kit.UIDesignKit';
import { Theme, isDarkMode } from '../common/Theme';
import { syncWeiboSplitNavigation } from '../common/WeiboNavigationLayout';

@Builder
export function WeiboBrowserBuilder(): void { WeiboBrowser() }

@Component
export struct WeiboBrowser {
  @Consume('weiboNavStack') weiboNavStack: NavPathStack;
  @State url: string = '';
  @State loading: boolean = true;
  @State title: string = '网页';
  @State errorMessage: string = '';
  private controller: webview.WebviewController = new webview.WebviewController();

  aboutToAppear(): void {
    const params: string[] = this.weiboNavStack.getParamByName('WeiboBrowser') as string[];
    const value: string = params !== undefined && params.length > 0 ? params[params.length - 1] : '';
    if (/^https?:\/\//i.test(value)) { this.url = value; }
  }

  private goBack(): boolean {
    try { if (this.url.length > 0 && this.controller.accessBackward()) { this.controller.backward(); return true; } } catch (_error) {}
    return false;
  }

  private refresh(): void {
    if (this.url.length === 0) { return; }
    try { this.errorMessage = ''; this.loading = true; this.controller.refresh(); }
    catch (_error) { this.loading = false; this.errorMessage = '网页刷新失败，请返回重试'; }
  }

  private popRoute(): void {
    this.weiboNavStack.pop();
    syncWeiboSplitNavigation(this.weiboNavStack);
  }

  @Builder
  BrowserTitle() {
    Row({ space: 12 }) {
      Button('‹').height(44).width(44).backgroundColor(Color.Transparent).accessibilityText('网页后退')
        .onClick((): void => { if (!this.goBack()) { this.popRoute(); } })
      Text(this.title).layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      Button('刷新').height(44).backgroundColor(Color.Transparent).enabled(this.url.length > 0)
        .onClick((): void => { this.refresh(); })
      Button('关闭').height(44).backgroundColor(Color.Transparent)
        .onClick((): void => { this.popRoute(); })
    }.width('100%').padding({ left: 12, right: 12 })
  }

  build() {
    HdsNavDestination() {
      Stack({ alignContent: Alignment.Top }) {
        if (this.url.length > 0) {
          Column() {
            if (this.errorMessage.length > 0) {
              Text(this.errorMessage).fontColor(Theme.danger()).padding(12)
            }
            Web({ src: this.url, controller: this.controller, incognitoMode: true })
              .javaScriptAccess(true).domStorageAccess(true).fileAccess(false)
              .mixedMode(MixedMode.None).layoutWeight(1).width('100%')
              .onPageBegin((): void => { this.loading = true; this.errorMessage = ''; })
              .onPageEnd((): void => { this.loading = false; })
              .onErrorReceive((event): void => {
                if (event !== undefined && event.request.isMainFrame()) { this.loading = false; this.errorMessage = '网页加载失败，请检查网络或点击刷新'; }
              })
              .onTitleReceive((event): void => { if (event !== undefined) { this.title = event.title; } })
              .onOverrideUrlLoading((request): boolean => !/^https?:\/\//i.test(request.getRequestUrl()))
          }
          .width('100%')
          .height('100%')

          if (this.loading) {
            LoadingProgress()
              .width(28)
              .height(28)
              .color(Theme.brand())
              .margin({ top: 12 })
          }
        } else {
          Text('不支持的链接').fontColor(Theme.textSecondary(isDarkMode()))
            .margin({ top: 40 })
        }
      }.width('100%').height('100%').backgroundColor(Theme.bg(isDarkMode()))
    }.hideBackButton(true)
      .titleBar({ content: { stackBuilder: (): void => this.BrowserTitle() } })
      .onBackPressed((): boolean => {
        if (this.goBack()) {
          return true;
        }
        this.popRoute();
        return true;
      })
  }
}
