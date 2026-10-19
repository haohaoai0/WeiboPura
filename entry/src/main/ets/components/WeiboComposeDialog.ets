import { ImmBlur, ImmMaterial, Radius, Spacing, Theme, fs, isDarkMode } from '../common/Theme';
import { WeiboPost, WeiboUser } from '../model/WeiboModel';
import { WeiboService } from '../service/WeiboService';
import { WeiboAuthManager } from '../service/WeiboAuthManager';
import { WeiboDraftManager } from '../service/WeiboDraftManager';
import { Haptic } from '../common/Haptic';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { WeiboEmojiPanel } from './WeiboEmojiPanel';

@CustomDialog
export struct WeiboComposeDialog {
  controller: CustomDialogController;
  mode: 'publish' | 'repost' = 'publish';
  targetPost: WeiboPost | null = null;
  onSuccess: () => void = () => {};

  @State isDark: boolean = isDarkMode();
  @State content: string = '';
  @State dualComment: boolean = false;
  @State submitting: boolean = false;
  @State selectedImages: string[] = [];
  @State pickingImages: boolean = false;
  @State uploadHint: string = '';
  @State showEmoji: boolean = false;
  private uploadedIds: Map<string, string> = new Map();
  private uploadRevision: number = -1;
  @StorageLink('fontScale') fontScale: number = 1.0;

  private currentAccountKey(): string {
    if (WeiboAuthManager.getInstance().hasCookie()) {
      const user: WeiboUser | null = WeiboService.getInstance().getCachedCurrentUser();
      if (user !== null && user.id.length > 0) {
        return user.id;
      }
      const targetId: string = WeiboAuthManager.getInstance().getTargetUserId();
      return targetId.length > 0 ? targetId : 'logged_in';
    }
    return 'guest';
  }

  private currentDraftId(): string {
    return this.mode === 'publish' ? 'publish' : (`repost_${this.targetPost?.id ?? 'unknown'}`);
  }

  private autoSaveDraft(): void {
    const accountKey: string = this.currentAccountKey();
    const draftId: string = this.currentDraftId();
    if (this.content.trim().length === 0 && this.selectedImages.length === 0) {
      WeiboDraftManager.getInstance().deleteDraft(accountKey, draftId);
      return;
    }
    WeiboDraftManager.getInstance().saveDraft({
      id: draftId,
      type: this.mode,
      accountKey: accountKey,
      text: this.content,
      images: this.selectedImages,
      targetPostId: this.targetPost?.id,
      dualComment: this.dualComment,
      updatedAt: Date.now()
    });
  }

  async aboutToAppear(): Promise<void> {
    const accountKey: string = this.currentAccountKey();
    const draftId: string = this.currentDraftId();
    const draft = await WeiboDraftManager.getInstance().getDraft(accountKey, draftId);
    if (draft !== null && this.content.trim().length === 0) {
      this.content = draft.text;
      if (draft.images && draft.images.length > 0 && this.selectedImages.length === 0) {
        this.selectedImages = draft.images;
      }
      if (draft.dualComment !== undefined) {
        this.dualComment = draft.dualComment;
      }
    }
  }

  private async selectImages(): Promise<void> {
    if (this.submitting || this.pickingImages || this.selectedImages.length >= 9) { return; }
    this.pickingImages = true;
    try {
      const picker: photoAccessHelper.PhotoViewPicker = new photoAccessHelper.PhotoViewPicker();
      const result: photoAccessHelper.PhotoSelectResult = await picker.select({
        MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE,
        maxSelectNumber: 9 - this.selectedImages.length
      });
      const next: string[] = this.selectedImages.slice();
      for (const uri of result.photoUris) { if (!next.includes(uri)) { next.push(uri); } }
      this.selectedImages = next.slice(0, 9);
      this.autoSaveDraft();
    } catch (_error) {
      this.getUIContext().getPromptAction().showToast({ message: '选图未完成，请重试' });
    } finally { this.pickingImages = false; }
  }

  private insertTopic(): void {
    this.content += '#输入话题# ';
  }

  private insertEmoji(code: string): void {
    this.content += `[${code}]`;
  }

