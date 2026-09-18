/*
 * TiebaPura - HarmonyOS 原生 ArkTS 实现的第三方百度贴吧客户端
 * Copyright (C) 2026 a307608689-afk
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

import { webview } from '@kit.ArkWeb';
import { BusinessError } from '@kit.BasicServicesKit';
import { AuthManager } from '../service/AuthManager';
import { TiebaService } from '../service/TiebaService';
import { UserInfo } from '../model/DataModel';
import { Theme, Spacing, Radius, isDarkMode, ImmBlur, ImmMaterial, MaterialManager, fs } from '../common/Theme';

// u 参数指定登录成功后跳转贴吧首页：passport 会在 302 的 URL 中携带 stoken 并种下 tieba 域 STOKEN cookie，
// 这是收藏/关注等写接口必需的凭证。不带 u 时登录可能停留在 passport 域，导致 STOKEN 缺失。
const LOGIN_URL: string =
  'https://wappass.baidu.com/passport/?login&u=https%3A%2F%2Ftieba.baidu.com%2F';
const TIEBA_URL: string = 'https://tieba.baidu.com/';

@Entry
@Component
struct Login {
  @State loading: boolean = false;
  @State isDark: boolean = isDarkMode();
  @State loginReady: boolean = false;
  @State webError: string = '';
  @StorageLink('fontScale') fontScale: number = 1.0;
  /** 页面可见时自增，强制组件重建使字号实时生效 */
  @State fontSizeTick: number = 0;

  onPageShow(): void {
    this.fontSizeTick++;
  }
  private controller: webview.WebviewController = new webview.WebviewController();
  private currentUrl: string = LOGIN_URL;
  private cookieCheckInFlight: boolean = false;
  /** 正在跳贴吧首页种 STOKEN 时，跳过 onPageEnd 触发的自动登录，防止循环 */
  private harvestingStoken: boolean = false;

  aboutToAppear(): void {
    MaterialManager.init();
    this.isDark = isDarkMode();
    try {
      webview.WebCookieManager.setLazyInitializeWebEngine(true);
    } catch (e) {
      // Web 引擎已初始化时无需重复设置。
    }
  }

  private async fetchCookieString(): Promise<string> {
    const cookies = await webview.WebCookieManager.fetchAllCookies(false);
    // STOKEN 存在域差异：passport.baidu.com 与 tieba.baidu.com 的 STOKEN 值不同，
    // 贴吧 API 只认 tieba 域的 STOKEN。把 tieba 域 Cookie 排在最前，
    // 保证后续 readCookieValue 正则取到的是 tieba 域的 STOKEN/BDUSS
    const tiebaParts: string[] = [];
    const otherParts: string[] = [];
    for (const item of cookies) {
      const part = `${item.name}=${item.value}`;
      const domain = `${item.domain ?? ''}`;
      if (domain.includes('tieba.baidu.com')) {
        tiebaParts.push(part);
      } else {
        otherParts.push(part);
      }
    }
    return [...tiebaParts, ...otherParts].join('; ');
  }

  /** 访问贴吧首页触发 tieba 域 STOKEN 下发后读取 Cookie
   * 根因：登录页在 wappass.baidu.com（passport 域）完成登录，BDUSS 检测到就返回的话，
   * WebView 从未访问 tieba.baidu.com，tieba 域 STOKEN（收藏等写接口必需）从未被种下。
   * 修复：登录成功后先导航到贴吧首页，等待页面加载完成种下 tieba 域 Cookie 再读取。
   */
  private async harvestTiebaStokenThenFinish(): Promise<void> {
    if (this.harvestingStoken) {
      return;
    }
    this.harvestingStoken = true;
    this.loading = true;
    this.webError = '';
    try {
      // 1. 导航到贴吧首页（触发 302 链种 tieba 域 STOKEN）
      this.currentUrl = TIEBA_URL;
      this.controller.loadUrl(TIEBA_URL);
      // 2. 等待页面加载（最多 8 秒，每 500ms 检查一次）
      let stokenReady = false;
      for (let i = 0; i < 16; i++) {
        await new Promise<void>((resolve) => setTimeout(resolve, 500));
        try {
          const cookie = await this.fetchCookieString();
          if (cookie.includes('STOKEN=')) {
            stokenReady = true;
            break;
          }
        } catch (e) {
          // 轮询中读取失败继续等待
        }
      }
      // 3. 读取最终 Cookie（无论 STOKEN 是否就绪，BDUSS 已确认）
      const finalCookie = await this.fetchCookieString();
      console.info(`[登录] tieba 域 STOKEN ${stokenReady ? '已获取' : '未检测到（8秒超时）'}，Cookie 长度 ${finalCookie.length}`);
      await this.finishLogin(finalCookie);
    } catch (error) {
      // 贴吧首页导航失败时仍用当前 Cookie 完成登录（BDUSS 可用，仅收藏受限）
      try {
        const fallbackCookie = await this.fetchCookieString();
        if (fallbackCookie.includes('BDUSS=')) {
          await this.finishLogin(fallbackCookie);
          return;
        }
      } catch (e2) {
      }
      const err = error as BusinessError;
      this.webError = err.message ?? '读取登录态失败，请稍后重试。';
    } finally {
      this.loading = false;
      this.harvestingStoken = false;
    }
  }

  private async tryReadCookieAfterVisible(): Promise<void> {
    if (this.cookieCheckInFlight || this.loading || !this.loginReady || this.harvestingStoken) {
      return;
    }
    this.cookieCheckInFlight = true;
    try {
      const cookie = await this.fetchCookieString();
      if (cookie.includes('BDUSS=')) {
        // 检测到登录态：先跳贴吧首页种 STOKEN 再完成登录
        await this.harvestTiebaStokenThenFinish();
      }
    } catch (e) {
      // 安全验证过程中的 Cookie 读取失败不覆盖页面，等待用户点击完成登录。
    } finally {
      this.cookieCheckInFlight = false;
    }
  }

  private async readLoginCookie(): Promise<void> {
    this.loading = true;
    this.webError = '';
    try {
      const cookie = await this.fetchCookieString();
      if (!cookie.includes('BDUSS=')) {
        this.webError = '还没有检测到贴吧登录态，请先在页面中完成百度账号登录。';
        return;
      }
      // 手动确认登录：同样先跳贴吧首页种 STOKEN
      await this.harvestTiebaStokenThenFinish();
    } catch (error) {
      const err = error as BusinessError;
      this.webError = err.message ?? '读取登录态失败，请稍后重试。';
    } finally {
      this.loading = false;
    }
  }

  private handleWebPageEnd(url: string): void {
    this.loginReady = true;
    this.webError = '';
    // 安全验证可能在 onPageEnd 后仍需一次渲染切换，延迟读取避免误判中间态。
    setTimeout(() => {
      this.tryReadCookieAfterVisible();
    }, 300);
  }

  private reloadLoginPage(): void {
    this.loginReady = false;
    this.webError = '';
    this.controller.loadUrl(this.currentUrl.length > 0 ? this.currentUrl : LOGIN_URL);
  }

  private async finishLogin(cookie: string): Promise<void> {
    try {
      await AuthManager.getInstance().setCookie(cookie);
      TiebaService.getInstance().invalidateStokenCache();
      const user = await TiebaService.getInstance().fetchUserInfo();
      // 贴吧网页结构可能因地区、风控或登录页版本变化而不同。
      // BDUSS 已由系统 Cookie 管理器确认时，不再把"用户信息解析失败"误判成登录失败。
      const info: UserInfo = {
        userId: user?.userId ?? '',
        name: user?.name ?? '贴吧用户',
        avatar: user?.avatar ?? '',
        isLogin: true,
      };
      await AuthManager.getInstance().setUserInfo(info);
      this.getUIContext().getPromptAction().showToast({ message: user ? `登录成功：${user.name}` : '登录成功' });
      this.getUIContext().getRouter().back();
    } catch (e) {
      this.webError = '网络校验失败，请检查网络后重试。';
    } finally {
      this.loading = false;
    }
  }

  private clearWebSession(): void {
    try {
      webview.WebCookieManager.clearAllCookiesSync();
      this.controller.clearHistory();
      this.currentUrl = LOGIN_URL;
      this.reloadLoginPage();
    } catch (e) {
      this.webError = '无法清理网页登录态，请稍后重试。';
    }
  }

  build() {
    Column() {
      Row() {
        Row() {
          Button() {
            Row({ space: 4 }) {
              SymbolGlyph($r('sys.symbol.chevron_left')).fontColor([$r('sys.color.icon_primary')]).fontSize(fs(28, this.fontScale))
              Text('返回')
                .fontSize(fs(13, this.fontScale))
                .fontColor($r('sys.color.font_primary'))
            }
          }
          .width(72)
          .height(48)
          .backgroundColor(Color.Transparent)
          .shadow(Theme.glassShadowStyle()).backgroundEffect(ImmBlur.control())
          .systemMaterial(ImmMaterial.control())
          .borderRadius(Radius.full)
          .zIndex(10)
          .hitTestBehavior(HitTestMode.Default)
          .onClick(() => {
            this.getUIContext().getRouter().back();
          })
        }
        .width(72)

        Column({ space: 2 }) {
          Text('登录贴吧')
            .fontSize(fs(18, this.fontScale))
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.textPrimary(this.isDark))
          Text('在应用内完成百度账号登录')
            .fontSize(fs(11, this.fontScale))
            .fontColor(Theme.textSecondary(this.isDark))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Center)

        Row() {
          Button('清除')
            .fontSize(fs(12, this.fontScale))
            .fontColor($r('sys.color.font_secondary'))
            .width(44)
            .height(44)
            .backgroundColor(Color.Transparent)
            .shadow(Theme.glassShadowStyle()).backgroundEffect(ImmBlur.control())
            .systemMaterial(ImmMaterial.control())
            .borderRadius(Radius.full)
            .onClick(() => this.clearWebSession())
        }
        .width(72)
        .justifyContent(FlexAlign.End)
      }
      .width('100%')
      .padding({ left: Spacing.lg, right: Spacing.lg, top: 44, bottom: 10 })
      .backgroundColor(Color.Transparent)
      .zIndex(10)

      Row({ space: 8 }) {
        Text('①')
          .fontSize(fs(15, this.fontScale))
          .fontColor(Theme.brand())
        Text('在下方页面完成百度账号登录')
          .fontSize(fs(13, this.fontScale))
          .fontColor(Theme.textSecondary(this.isDark))
        Blank()
        Text('安全登录')
          .fontSize(fs(12, this.fontScale))
          .fontColor(Theme.success())
      }
      .width('100%')
      .padding({ left: Spacing.lg, right: Spacing.lg, bottom: 8 })

      Web({ src: LOGIN_URL, controller: this.controller })
        .width('100%')
        .layoutWeight(1)
        .zIndex(0)
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .imageAccess(true)
        .onlineImageAccess(true)
        .onControllerAttached(() => {
          const mobileUA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1';
          this.controller.setCustomUserAgent(`${mobileUA} TiebaPura/1.0`);
        })
        .onPageBegin((event) => {
          this.loginReady = false;
          this.currentUrl = event.url;
          this.webError = '';
        })
        .onPageVisible((event) => {
          this.loginReady = true;
          this.currentUrl = event.url;
          this.tryReadCookieAfterVisible();
        })
        .onPageEnd((event) => {
          this.handleWebPageEnd(event.url);
        })
        .onErrorReceive((event) => {
          this.loginReady = false;
          this.webError = `登录页加载失败（${event.error.getErrorCode()}），请点击重试。`;
        })
        .onHttpErrorReceive((event) => {
          if (event.request.isMainFrame()) {
            this.loginReady = false;
            this.webError = `登录页返回 HTTP ${event.response.getResponseCode()}，请点击重试。`;
          }
        })
        .onRenderExited(() => {
          this.loginReady = false;
          this.webError = '登录页面渲染进程已退出，请点击重试。';
        })

      if (this.webError.length > 0) {
        Row({ space: 8 }) {
          Text(this.webError)
            .fontSize(fs(12, this.fontScale))
            .fontColor(Theme.danger())
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
          Button('重试')
            .fontSize(fs(12, this.fontScale))
            .fontColor(Theme.brand())
            .backgroundColor(Color.Transparent)
            .onClick(() => this.reloadLoginPage())
        }
        .width('100%')
        .padding({ left: Spacing.lg, right: Spacing.lg, top: 6, bottom: 6 })
      }

      Button(this.loading ? '正在读取登录态…' : '完成登录')
        .width('calc(100% - 32vp)')
        .height(46)
        .fontSize(fs(15, this.fontScale))
        .fontColor(Color.White)
        .backgroundColor(Theme.brand())
        .borderRadius(Radius.full)
        .enabled(!this.loading)
        .margin({ bottom: 14 })
        .onClick(() => this.readLoginCookie())

      Text('登录凭证只保存在本应用沙箱内，用于贴吧网页请求。')
        .fontSize(fs(11, this.fontScale))
        .fontColor(Theme.textTertiary(this.isDark))
        .margin({ bottom: 12 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg(this.isDark))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .zIndex(1)
  }
}

