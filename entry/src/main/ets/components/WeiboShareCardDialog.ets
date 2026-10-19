import { common } from '@kit.AbilityKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';
import { pasteboard } from '@kit.BasicServicesKit';
import { WeiboPost } from '../model/WeiboModel';
import { Radius, Spacing, Theme, fs, isDarkMode } from '../common/Theme';
import { Haptic } from '../common/Haptic';

function createEmptyPost(): WeiboPost {
  const p: WeiboPost = {
    id: '',
    userId: '',
    userName: '',
    userAvatar: '',
    text: '',
    isLongText: false,
    pictures: [],
    videoUrl: '',
    videoCoverUrl: '',
    repostCount: 0,
    commentCount: 0,
    likeCount: 0,
    createdAt: '',
    source: '',
    isLiked: false,
    isFavorited: false,
    repost: null
  };
  return p;
}

@CustomDialog
export struct WeiboShareCardDialog {
  controller: CustomDialogController;
  post: WeiboPost = createEmptyPost();

  @State isDarkTheme: boolean = isDarkMode();
  @State generating: boolean = false;
  @StorageLink('fontScale') fontScale: number = 1.0;

  private cardSnapshotId: string = 'fluo-share-card-container';

  private async generateCardFile(): Promise<string> {
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const savePath: string = `${context.filesDir}/fluo_card_${this.post.id}_${Date.now()}.png`;
    const pixelMap: image.PixelMap = await this.getUIContext().getComponentSnapshot().get(this.cardSnapshotId);
    const packer: image.ImagePacker = image.createImagePacker();
    const data: ArrayBuffer = await packer.packToData(pixelMap, { format: 'image/png', quality: 95 });
    const file: fileIo.File = fileIo.openSync(savePath, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);
    try {
      fileIo.writeSync(file.fd, data);
    } finally {
      fileIo.closeSync(file.fd);
    }
    return fileUri.getUriFromPath(savePath);
  }

  private async saveCardImage(): Promise<void> {
    if (this.generating) { return; }
    this.generating = true;
    Haptic.light();
    let createdUri: string = '';
    try {
      const uri: string = await this.generateCardFile();
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const phAccessHelper: photoAccessHelper.PhotoAccessHelper = photoAccessHelper.getPhotoAccessHelper(context);
      createdUri = await phAccessHelper.createAsset(photoAccessHelper.PhotoType.IMAGE, 'png');
      const srcFile: fileIo.File = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      const destFile: fileIo.File = fileIo.openSync(createdUri, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);
      try {
        fileIo.copyFileSync(srcFile.fd, destFile.fd);
      } finally {
        fileIo.closeSync(srcFile.fd);
        fileIo.closeSync(destFile.fd);
      }
      this.getUIContext().getPromptAction().showToast({ message: '分享卡片已保存至相册' });
    } catch (_e) {
      if (createdUri.length > 0) {
        try {
          const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
          await photoAccessHelper.MediaAssetChangeRequest.deleteAssets(context, [createdUri]);
        } catch (_delErr) {}
      }
      this.getUIContext().getPromptAction().showToast({ message: '卡片已生成，请在系统分享中保存' });
      await this.shareCardImage();
    } finally {
      this.generating = false;
    }
  }

  private async shareCardImage(): Promise<void> {
    if (this.generating) { return; }
    this.generating = true;
    Haptic.light();
    try {
      const uri: string = await this.generateCardFile();
      const shareData: systemShare.SharedData = new systemShare.SharedData({
        utd: utd.UniformDataType.IMAGE,
        uri: uri,
        title: `${this.post.userName} 的微博分享`,
        description: this.post.text.substring(0, 100)
      });
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const controller: systemShare.ShareController = new systemShare.ShareController(shareData);
      controller.show(context, {
        previewMode: systemShare.SharePreviewMode.DEFAULT,
        selectionMode: systemShare.SelectionMode.SINGLE
      });
    } catch (_e) {
      this.getUIContext().getPromptAction().showToast({ message: '分享卡片拉起失败，请重试' });
    } finally {
      this.generating = false;
    }
  }

