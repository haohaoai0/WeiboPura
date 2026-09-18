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

import { AuthManager } from '../service/AuthManager';
import { TiebaService } from '../service/TiebaService';
import { Theme, Spacing, Radius, isDarkMode, ImmBlur, ImmMaterial, MaterialManager, fs } from '../common/Theme';

@Entry
@Component
struct ComposeThread {
  @State forumName: string = '';
  @State forumId: string = '';
  @State title: string = '';
  @State content: string = '';
  @State publishing: boolean = false;
  @State pendingPublish: boolean = false;
  @State isDark: boolean = isDarkMode();
  @StorageLink('fontScale') fontScale: number = 1.0;
  /** 页面可见时自增，强制组件重建使字号实时生效 */
  @State fontSizeTick: number = 0;

  onPageShow(): void {
    this.fontSizeTick++;
  }

  aboutToAppear(): void {
    MaterialManager.init();
    const params = this.getUIContext().getRouter().getParams() as Record<string, string>;
    if (params?.kw) {
      this.forumName = `${params.kw}`;
    }
    if (params?.fid) {
      this.forumId = `${params.fid}`;
    }
    this.isDark = isDarkMode();
  }

  private async publish(): Promise<void> {
    if (!AuthManager.getInstance().isLogin()) {
      this.getUIContext().getPromptAction().showToast({ message: '请先登录贴吧账号' });
      return;
    }
    if (this.forumName.trim().length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: '缺少贴吧名称' });
      return;
    }
    if (this.title.trim().length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: '请输入主题标题' });
      return;
    }
    if (this.content.trim().length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: '请输入主题内容' });
      return;
    }
    if (!this.pendingPublish) {
      this.pendingPublish = true;
      this.getUIContext().getPromptAction().showToast({ message: '再次点击发布，确认提交主题' });
      return;
    }
    this.publishing = true;
    try {
      const result = await TiebaService.getInstance().publishThread(this.forumName, this.title, this.content, this.forumId);
      this.getUIContext().getPromptAction().showToast({ message: result.message });
      this.getUIContext().getRouter().back();
    } catch (e) {
      this.pendingPublish = false;
      this.getUIContext().getPromptAction().showToast({ message: (e as Error).message ?? '发帖失败' });
    } finally {
      this.publishing = false;
    }
  }

  build() {
    Column() {
      Row({ space: Spacing.sm }) {
        Button() {
          Row({ space: 3 }) {
            SymbolGlyph($r('sys.symbol.chevron_left')).fontColor([$r('sys.color.icon_primary')]).fontSize(fs(28, this.fontScale))
            Text('返回').fontSize(fs(13, this.fontScale)).fontColor($r('sys.color.font_primary'))
          }
        }
        .width(64)
        .height(44)
        .backgroundColor(Color.Transparent)
        .shadow(Theme.glassShadowStyle()).backgroundEffect(ImmBlur.control())
        .systemMaterial(ImmMaterial.control())
        .borderRadius(Radius.full)
        .onClick(() => this.getUIContext().getRouter().back())

        Text(`发布到 ${this.forumName}吧`)
          .fontSize(fs(18, this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.textPrimary(this.isDark))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .padding({ left: Spacing.lg, right: Spacing.lg, top: 44, bottom: 10 })
      .backgroundColor(Color.Transparent)

      Column({ space: Spacing.md }) {
        TextInput({ placeholder: '主题标题', text: this.title })
          .width('100%')
          .height(48)
          .fontSize(fs(16, this.fontScale))
          .fontColor(Theme.textPrimary(this.isDark))
          .backgroundColor(Theme.bgElevated(this.isDark))
          .borderRadius(Radius.md)
          .onChange((value: string) => {
            this.title = value;
            this.pendingPublish = false;
          })

        TextInput({ placeholder: '写下主题内容', text: this.content })
          .width('100%')
          .height(220)
          .fontSize(fs(15, this.fontScale))
          .fontColor(Theme.textPrimary(this.isDark))
          .backgroundColor(Theme.bgElevated(this.isDark))
          .borderRadius(Radius.md)
          .textAlign(TextAlign.Start)
          .onChange((value: string) => {
            this.content = value;
            this.pendingPublish = false;
          })

        Text('发布请求会携带当前登录 Cookie，并由贴吧服务端校验 tbs、权限和风控状态。')
          .fontSize(fs(12, this.fontScale))
          .fontColor(Theme.textSecondary(this.isDark))
          .width('100%')

        Button(this.publishing ? '发布中' : (this.pendingPublish ? '确认发布' : '发布主题'))
          .width('100%')
          .height(46)
          .fontSize(fs(15, this.fontScale))
          .fontColor(Color.White)
          .backgroundColor(this.pendingPublish ? Theme.success() : Theme.brand())
          .borderRadius(Radius.full)
          .enabled(!this.publishing)
          .onClick(() => this.publish())
      }
      .width('100%')
      .padding(Spacing.lg)
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg(this.isDark))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