  private async submit(): Promise<void> {
    if (this.submitting) {
      return;
    }
    if (!WeiboAuthManager.getInstance().hasCookie()) {
      this.getUIContext().getPromptAction().showToast({ message: '请先登录微博账号' });
      return;
    }
    const auth: WeiboAuthManager = WeiboAuthManager.getInstance();
    const revision: number = auth.getSessionRevision();
    const clean: string = this.content.trim();
    if (this.mode === 'publish' && clean.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: '请输入微博内容' });
      return;
    }

    this.submitting = true;
    Haptic.light();
    try {
      if (this.mode === 'repost' && this.targetPost !== null) {
        await WeiboService.getInstance().repostPost(this.targetPost.id, clean, this.dualComment);
        auth.assertSession(revision);
        this.getUIContext().getPromptAction().showToast({ message: '转发成功' });
      } else {
        const service: WeiboService = WeiboService.getInstance();
        if (revision !== this.uploadRevision) { this.uploadedIds.clear(); this.uploadRevision = revision; }
        const pictureIds: string[] = [];
        for (let index: number = 0; index < this.selectedImages.length; index++) {
          const uri: string = this.selectedImages[index];
          this.uploadHint = `正在上传图片 ${index + 1}/${this.selectedImages.length}`;
          let id: string | undefined = this.uploadedIds.get(uri);
          auth.assertSession(revision);
          if (id === undefined) {
            id = await service.uploadPicture(uri);
            auth.assertSession(revision);
            this.uploadedIds.set(uri, id);
          }
          pictureIds.push(id);
        }
        this.uploadHint = '正在发布…';
        auth.assertSession(revision);
        await service.publishPost(clean, pictureIds);
        auth.assertSession(revision);
        this.getUIContext().getPromptAction().showToast({ message: '微博发布成功' });
      }
      const accountKey: string = this.currentAccountKey();
      await WeiboDraftManager.getInstance().deleteDraft(accountKey, this.currentDraftId());
      this.onSuccess();
      this.controller.close();
    } catch (e) {
      const msg: string = (e as Error).message ?? '发布失败，请重试';
      this.getUIContext().getPromptAction().showToast({ message: msg });
    } finally {
      this.submitting = false;
      this.uploadHint = '';
    }
  }

  private handleClose(): void {
    if (this.submitting) {
      return;
    }
    if (this.content.trim().length > 0 || this.selectedImages.length > 0) {
      this.getUIContext().showAlertDialog({
        title: '提示',
        message: '当前有未发布的微博内容，是否退出？',
        primaryButton: {
          value: '保存草稿',
          action: (): void => {
            this.autoSaveDraft();
            this.controller.close();
          }
        },
        secondaryButton: {
          value: '放弃内容',
          fontColor: Theme.danger(),
          action: (): void => {
            const accountKey: string = this.currentAccountKey();
            WeiboDraftManager.getInstance().deleteDraft(accountKey, this.currentDraftId());
            this.content = '';
            this.selectedImages = [];
            this.controller.close();
          }
        }
      });
      return;
    }
    this.controller.close();
  }

  build() {
    Scroll() {
    Column({ space: Spacing.md }) {
      // 顶栏：标题与关闭按钮
      Row() {
        Text(this.mode === 'repost' ? '转发微博' : '发微博')
          .fontSize(fs(18, this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.textPrimary(this.isDark))
          .layoutWeight(1)

        Button() {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(fs(16, this.fontScale))
            .fontColor([Theme.textSecondary(this.isDark)])
        }
        .width(44)
        .height(44)
        .backgroundColor(Color.Transparent)
        .enabled(!this.submitting)
        .onClick((): void => {
          this.handleClose();
        })
      }
      .width('100%')

      // 原微博引用卡片（如果是转发模式）
      if (this.mode === 'repost' && this.targetPost !== null) {
        Column({ space: 4 }) {
          Text(`@${this.targetPost.userName}：${this.targetPost.text}`)
            .fontSize(fs(13, this.fontScale))
            .fontColor(Theme.textSecondary(this.isDark))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        .width('100%')
        .padding(10)
        .backgroundColor(this.isDark ? '#14FFFFFF' : '#08000000')
        .borderRadius(Radius.md)
      }

      // 文本输入区
      TextArea({
        text: this.content,
        placeholder: this.mode === 'repost' ? '说说分享的心得…（选填）' : '分享新鲜事…'
      })
        .height(130)
        .width('100%')
        .fontSize(fs(15, this.fontScale))
        .fontColor(Theme.textPrimary(this.isDark))
        .placeholderColor(Theme.textSecondary(this.isDark))
        .backgroundColor(this.isDark ? '#1AFFFFFF' : '#0A000000')
        .borderRadius(Radius.md)
        .padding(Spacing.sm)
        .enabled(!this.submitting)
        .onChange((val: string): void => {
          this.content = val;
          this.autoSaveDraft();
        })

      if (this.mode === 'publish') {
        Row({ space: 8 }) {
          Button(this.pickingImages ? '正在选图…' : `添加图片 ${this.selectedImages.length}/9`)
            .height(44).backgroundColor(Theme.brandBg(this.isDark)).fontColor(Theme.brand())
            .enabled(!this.submitting && !this.pickingImages && this.selectedImages.length < 9)
            .onClick((): void => { this.selectImages(); })
          Text('仅上传你选择的图片').fontSize(fs(12, this.fontScale)).fontColor(Theme.textSecondary(this.isDark))
        }.width('100%')
        if (this.selectedImages.length > 0) {
          Scroll() {
            Row({ space: 8 }) {
              ForEach(this.selectedImages, (uri: string, index: number): void => {
                Stack({ alignContent: Alignment.TopEnd }) {
                  Image(uri).width(76).height(76).objectFit(ImageFit.Cover).borderRadius(Radius.md)
                  Button('×').width(44).height(44).backgroundColor('#99000000').fontColor(Color.White)
                    .accessibilityText(`移除第 ${index + 1} 张图片`).enabled(!this.submitting)
                    .onClick((): void => { this.selectedImages = this.selectedImages.filter((item: string): boolean => item !== uri); })
                }
              }, (uri: string): string => uri)
            }
          }.width('100%').height(80).scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
        }
      }

      // 快捷工具栏（插入话题、经典表情、字数统计）
      Row({ space: Spacing.sm }) {
        Button() {
          Text('# 话题')
            .fontSize(fs(13, this.fontScale))
            .fontColor(Theme.brand())
        }
        .backgroundColor(Theme.brandBg(this.isDark))
        .borderRadius(Radius.full)
        .height(44)
        .enabled(!this.submitting)
        .padding({ left: 10, right: 10 })
        .onClick((): void => { this.insertTopic(); })

        Button('表情').height(44).fontColor(Theme.brand()).backgroundColor(Theme.brandBg(this.isDark))
          .enabled(!this.submitting).onClick((): void => { this.showEmoji = !this.showEmoji; })

        Blank()

        Text(`${this.content.length}`)
          .fontSize(fs(12, this.fontScale))
          .fontColor(Theme.textTertiary(this.isDark))
      }
      .width('100%')

      if (this.showEmoji) {
        WeiboEmojiPanel({ onSelect: (name: string): void => { this.insertEmoji(name); this.showEmoji = false; } })
      }

      // 转发模式下的附加选项（同时评论）
      if (this.mode === 'repost') {
        Row({ space: Spacing.xs }) {
          Checkbox()
            .enabled(!this.submitting)
            .select(this.dualComment)
            .selectedColor(Theme.brand())
            .onChange((val: boolean): void => {
              this.dualComment = val;
            })
          Text('同时评论')
            .fontSize(fs(13, this.fontScale))
            .fontColor(Theme.textSecondary(this.isDark))
        }
        .width('100%')
        .justifyContent(FlexAlign.Start)
      }

      // 底部提交按钮
      Button() {
        Row({ space: 6 }) {
          if (this.submitting) {
            LoadingProgress()
              .width(16)
              .height(16)
              .color(Color.White)
          }
          Text(this.submitting ? (this.uploadHint.length > 0 ? this.uploadHint : '提交中…') : (this.mode === 'repost' ? '立即转发' : '发布'))
            .fontSize(fs(16, this.fontScale))
            .fontWeight(FontWeight.Bold)
            .fontColor(Color.White)
        }
      }
      .width('100%')
      .height(44)
      .backgroundColor(Theme.brand())
      .borderRadius(Radius.full)
      .enabled(!this.submitting && !this.pickingImages && (this.mode === 'repost' || this.content.trim().length > 0))
      .onClick((): void => {
        this.submit();
      })
    }
    .width('100%')
    .padding(Spacing.lg)
    }
    .width('92%')
    .constraintSize({ maxHeight: '80%' })
    .scrollBar(BarState.Auto)
    .backgroundColor(Theme.bgCard(this.isDark))
    .borderRadius(Radius.lg)
    .shadow(Theme.glassShadowStyle())
  }
}