  private copyCardLink(): void {
    const link: string = `https://m.weibo.cn/detail/${this.post.id}`;
    const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, link);
    pasteboard.getSystemPasteboard().setData(data);
    this.getUIContext().getPromptAction().showToast({ message: '微博链接已复制' });
  }

  @Builder
  CardContent() {
    Stack() {
      // 方案 2 右上角环境流光辉光
      Circle({ width: 130, height: 130 })
        .fill(this.isDarkTheme ? 'rgba(78, 170, 120, 0.12)' : 'rgba(78, 170, 120, 0.16)')
        .blur(40)
        .position({ x: 230, y: -20 })

      Column({ space: Spacing.md }) {
        // 顶部流光胶囊徽标
        Row({ space: 5 }) {
          Circle({ width: 7, height: 7 })
            .fill(Theme.brand())
          Text('精选摘录')
            .fontSize(fs(11, this.fontScale))
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.brand())
        }
        .padding({ left: 10, right: 10, top: 4, bottom: 4 })
        .backgroundColor(this.isDarkTheme ? 'rgba(78, 170, 120, 0.15)' : 'rgba(78, 170, 120, 0.12)')
        .borderRadius(Radius.full)
        .alignSelf(ItemAlign.Start)

        // 艺术双引号微标
        Text('“')
          .fontSize(36)
          .fontWeight(FontWeight.Bolder)
          .fontColor(Theme.brand())
          .opacity(0.35)
          .height(24)
          .alignSelf(ItemAlign.Start)

        // 微博正文：优雅大字号阅读排版
        Text(this.post.text)
          .fontSize(fs(16, this.fontScale))
          .lineHeight(fs(26, this.fontScale))
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textPrimary(this.isDarkTheme))
          .width('100%')

        // 转发原博嵌套（若有）
        if (this.post.repost !== null) {
          Column({ space: Spacing.xs }) {
            Text(`@${this.post.repost.userName}`)
              .fontSize(fs(12, this.fontScale))
              .fontWeight(FontWeight.Bold)
              .fontColor(Theme.brand())
              .width('100%')

            Text(this.post.repost.text)
              .fontSize(fs(12, this.fontScale))
              .lineHeight(fs(19, this.fontScale))
              .fontColor(Theme.textSecondary(this.isDarkTheme))
              .width('100%')
          }
          .width('100%')
          .padding(Spacing.sm)
          .backgroundColor(this.isDarkTheme ? 'rgba(78, 170, 120, 0.08)' : 'rgba(78, 170, 120, 0.06)')
          .borderRadius(Radius.md)
        }

        // 配图展示（至多 3 张）
        if (this.post.pictures && this.post.pictures.length > 0) {
          if (this.post.pictures.length === 1) {
            Image(this.post.pictures[0])
              .width('100%')
              .constraintSize({ maxHeight: 210 })
              .objectFit(ImageFit.Cover)
              .borderRadius(Radius.md)
          } else {
            Row({ space: 8 }) {
              ForEach(this.post.pictures.slice(0, 3), (pic: string): void => {
                Image(pic)
                  .layoutWeight(1)
                  .height(96)
                  .objectFit(ImageFit.Cover)
                  .borderRadius(Radius.sm)
              }, (pic: string): string => pic)
            }
            .width('100%')
          }
        }

        // 方案 2 胶囊状作者标识条
        Row({ space: Spacing.sm }) {
          if (this.post.userAvatar.length > 0) {
            Image(this.post.userAvatar)
              .width(28)
              .height(28)
              .borderRadius(14)
              .objectFit(ImageFit.Cover)
          } else {
            Stack() {
              Text(this.post.userName.substring(0, 1))
                .fontSize(fs(12, this.fontScale))
                .fontColor(Color.White)
                .fontWeight(FontWeight.Bold)
            }
            .width(28)
            .height(28)
            .borderRadius(14)
            .backgroundColor(Theme.brand())
            .alignContent(Alignment.Center)
          }

          Text(this.post.userName)
            .fontSize(fs(13, this.fontScale))
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.textPrimary(this.isDarkTheme))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          Text(this.post.createdAt)
            .fontSize(fs(11, this.fontScale))
            .fontColor(Theme.textTertiary(this.isDarkTheme))
        }
        .width('100%')
        .padding({ left: Spacing.md, right: Spacing.md, top: 8, bottom: 8 })
        .backgroundColor(this.isDarkTheme ? 'rgba(255, 255, 255, 0.05)' : 'rgba(0, 0, 0, 0.03)')
        .borderRadius(Radius.full)
        .border({
          width: 0.5,
          color: this.isDarkTheme ? 'rgba(255, 255, 255, 0.08)' : 'rgba(0, 0, 0, 0.06)'
        })

        // 底部：仅保留 Fluo 品牌标识小字与来源微缩水印（方案 2 仅保留小字）
        Row() {
          Row({ space: 6 }) {
            Circle({ width: 10, height: 10 })
              .fill(Theme.brand())
            Text('Fluo · 沉浸阅读')
              .fontSize(fs(11, this.fontScale))
              .fontWeight(FontWeight.Medium)
              .fontColor(Theme.brand())
          }

          Blank()

          Text('m.weibo.cn')
            .fontSize(fs(11, this.fontScale))
            .fontColor(Theme.textTertiary(this.isDarkTheme))
        }
        .width('100%')
        .padding({ top: Spacing.xs })
        .border({
          width: { top: 0.5 },
          color: this.isDarkTheme ? 'rgba(255, 255, 255, 0.08)' : 'rgba(0, 0, 0, 0.06)'
        })
      }
      .width('100%')
    }
    .width(360)
    .padding(Spacing.lg)
    .backgroundColor(Theme.bgCard(this.isDarkTheme))
    .borderRadius(Radius.lg)
    .border({
      width: 1,
      color: this.isDarkTheme ? 'rgba(78, 170, 120, 0.35)' : 'rgba(78, 170, 120, 0.28)'
    })
    .shadow(Theme.glassShadowStyle())
    .id(this.cardSnapshotId)
  }

  build() {
    Column({ space: Spacing.md }) {
      // 弹窗顶栏：标题、主题切换与关闭
      Row() {
        Text('分享卡片')
          .fontSize(fs(17, this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.textPrimary(this.isDarkTheme))
          .layoutWeight(1)

        Button({ type: ButtonType.Circle }) {
          SymbolGlyph(this.isDarkTheme ? $r('sys.symbol.sun_max') : $r('sys.symbol.moon'))
            .fontSize(16)
            .fontColor([Theme.textSecondary(this.isDarkTheme)])
        }
        .width(36)
        .height(36)
        .backgroundColor(Color.Transparent)
        .onClick((): void => {
          this.isDarkTheme = !this.isDarkTheme;
        })

        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(16)
            .fontColor([Theme.textSecondary(this.isDarkTheme)])
        }
        .width(36)
        .height(36)
        .backgroundColor(Color.Transparent)
        .onClick((): void => {
          this.controller.close();
        })
      }
      .width('100%')
      .padding({ left: Spacing.sm, right: Spacing.sm })

      // 卡片预览主体
      Scroll() {
        this.CardContent()
      }
      .constraintSize({ maxHeight: 420 })
      .scrollBar(BarState.Off)

      // 底部操作区
      Row({ space: Spacing.md }) {
        Button('复制链接')
          .layoutWeight(1)
          .height(40)
          .fontSize(fs(14, this.fontScale))
          .fontColor(Theme.textPrimary(this.isDarkTheme))
          .backgroundColor(this.isDarkTheme ? 'rgba(255, 255, 255, 0.08)' : 'rgba(0, 0, 0, 0.05)')
          .borderRadius(Radius.full)
          .onClick((): void => {
            this.copyCardLink();
          })

        Button(this.generating ? '正在生成…' : '保存图片')
          .layoutWeight(1)
          .height(40)
          .fontSize(fs(14, this.fontScale))
          .fontColor(Color.White)
          .backgroundColor(Theme.brand())
          .borderRadius(Radius.full)
          .enabled(!this.generating)
          .onClick((): void => {
            this.saveCardImage();
          })

        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.share'))
            .fontSize(18)
            .fontColor([Color.White])
        }
        .width(40)
        .height(40)
        .backgroundColor(Theme.brand())
        .enabled(!this.generating)
        .onClick((): void => {
          this.shareCardImage();
        })
      }
      .width('100%')
    }
    .width(380)
    .padding(Spacing.lg)
    .backgroundColor(Theme.bg(this.isDarkTheme))
    .borderRadius(Radius.postCard)
  }
}
