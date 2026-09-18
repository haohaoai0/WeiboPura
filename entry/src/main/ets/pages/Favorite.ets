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

import { common } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { display, LengthMetrics } from '@kit.ArkUI';
import { picker, fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { CacheManager } from '../cache/CacheManager';
import { CACHE_KEY } from '../common/Constants';
import { CategoryMapping, FavCategory, FolderItem, PostCardItem, PersonalContentItem, PinRecord } from '../model/DataModel';
import { TiebaService } from '../service/TiebaService';
import { AuthManager } from '../service/AuthManager';
import { FavoriteStore, CATEGORY_DEFAULT_ID, BackupFolder, BackupImportSummary, BackupPayload } from '../service/FavoriteStore';
import { Theme, Spacing, Radius, isDarkMode, ImmBlur, ImmMaterial, MaterialManager, fs, isWideBarDevice, isLargeFoldDevice, isWideFormDevice as detectWideFormDevice, readColumnMode, overrideColumns, isLargeScreenForm, isWideBarFullscreen } from '../common/Theme';
import { LoadingView, EmptyView, ErrorView, ThreadSharePayload } from '../components/CommonComponents';
import { ListRowSkeleton } from '../components/Skeleton';
import { FavCategoryPicker } from '../components/FavCategoryPicker';
import { ToastUtil, ToastType } from '../common/ToastUtil';
import { Haptic } from '../common/Haptic';
import { ShareUtil } from '../common/ShareUtil';
import { compareByName } from '../common/Pinyin';

enum FavCategoryTab {
  Forums = 0,
  Custom = 1,
}

/** v1.11 排序模式：名称正/倒序、时间正/倒序（添加时间）、自定义（仅自定义分类可用） */
enum SortMode {
  NameAsc = 0,
  NameDesc = 1,
  TimeAsc = 2,
  TimeDesc = 3,
  Custom = 4,
}

/** BUG-05 置顶/取消置顶确认弹窗目标 */
interface PinConfirmTarget {
  forumName: string;
  targetPin: boolean;
}

/** v1.18 收藏云同步元数据（按账号隔离持久化）：lastNetAt=最近一次网络同步，fullAt=最近一次全量校正完成 */
interface SyncMeta {
  lastNetAt: number;
  fullAt: number;
}

enum FavLoadState {
  Loading, Success, Empty, Error,
}

// 吧头像内存缓存（跨页面会话复用，避免频繁触发吧接口风控）
const forumAvatarMemoryCache: Map<string, string> = new Map<string, string>();
/** 收藏页顶部槽位开关（§6.10 同机制，与首页/进吧/详情页一致）：
 *  true  = TopBar 整行（五种形态）搬进 Navigation title 槽位，槽内子元素各自挂 systemMaterial 吃官方沉浸材质；
 *  false = 一键回退到改造前的页面主体悬浮 TopBar（segGlass + backgroundBlurStyle 真磨砂自绘），旧 TopBar() 原样保留。 */
const FAV_OFFICIAL_TITLE_BAR: boolean = true;
/** 顶部槽位高度 = 44(状态栏让位) + 44(按钮行高) + 10(底部呼吸)，与原 TopBar 的 padding(top:44, bottom:10) 逐项一致。
 *  内容让位常量（TopBar 98 + Tab 44 + Tab 与首卡间隙 6 = 148）不变 —— 两个数字成对，改一个必须核对另一个。 */
const FAV_TITLE_BAR_HEIGHT: number = 98;
/** 槽内第二行「吧分类 / 自定义分类」胶囊行高 = 2(与按钮行间隙，原 top:100 - TopBar 98) + 40(胶囊高，加高为饱满胶囊) + 8(底部 Spacing.sm)。
 *  仅根态显示，title 高度随之在 98 / 98+50 切换。 */
const FAV_CAT_TAB_ROW_HEIGHT: number = 50;
// 收藏页导航状态（模块级内存：Index 底部 Tab 条件渲染会销毁/重建组件，用模块变量恢复浏览位置；进程重启自然重置）
let lastCategoryTab: number = FavCategoryTab.Forums;
let lastSelectedForum: string = '';
let lastSelectedCategoryId: string = '';

/**
 * 通用确认弹窗（系统 CustomDialog + API 26 沉浸光感）。
 * 现承载三处：收藏页「置顶/取消置顶」确认、编辑态「批量删除收藏」确认、分类管理「删除分类」确认。
 * 三者几何完全同源（宽度 / 圆角 / 底部锚点 / 遮罩一致），仅文案与主按钮配色不同：
 * 置顶 = 品牌蓝（ImmMaterial.accent），两处删除 = 危险红（ImmMaterial.danger + danger=true）。
 *
 * 与进吧页一键签到弹窗同源改造：原「页面 body 顶层 Stack 自绘浮层」换成系统弹窗，
 * 玻璃层交给 options.systemMaterial，卡内不再自绘 backgroundColor / border /
 * backgroundBlurStyle / shadow 四项（材质会接管它们）。
 *
 * 几何与内容对齐（与改造前的自绘浮层逐项一致）：
 * - 宽度 calc(100% - 48vp) → options.width 数值 vp；圆角 32vp；遮罩 #06000000；
 *   底部锚点（底距 110）；标题 / 正文 / 按钮尺寸与字号全部原样保留。
 * - 文案走快照 @Link：宿主打开前算好，弹窗内不再做三元判断（PinConfirmTarget | null
 *   不能直接 @Link 进 @CustomDialog）。
 */
@CustomDialog
struct ConfirmDialogCard {
  /** 系统弹窗必须声明 CustomDialogController 类型属性（ArkTS 编译期强校验） */
  controller?: CustomDialogController;
  @Link isDark: boolean;
  @Link fontScale: number;
  /** 标题（「置顶收纳夹」/「取消置顶」/「删除收藏」） */
  @Link dialogTitle: string;
  /** 正文说明 */
  @Link dialogMessage: string;
  /** 主按钮文案（「置顶」/「取消置顶」/「删除」） */
  @Link confirmLabel: string;
  /**
   * 主按钮是否走危险色（删除等不可逆操作）。
   * 常量语义（同一弹窗实例内不会变化），故用普通成员而非 @Link：由 controller builder 传字面量。
   */
  danger: boolean = false;
  /** 取消（点遮罩 / 返回键同源） */
  onCancel: () => void = () => {};
  /** 确认执行 */
  onConfirm: () => void = () => {};

  build() {
    Column() {
      Column({ space: 6 }) {
        Text(this.dialogTitle)
          .fontSize(fs(17, this.fontScale))
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textPrimary(this.isDark))
          .textAlign(TextAlign.Center)
        Text(this.dialogMessage)
          .fontSize(fs(13, this.fontScale))
          .fontColor(Theme.textSecondary(this.isDark))
          .lineHeight(fs(18, this.fontScale))
          .textAlign(TextAlign.Center)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
      .padding({ left: Spacing.lg, right: Spacing.lg, top: Spacing.lg, bottom: Spacing.md })

      Row({ space: Spacing.md }) {
        Button() {
          Text('取消')
            .fontSize(fs(15, this.fontScale))
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.textPrimary(this.isDark))
        }
        .layoutWeight(1)
        .height(44)
        // 与一键签到弹窗的次按钮同源：材质 + 半透明底 + 中性轻投影（底色不透明会盖掉材质）
        .systemMaterial(ImmMaterial.cardAction())
        .backgroundColor(this.isDark ? '#B31B1E24' : '#B3FFFFFF')
        .borderRadius(Radius.full)
        .shadow({ radius: 10, color: this.isDark ? '#4D000000' : '#1F101824', offsetY: 3 })
        .accessibilityText('取消')
        .onClick(() => { this.onCancel(); })

        Button() {
          Text(this.confirmLabel)
            .fontSize(fs(15, this.fontScale))
            .fontColor(Color.White)
            .fontWeight(FontWeight.Medium)
        }
        .layoutWeight(1)
        .height(44)
        // 与一键签到弹窗的主按钮同源：品牌蓝 / 危险红 + 材质 + 同色浮起阴影
        .systemMaterial(this.danger ? ImmMaterial.danger(this.isDark) : ImmMaterial.accent(this.isDark))
        .backgroundColor(this.danger ? '#CCF5222D' : '#CC3173FF')
        .borderRadius(Radius.full)
        .shadow({
          radius: 14,
          color: this.danger ? (this.isDark ? '#66F5222D' : '#4DF5222D') : (this.isDark ? '#663173FF' : '#4D3173FF'),
          offsetY: 4
        })
        .accessibilityText(`确认${this.confirmLabel}`)
        .onClick(() => { this.onConfirm(); })
      }
      .width('100%')
      .padding({ left: Spacing.lg, right: Spacing.lg, bottom: Spacing.lg })
    }
    .width('100%')
    .padding({ top: Spacing.md })
  }
}

/**
 * 分类管理弹窗（系统 CustomDialog + API 26 沉浸光感）。
 *
 * 原为「页面 body 顶层 Stack 自绘浮层」（宿主 @Builder CategoryManageSheet）→ 换成系统 CustomDialog：
 * 自绘浮层挂 systemMaterial 必然 `Material inactive: out of scope`，只有系统弹窗宿主才吃官方沉浸材质。
 *
 * 几何与改造前逐项一致（§4.3 对齐表）：
 * - 宽度 calc(100% - 48vp) → options.width 数值 vp；圆角 32vp；遮罩 #06000000；
 *   底部锚点（底距 110）→ alignment Bottom + offset dy -110；
 *   信息行 / 菜单行 / 取消按钮的尺寸、内距、字号全部原样保留。
 * - 卡内不再自绘 backgroundColor / border / backgroundBlurStyle / shadow 四项（材质会接管）。
 *
 * 数据传递（可空对象 `FavCategory | null` 不能 @Link 进弹窗，§6.3）：
 * 宿主把 manageTargetCat 拆成 4 个基本类型快照 @Link 进来，由 onManageCatChanged 同步 ——
 * 重命名成功后宿主重指向新对象，快照随之刷新，信息行名称实时更新（与改造前一致）。
 *
 * ⚠️ 重命名编辑态直接 @Link 宿主的 categoryRenameMode / categoryInputValue，
 * 故宿主 commitCategoryRename / cancelCategoryRename 读到的仍是同一份数据，业务逻辑零改动。
 */
@CustomDialog
struct CategoryManageDialog {
  /** 系统弹窗必须声明 CustomDialogController 类型属性（ArkTS 编译期强校验） */
  controller?: CustomDialogController;
  @Link isDark: boolean;
  @Link fontScale: number;
  /** 目标分类展示快照（名称 / 封面 / 图标 / 收藏数） */
  @Link catName: string;
  @Link catCover: string;
  @Link catIcon: string;
  @Link catCount: number;
  /** 弹窗内原地重命名编辑态：true = 信息行名称区切换为输入框（弹窗不关闭） */
  @Link renameMode: boolean;
  /** 重命名输入值（与宿主 categoryInputValue 是同一份数据） */
  @Link inputValue: string;
  /** 提交重命名（业务在宿主：校验 + 写 store + 刷新 categories） */
  onCommitRename: () => void = () => {};
  /** 删除分类（业务在宿主：先关窗再延时弹确认框） */
  onRemove: () => void = () => {};
  /** 取消（点遮罩 / 返回键同源，统一走宿主 closeCategoryManage） */
  onCancel: () => void = () => {};

  build() {
    Column() {
      // 信息行：封面 + 分类名/重命名输入 + 数量（透明底，融入玻璃卡，承担卡片顶部标题功能）
      Row({ space: Spacing.md }) {
        this.CategoryCoverCell(this.catCover, this.catIcon, this.catName)
        if (this.renameMode) {
          Row({ space: 8 }) {
            TextInput({ placeholder: '分类名称', text: this.inputValue })
              .layoutWeight(1)
              .fontSize(fs(14, this.fontScale))
              .fontColor(Theme.textPrimary(this.isDark))
              .backgroundColor(Theme.bgCard(this.isDark))
              .borderRadius(Radius.full)
              .height(40)
              .defaultFocus(true)
              .onChange((v: string) => { this.inputValue = v; })
              .onSubmit(() => { this.onCommitRename(); })

            Button() {
              Text('取消')
                .fontSize(fs(13, this.fontScale))
                .fontColor(Theme.textSecondary(this.isDark))
            }
            .height(40)
            .padding({ left: 12, right: 12 })
            // 按 §6.2：弹窗内 Button 也吃官方材质（半透明底 + 材质可共存；不透明底会盖掉材质）
            .systemMaterial(ImmMaterial.cardAction())
            .backgroundColor(this.isDark ? '#B31B1E24' : '#B3FFFFFF')
            .borderRadius(Radius.full)
            .onClick(() => {
              // 取消重命名：退出编辑态，信息行恢复显示原名称（弹窗不关闭）
              this.renameMode = false;
              this.inputValue = this.catName;
            })

            Button() {
              Text('保存')
                .fontSize(fs(13, this.fontScale))
                .fontColor(Color.White)
            }
            .height(40)
            .padding({ left: 14, right: 14 })
            .systemMaterial(ImmMaterial.accent(this.isDark))
            .backgroundColor('#CC3173FF')
            .borderRadius(Radius.full)
            .onClick(() => { this.onCommitRename(); })
          }
          .layoutWeight(1)
        } else {
          Column({ space: 4 }) {
            Text(this.catName)
              .fontSize(fs(16, this.fontScale))
              .fontWeight(FontWeight.Bold)
              .fontColor(Theme.textPrimary(this.isDark))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(`${this.catCount} 个收藏`)
              .fontSize(fs(12, this.fontScale))
              .fontColor(Theme.textTertiary(this.isDark))
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
        }
      }
      .width('100%')
      .padding({ left: Spacing.lg, right: Spacing.lg, bottom: Spacing.sm })

      this.CardDividerLine()

      // 操作菜单行（透明底 + 行间分隔线）
      Column() {
        this.ActionRow($r('sys.symbol.square_and_pencil'), '重命名分类', false, () => {
          // 弹窗内原地重命名：不关闭弹窗，信息行名称处切换为输入框并预填原名
          this.renameMode = true;
          this.inputValue = this.catName;
        })
        this.CardDividerLine()
        this.ActionRow($r('sys.symbol.trash'), '删除分类', true, () => { this.onRemove(); })
      }
      .width('100%')
      .padding({ left: Spacing.lg, right: Spacing.lg })

      Button() {
        Text('取消')
          .fontSize(fs(15, this.fontScale))
          .fontColor(Theme.textPrimary(this.isDark))
          .fontWeight(FontWeight.Medium)
      }
      .width('calc(100% - 32vp)')
      .height(44)
      .systemMaterial(ImmMaterial.cardAction())
      .backgroundColor(this.isDark ? '#B31B1E24' : '#B3FFFFFF')
      .borderRadius(Radius.full)
      .margin({ left: Spacing.lg, right: Spacing.lg, top: Spacing.md, bottom: Spacing.lg })
      .accessibilityText('取消')
      .onClick(() => { this.onCancel(); })
    }
    .width('100%')
    .padding({ top: Spacing.md })
  }

  /**
   * 分类封面（与宿主 @Builder CategoryCover 同源）：有 cover 显示图片（等比裁剪），无 cover 走扁平 SymbolGlyph 兜底。
   * 宿主那份继续供分类卡片使用；此处复制一份让弹窗内容自包含（@Builder 不能跨 struct 调用）。
   */
  @Builder
  CategoryCoverCell(cover: string, icon: string, name: string) {
    if (cover.length > 0) {
      // 数据库存的是裸绝对路径（如 /data/.../files/cat_cover_xxx.png），Image 需 file:// 前缀
      Image(cover.startsWith('file://') ? cover : `file://${cover}`)
        .width(48)
        .height(48)
        .objectFit(ImageFit.Cover)
        .borderRadius(24)
        .clip(true)
        .syncLoad(true)
        .accessibilityText('封面图')
    } else {
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph($r('sys.symbol.folder_fill'))
          .fontSize(fs(24, this.fontScale))
          .fontColor([Theme.brand()])
      }
      .width(48)
      .height(48)
      .backgroundColor(Theme.bgElevated(this.isDark))
      .borderRadius(24)
      .accessibilityText(`${name} 分类图标`)
    }
  }

  /** 分类管理操作行（与宿主 @Builder ActionRow 同源）：SymbolGlyph 图标 + 标题 + 右箭头，危险操作用 Theme.danger */
  @Builder
  ActionRow(symbol: Resource, title: string, danger: boolean, onTap: () => void) {
    Row({ space: Spacing.md }) {
      SymbolGlyph(symbol)
        .fontColor([danger ? Theme.danger() : Theme.textPrimary(this.isDark)])
        .fontSize(fs(19, this.fontScale))
      Text(title)
        .fontSize(fs(15, this.fontScale))
        .fontWeight(FontWeight.Medium)
        .fontColor(danger ? Theme.danger() : Theme.textPrimary(this.isDark))
        .layoutWeight(1)
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontColor([$r('sys.color.icon_tertiary')])
        .fontSize(fs(14, this.fontScale))
    }
    .width('100%')
    .padding({ left: Spacing.md, right: Spacing.md, top: 12, bottom: 12 })
    .accessibilityText(title)
    .onClick(onTap)
  }

  /** 居中卡片内分隔线（与宿主 @Builder CardDivider 同源，深浅色自适应） */
  @Builder
  CardDividerLine() {
    Column()
      .width('calc(100% - 32vp)')
      .height(0.5)
      .backgroundColor(this.isDark ? '#26FFFFFF' : '#12000000')
  }
}

/**
 * 备份弹窗（系统 CustomDialog + API 26 沉浸光感）。
 *
 * 原为「页面 body 顶层 Stack 自绘浮层」（宿主 @Builder BackupDialog）→ 换成系统 CustomDialog：
 * 自绘浮层挂 systemMaterial 必然 `Material inactive: out of scope`，只有系统弹窗宿主才吃官方沉浸材质。
 *
 * 几何与改造前逐项一致（§4.3 对齐表）：
 * - 宽度 calc(100% - 48vp) → options.width 数值 vp；圆角 32vp；遮罩 #06000000；
 *   底部锚点（底距 110）→ alignment Bottom + offset dy -110；
 *   标题区 / 两条分隔线 / 两行入口 / 取消按钮的尺寸、内距、字号、图标全部原样保留。
 * - 卡内不再自绘 backgroundColor / border / backgroundBlurStyle / shadow 四项（材质会接管）。
 *
 * 内容自包含：CardDividerLine 与宿主 CardDivider 同源（@Builder 不能跨 struct 调用，§6.6 坑 1）。
 * ⚠️ 两行入口（导出 / 导入）原本就是**透明行**（无底色，平铺在玻璃卡上），故不挂材质 ——
 * 挂 THIN 材质会在卡面多出一块玻璃瓦片，与改造前观感不符；只把卡片玻璃本身换成官方材质。
 */
@CustomDialog
struct BackupDialogCard {
  /** 系统弹窗必须声明 CustomDialogController 类型属性（ArkTS 编译期强校验） */
  controller?: CustomDialogController;
  @Link isDark: boolean;
  @Link fontScale: number;
  /** 导出备份（业务在宿主：关本弹窗 → 打开导出授权弹窗） */
  onExport: () => void = () => {};
  /** 导入备份（业务在宿主：关本弹窗 → 拉起系统文件选择器） */
  onImport: () => void = () => {};
  /** 取消（点遮罩 / 返回键同源，统一走宿主 closeBackupDialog） */
  onCancel: () => void = () => {};

  build() {
    Column() {
      // 标题区（留出呼吸感）
      Column({ space: 6 }) {
        Text('分类备份')
          .fontSize(fs(17, this.fontScale))
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textPrimary(this.isDark))
          .textAlign(TextAlign.Center)
        Text('备份仅包含自定义分类及其中的帖子映射，收藏本体在云端不受影响。')
          .fontSize(fs(13, this.fontScale))
          .fontColor(Theme.textSecondary(this.isDark))
          .lineHeight(fs(18, this.fontScale))
          .textAlign(TextAlign.Center)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
      .padding({ left: Spacing.lg, right: Spacing.lg, top: Spacing.lg, bottom: Spacing.md })

      this.CardDividerLine()

      // 导出备份：图标 + 主文案 + 副文案 + 右箭头
      Row({ space: Spacing.md }) {
        SymbolGlyph($r('sys.symbol.arrow_up'))
          .fontColor([Theme.textPrimary(this.isDark)])
          .fontSize(fs(19, this.fontScale))
        Column({ space: 2 }) {
          Text('导出备份')
            .fontSize(fs(15, this.fontScale))
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.textPrimary(this.isDark))
          Text('将自定义分类及分类内帖子保存为 JSON 文件')
            .fontSize(fs(12, this.fontScale))
            .fontColor(Theme.textTertiary(this.isDark))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontColor([$r('sys.color.icon_tertiary')])
          .fontSize(fs(14, this.fontScale))
      }
      .width('100%')
      .padding({ left: Spacing.md, right: Spacing.md, top: 12, bottom: 12 })
      .accessibilityText('导出备份')
      .onClick(() => { this.onExport(); })

      this.CardDividerLine()

      // 导入备份
      Row({ space: Spacing.md }) {
        SymbolGlyph($r('sys.symbol.arrow_down'))
          .fontColor([Theme.textPrimary(this.isDark)])
          .fontSize(fs(19, this.fontScale))
        Column({ space: 2 }) {
          Text('导入备份')
            .fontSize(fs(15, this.fontScale))
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.textPrimary(this.isDark))
          Text('从本地 JSON 文件恢复分类与帖子映射')
            .fontSize(fs(12, this.fontScale))
            .fontColor(Theme.textTertiary(this.isDark))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontColor([$r('sys.color.icon_tertiary')])
          .fontSize(fs(14, this.fontScale))
      }
      .width('100%')
      .padding({ left: Spacing.md, right: Spacing.md, top: 12, bottom: 12 })
      .accessibilityText('导入备份')
      .onClick(() => { this.onImport(); })

      // 显式取消按钮（同分类管理弹窗视觉）：按 §6.2 挂材质 + **半透明**底
      //（原 Theme.bgCard 是不透明卡片色，会完全盖掉材质，故换 #B3FFFFFF / #B31B1E24）
      Button() {
        Text('取消')
          .fontSize(fs(15, this.fontScale))
          .fontColor(Theme.textPrimary(this.isDark))
          .fontWeight(FontWeight.Medium)
      }
      .width('calc(100% - 32vp)')
      .height(44)
      .systemMaterial(ImmMaterial.cardAction())
      .backgroundColor(this.isDark ? '#B31B1E24' : '#B3FFFFFF')
      .borderRadius(Radius.full)
      .margin({ left: Spacing.lg, right: Spacing.lg, top: Spacing.md, bottom: Spacing.lg })
      .accessibilityText('取消')
      .onClick(() => { this.onCancel(); })
    }
    .width('100%')
    .padding({ top: Spacing.md })
  }

  /** 居中卡片内分隔线（与宿主 @Builder CardDivider 同源，深浅色自适应） */
  @Builder
  CardDividerLine() {
    Column()
      .width('calc(100% - 32vp)')
      .height(0.5)
      .backgroundColor(this.isDark ? '#26FFFFFF' : '#12000000')
  }
}

/**
 * 导出备份授权弹窗（系统 CustomDialog + API 26 沉浸光感）。
 *
 * 原为「页面 body 顶层 Stack 自绘浮层」（宿主 @Builder ExportDialog）→ 换成系统 CustomDialog：
 * 自绘浮层挂 systemMaterial 必然 `Material inactive: out of scope`，只有系统弹窗宿主才吃官方沉浸材质。
 *
 * UI 与同页「分类备份」弹窗（BackupDialogCard）**完全一致**（用户点名要求）：
 * 卡片宽度 `dialogCardWidth()` / 圆角 32vp / 底部锚点（底距 110）/ 遮罩 #06000000 / `ImmMaterial.dialog()`；
 * 标题区排版同款（标题 17 Medium 居中 + 说明 13 次级居中、lineHeight 18、内距 lg/lg/lg/md）；
 * 标题区下同一条分隔线；下方是同一套「全宽 44 高 + Radius.full」按钮语言（16vp 内缩 = 卡片宽 - 32vp）。
 *
 * ⚠️ 唯一不能统一的：主操作必须是系统 **SaveButton 安全控件**（用户真实点击才临时授权写入本地文件，
 * 换普通 Button 会破坏免权限授权链路）。因此按安全控件通用属性规范：
 * - 宽度用**数值 vp**（`actionWidth` = 卡片宽 - 32）而不是百分比 / calc —— 安全控件只继承
 *   「安全控件通用属性」，对非常规取值容错差，文本被截断时会**静默不授权**；
 * - 安全控件通用属性里**没有 margin**，故外边距交给外层 Row 的 padding。
 *
 * 文案走快照 @Link（宿主打开前算好分类数），弹窗内不做业务取数（同 ConfirmDialogCard §6.1）。
 */
@CustomDialog
struct ExportDialogCard {
  /** 系统弹窗必须声明 CustomDialogController 类型属性（ArkTS 编译期强校验） */
  controller?: CustomDialogController;
  @Link isDark: boolean;
  @Link fontScale: number;
  /** 说明文案（宿主打开前算好：`将导出 N 个自定义分类及分类内帖子为 JSON 文件。`） */
  @Link dialogMessage: string;
  /** 卡内按钮宽（vp）= 卡片宽 - 32，与「取消」按钮的 calc(100% - 32vp) 等值（安全控件不用百分比） */
  actionWidth: number = 280;
  /** SaveButton 授权成功（宿主：构建 JSON → 系统保存面板 → 写文件） */
  onAuthorized: () => void = () => {};
  /** 取消（点遮罩 / 返回键同源，统一走宿主 closeExportDialog） */
  onCancel: () => void = () => {};

  build() {
    Column() {
      // 标题区（与备份弹窗逐项一致）
      Column({ space: 6 }) {
        Text('导出备份')
          .fontSize(fs(17, this.fontScale))
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textPrimary(this.isDark))
          .textAlign(TextAlign.Center)
        Text(this.dialogMessage)
          .fontSize(fs(13, this.fontScale))
          .fontColor(Theme.textSecondary(this.isDark))
          .lineHeight(fs(18, this.fontScale))
          .textAlign(TextAlign.Center)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
      .padding({ left: Spacing.lg, right: Spacing.lg, top: Spacing.lg, bottom: Spacing.md })

      this.CardDividerLine()

      // 授权区：系统安全控件（全宽 44，与下方取消按钮同形；外边距由外层 Row 承担）
      Row() {
        SaveButton({ icon: SaveIconStyle.FULL_FILLED, text: SaveDescription.SAVE, buttonType: ButtonType.Capsule })
          .width(this.actionWidth)
          .height(44)
          .onClick((event: ClickEvent, result: SaveButtonOnClickResult) => {
            if (result === SaveButtonOnClickResult.SUCCESS) {
              this.onAuthorized();
            }
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .padding({ left: Spacing.lg, right: Spacing.lg, top: Spacing.md })

      // 显式取消按钮（与备份弹窗同款：材质 + 半透明底）
      Button() {
        Text('取消')
          .fontSize(fs(15, this.fontScale))
          .fontColor(Theme.textPrimary(this.isDark))
          .fontWeight(FontWeight.Medium)
      }
      .width('calc(100% - 32vp)')
      .height(44)
      .systemMaterial(ImmMaterial.cardAction())
      .backgroundColor(this.isDark ? '#B31B1E24' : '#B3FFFFFF')
      .borderRadius(Radius.full)
      .margin({ left: Spacing.lg, right: Spacing.lg, top: Spacing.md, bottom: Spacing.lg })
      .accessibilityText('取消导出')
      .onClick(() => { this.onCancel(); })
    }
    .width('100%')
    .padding({ top: Spacing.md })
  }

  /** 居中卡片内分隔线（与宿主 @Builder CardDivider 同源，深浅色自适应） */
  @Builder
  CardDividerLine() {
    Column()
      .width('calc(100% - 32vp)')
      .height(0.5)
      .backgroundColor(this.isDark ? '#26FFFFFF' : '#12000000')
  }
}

/**
 * 收藏主 Tab 页（P0 骨架第一批）：
 * - 吧分类收纳夹列表（增量聚合，按吧名分组 + 吧名码点序 + 置顶恒顶）
 * - 吧内帖子列表（本地过滤，排序降级：倒序=接口默认序，正序=本地反转，置顶恒顶）
 * - 自定义分类页（框架 + 空态引导，CRUD 后续迭代）
 * - 长按置顶/取消置顶（吧收纳夹与帖子，Preferences 存储）
 * - 下拉刷新 + 触底分页 + 空态/错误态；EventHub 订阅收藏变更（重读本地缓存）
 */
@Component
export struct FavoriteTab {
  @State @Watch('syncBackState') categoryTab: number = lastCategoryTab;
  @State @Watch('syncBackState') selectedForum: string = lastSelectedForum;
  @State folders: FolderItem[] = [];
  @State allThreads: PersonalContentItem[] = [];
  // v1.11 排序：SortMode + 下拉菜单开关 + 本地收藏时间映射 + 分类内帖子自定义顺序 + 帖子拖拽下标
  @State sortMode: SortMode = SortMode.TimeDesc;
  @State showSortMenu: boolean = false;
  @State collectTimes: Record<string, number> = {};
  @State threadOrders: Record<string, string[]> = {};
  @State draggingThreadIndex: number = -1;
  @State loadState: FavLoadState = FavLoadState.Loading;
  @State errorMsg: string = '';
  @State loading: boolean = false;
  @State loadingMore: boolean = false;
  @State hasMore: boolean = true;
  @State isDark: boolean = isDarkMode();
  @State refreshing: boolean = false;
  @State pinnedFolders: PinRecord[] = [];
  /**
   * 顶部渐显带收窄（2026-09-13 用户反馈）：平板竖屏下原 20% 渐显覆盖到第一个卡片中部，
   * 要求「只覆盖顶部按钮与标题」→ 平板档覆盖高度 = 顶栏 98 + 分段切换区（至 132），手机维持 20%。
   */
  private readonly isWideFormDevice: boolean = detectWideFormDevice();
  // ===== 平板适配（docs/TiebaPura平板适配.md §4.3 改动四）=====
  /** 窗口宽 / 高（vp）：aboutToAppear 取首帧初值（fadeCoverVp 同源），根 Stack.onAreaChange 实时兜底 */
  @State pageWidth: number = 0;
  @State pageHeight: number = 0;

  /** 横竖屏：宽高比（与 §4.1 / §4.2 同口径） */
  private isLandscape(): boolean {
    return this.pageWidth > this.pageHeight;
  }

  /**
   * 列数（§4.3 改动四，2026-09-14 拍板）：大屏横 4 / 竖 3；窄窗与手机维持 1 列。
   * 形态闸门必须放首行：只按宽度判会让手机横屏（约 780vp ≥ 600）误命中多列。
   */
  private favColumns(): number {
    // 窗口闸门最前（2026-09-17 小窗 / 分屏适配）：窗口宽 <600（自由多窗小窗 / 分屏窄窗）一律回落
    // 手机单列档——须在设备恒值分支（大折叠恒 3）之前，防小窗误命中
    // 阔直屏全屏白名单（2026-09-18）：Pura X View（VOL-AL00）等阔直屏竖屏全屏窗口宽仅 ~440vp，
    // 会被本闸门误判成小窗；白名单放行（小窗 / 分屏仍拦，见 Theme.isWideBarFullscreen）
    if (this.pageWidth > 0 && this.pageWidth < 600 && !isWideBarFullscreen(this.pageWidth)) {
      return 1;
    }
    // 「列数调整」（2026-09-18，个性化 → 列数调整）：仅大屏形态（平板 / 阔直屏 / 大折叠展开）生效，
    // 窄窗与手机档已由上面的窗口闸门返回不受影响；默认档 ov=0 → 原样走下面自动适配分支（逐像素零回归）
    if (isLargeScreenForm(this.isWideFormDevice)) {
      const ov: number = overrideColumns(this.columnMode, this.isLandscape());
      if (ov > 0) {
        return ov;
      }
    }
    // 大折叠（docs/TiebaPura大折叠适配.md §4.2）：竖 2 / 横 3（2026-09-17 用户改定，与阔直屏同口径）
    if (isLargeFoldDevice()) {
      return this.isLandscape() ? 3 : 2;
    }
    // 阔直屏（docs/TiebaPura阔直屏适配.md §4.2，2026-09-17 用户改定）：不依赖宽度阈值（竖屏宽 <600），
    // 竖 1 / 横 3（竖屏回落手机单列档；初版竖 2 作废）
    if (isWideBarDevice()) {
      return this.isLandscape() ? 3 : 1;
    }
    if (!this.isWideFormDevice) {
      return 1;
    }
    if (this.pageWidth < 600) {
      return 1; // 折叠态 / 分屏 / 自由多窗窄窗
    }
    // 2026-09-17 三次拍板：平板**竖屏 2 列**（≥840 竖屏 3 列作废）/ 横屏 3 列（各视图共用）
    return this.isLandscape() ? 3 : 2;
  }

  /** 帖子列表列模板（改动三 / 五共用）：收藏夹点开列表与搜索态同口径 */
  private forumColumnsTemplate(): string {
    const n: number = this.favColumns();
    if (n >= 4) {
      return '1fr 1fr 1fr 1fr';
    }
    if (n === 3) {
      return '1fr 1fr 1fr';
    }
    return '1fr';
  }
  /** 屏幕长边（vp）：竖屏视口高的稳定来源（旋转取长边，渐显比例不漂移） */
  @State fadeCoverVp: number = 0;
  @State pinnedThreads: PinRecord[] = [];
  @State notLoggedIn: boolean = false;
  @State @Watch('syncBackState') editMode: boolean = false;
  @State selectedTids: string[] = [];
  @State categories: FavCategory[] = [];
  @State mappings: CategoryMapping[] = [];
  @State @Watch('syncBackState') selectedCategoryId: string = lastSelectedCategoryId;
  @State @Watch('syncBackState') categoryInputVisible: boolean = false;
  @State categoryEditingId: string = '';
  @State categoryInputValue: string = '';
  @State @Watch('syncBackState') showMovePanel: boolean = false;
  /** §4.3 改动六·方案四：平板「自定义排序」半屏面板开关（bindSheet，与 showMovePanel 同机制） */
  @State showSortPanel: boolean = false;
  /** 移入面板勾选集合（分类 id；CATEGORY_DEFAULT_ID = 未分类，与具体分类互斥）——面板组件 @Link 双向绑定 */
  @State moveChecked: string[] = [];
  /**
   * 移入面板内「新建分类」输入态（面板组件 @Link 双向绑定；输入行草稿留在组件内，宿主只持两态开关）。
   * 宿主持有它只为让返回键先退输入行、不关整个面板（与收藏页 categoryInputVisible 口径一致）。
   */
  @State pickerCreating: boolean = false;
  /** 移入面板参与的帖子 tid 快照（须 @State 才能作为 @Prop 同步给面板组件 FavCategoryPicker） */
  @State movePanelTids: string[] = [];
  /**
   * 导出授权弹窗显隐（v1.15.11 起为系统 CustomDialog + API 26 沉浸光感，见顶层 struct ExportDialogCard）。
   * 与其他弹窗同款：布尔状态 + @Watch 驱动 open/close（故原先挂在它上面的 syncBackState 由 onShowExportDialogChanged 代劳）。
   */
  @State @Watch('onShowExportDialogChanged') showExportDialog: boolean = false;
  /** 导出弹窗说明文案快照（宿主打开前算好分类数，弹窗内只读展示） */
  @State exportDialogMessage: string = '';
  /**
   * v1.15.9 备份入口显隐（v1.15.11 起为系统 CustomDialog + API 26 沉浸光感，见顶层 struct BackupDialogCard）。
   * 保留单一布尔状态，真正 open/close 由 @Watch 驱动，既有 `this.showBackupDialog = x` 调用点零改动。
   * ⚠️ 一个状态变量只能挂一个 @Watch，故原先的 syncBackState 由 onShowBackupDialogChanged 代劳。
   */
  @State @Watch('onShowBackupDialogChanged') showBackupDialog: boolean = false;
  /**
   * 分类管理显隐（v1.15.10 起为系统 CustomDialog + API 26 沉浸光感，见顶层 struct CategoryManageDialog）。
   * 保留单一布尔状态，真正 open/close 由 @Watch 驱动，既有 `this.showCategoryManage = x` 调用点零改动。
   * ⚠️ 一个状态变量只能挂一个 @Watch，故原先的 syncBackState 由 onShowCategoryManageChanged 代劳。
   */
  @State @Watch('onShowCategoryManageChanged') showCategoryManage: boolean = false;
  /** 分类管理目标（唯一真源；传给弹窗的基本类型快照由 onManageCatChanged 同步） */
  @State @Watch('onManageCatChanged') manageTargetCat: FavCategory | null = null;
  /** 弹窗展示快照：目标分类的名称 / 封面 / 图标 / 收藏数（可空对象不能 @Link 进 @CustomDialog，§6.3） */
  @State manageCatName: string = '';
  @State manageCatCover: string = '';
  @State manageCatIcon: string = '';
  @State manageCatCount: number = 0;
  // v1.15.8 分类管理弹窗内原地重命名：true = 信息行名称区切换为输入框（弹窗不关闭）
  @State @Watch('syncBackState') categoryRenameMode: boolean = false;
  /**
   * 置顶/取消置顶确认显隐（系统 CustomDialog + API 26 沉浸光感）。
   * 宿主已由「页面 body 顶层 Stack 自绘浮层」换成系统 CustomDialog —— 官方沉浸光感 A 档
   * 「弹窗类」只覆盖系统 Dialog / 弹窗类接口，自绘浮层挂 systemMaterial 必然 out of scope。
   * 保留单一布尔状态，真正 open/close 由 @Watch 驱动，既有 `this.showPinConfirm = x` 调用点零改动。
   * ⚠️ 一个状态变量只能挂一个 @Watch，故原先的 syncBackState 由 onShowPinConfirmChanged 代劳。
   */
  @State @Watch('onShowPinConfirmChanged') showPinConfirm: boolean = false;
  @State pinConfirmTarget: PinConfirmTarget | null = null;
  /** 弹窗展示快照：标题（PinConfirmTarget | null 不能直接 @Link 进 @CustomDialog） */
  @State pinConfirmTitle: string = '';
  /** 弹窗展示快照：正文说明 */
  @State pinConfirmMessage: string = '';
  /** 弹窗展示快照：主按钮文案 */
  @State pinConfirmConfirmLabel: string = '';

  /**
   * 批量删除收藏确认显隐（系统 CustomDialog + API 26 沉浸光感）。
   * 改造前是 `AlertDialog.show()`（系统居中弹窗）→ 现改为与置顶确认同源的 CustomDialog。
   * ⚠️ showDeleteConfirm 会纳入 syncBackState 的 favCanGoBack 判定，
   * 保证弹窗打开时系统返回键只关弹窗、不退页面（由下方 @Watch 回调代调 syncBackState）。
   */
  @State @Watch('onShowDeleteConfirmChanged') showDeleteConfirm: boolean = false;
  /** 弹窗展示快照：标题（恒为「删除收藏」，用 @State 是为了能 @Link 进弹窗） */
  @State deleteConfirmTitle: string = '删除收藏';
  /** 弹窗展示快照：正文说明（打开时算好选中条数） */
  @State deleteConfirmMessage: string = '';
  /** 弹窗展示快照：主按钮文案（恒为「删除」） */
  @State deleteConfirmConfirmLabel: string = '删除';

  /**
   * 分类删除确认显隐（系统 CustomDialog + API 26 沉浸光感）。
   * 改造前是 `AlertDialog.show()`（系统白底居中弹窗，与刚关掉的玻璃菜单卡观感割裂）→
   * 现改为与置顶 / 批量删除确认**同源**的 ConfirmDialogCard（danger=true → 危险红主按钮）。
   * ⚠️ 同样纳入 syncBackState 的 favCanGoBack 判定（由下方 @Watch 回调代调）。
   */
  @State @Watch('onShowRemoveCatConfirmChanged') showRemoveCatConfirm: boolean = false;
  /** 待删分类（唯一真源；文案快照在 requestRemoveCategory 里直接算好，无需 @Watch 桥接） */
  @State removeCatTarget: FavCategory | null = null;
  /** 弹窗展示快照：标题（恒为「删除分类」） */
  @State removeCatConfirmTitle: string = '删除分类';
  /** 弹窗展示快照：正文说明（打开前算好分类名与条数） */
  @State removeCatMessage: string = '';
  /** 弹窗展示快照：主按钮文案（恒为「删除」） */
  @State removeCatConfirmLabel: string = '删除';

  /**
   * 置顶确认弹窗控制器（系统 CustomDialog + API 26 沉浸光感）。
   * 几何与进吧页一键签到弹窗同源：宽度 dialogCardWidth()、圆角 32vp、底部锚点 dy -110、遮罩 #06000000。
   * 玻璃层交给 options.systemMaterial（ImmMaterial.dialog()），卡内不再自绘那五项。
   * ⚠️ customStyle 必须为 false —— customStyle=true 时弹窗背景强制透明、圆角归 0 且材质不生效。
   */
  private pinConfirmController: CustomDialogController = new CustomDialogController({
    builder: ConfirmDialogCard({
      isDark: $isDark,
      fontScale: $fontScale,
      dialogTitle: $pinConfirmTitle,
      dialogMessage: $pinConfirmMessage,
      confirmLabel: $pinConfirmConfirmLabel,
      onCancel: () => { this.closePinConfirm(); },
      onConfirm: () => { this.confirmPin(); }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Bottom,
    offset: { dx: 0, dy: -110 },
    maskColor: '#06000000',
    cornerRadius: 32,
    width: this.dialogCardWidth(),
    customStyle: false,
    systemMaterial: ImmMaterial.dialog(),
    openAnimation: { duration: 220, curve: Curve.EaseOut },
    closeAnimation: { duration: 200, curve: Curve.EaseInOut },
    // 点遮罩/返回键统一交给 closePinConfirm（与自绘浮层时期语义一致）
    onWillDismiss: () => { this.closePinConfirm(); }
  });

  /**
   * 批量删除收藏确认弹窗控制器。
   * 几何与置顶确认弹窗**逐项一致**（宽度 dialogCardWidth() / 圆角 32vp / 底部锚点 dy -110 /
   * 遮罩 #06000000 / 同一 ImmMaterial.dialog()），即两弹窗出现在屏幕同一位置；
   * 唯一差异是 danger=true → 主按钮走危险红（ImmMaterial.danger + #CCF5222D）。
   */
  private deleteConfirmController: CustomDialogController = new CustomDialogController({
    builder: ConfirmDialogCard({
      isDark: $isDark,
      fontScale: $fontScale,
      dialogTitle: $deleteConfirmTitle,
      dialogMessage: $deleteConfirmMessage,
      confirmLabel: $deleteConfirmConfirmLabel,
      danger: true,
      onCancel: () => { this.closeDeleteConfirm(); },
      onConfirm: () => { this.confirmDeleteSelectedDialog(); }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Bottom,
    offset: { dx: 0, dy: -110 },
    maskColor: '#06000000',
    cornerRadius: 32,
    width: this.dialogCardWidth(),
    customStyle: false,
    systemMaterial: ImmMaterial.dialog(),
    openAnimation: { duration: 220, curve: Curve.EaseOut },
    closeAnimation: { duration: 200, curve: Curve.EaseInOut },
    // 点遮罩/返回键统一交给 closeDeleteConfirm
    onWillDismiss: () => { this.closeDeleteConfirm(); }
  });

  /**
   * 分类删除确认弹窗控制器。
   * 几何与置顶 / 批量删除确认弹窗**逐项一致**（同一 dialogCardWidth() / 圆角 32vp / 底部锚点 dy -110 /
   * 遮罩 #06000000 / 同一 ImmMaterial.dialog()），danger=true → 主按钮走危险红。
   * 至此收藏页三处二次确认（置顶 / 批量删除收藏 / 删除分类）全部为同款玻璃卡。
   */
  private removeCatConfirmController: CustomDialogController = new CustomDialogController({
    builder: ConfirmDialogCard({
      isDark: $isDark,
      fontScale: $fontScale,
      dialogTitle: $removeCatConfirmTitle,
      dialogMessage: $removeCatMessage,
      confirmLabel: $removeCatConfirmLabel,
      danger: true,
      onCancel: () => { this.closeRemoveCatConfirm(); },
      onConfirm: () => { this.confirmRemoveCategoryDialog(); }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Bottom,
    offset: { dx: 0, dy: -110 },
    maskColor: '#06000000',
    cornerRadius: 32,
    width: this.dialogCardWidth(),
    customStyle: false,
    systemMaterial: ImmMaterial.dialog(),
    openAnimation: { duration: 220, curve: Curve.EaseOut },
    closeAnimation: { duration: 200, curve: Curve.EaseInOut },
    // 点遮罩/返回键统一交给 closeRemoveCatConfirm
    onWillDismiss: () => { this.closeRemoveCatConfirm(); }
  });

  /**
   * 分类管理弹窗控制器。几何与置顶/删除确认弹窗同源
   * （宽度 dialogCardWidth() / 圆角 32vp / 底部锚点 dy -110 / 遮罩 #06000000 / 同一 ImmMaterial.dialog()）。
   * 内容由顶层 CategoryManageDialog 承载（信息行 + 菜单行 + 取消按钮）。
   */
  private categoryManageController: CustomDialogController = new CustomDialogController({
    builder: CategoryManageDialog({
      isDark: $isDark,
      fontScale: $fontScale,
      catName: $manageCatName,
      catCover: $manageCatCover,
      catIcon: $manageCatIcon,
      catCount: $manageCatCount,
      renameMode: $categoryRenameMode,
      inputValue: $categoryInputValue,
      onCommitRename: () => { this.commitCategoryRename(); },
      onRemove: () => { this.removeCategoryFromDialog(); },
      onCancel: () => { this.closeCategoryManage(); }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Bottom,
    offset: { dx: 0, dy: -110 },
    maskColor: '#06000000',
    cornerRadius: 32,
    width: this.dialogCardWidth(),
    customStyle: false,
    systemMaterial: ImmMaterial.dialog(),
    openAnimation: { duration: 220, curve: Curve.EaseOut },
    closeAnimation: { duration: 200, curve: Curve.EaseInOut },
    // 点遮罩/返回键统一交给 closeCategoryManage
    onWillDismiss: () => { this.closeCategoryManage(); }
  });

  /**
   * 备份弹窗控制器（系统 CustomDialog + API 26 沉浸光感）。
   * 几何与其他弹窗**逐项一致**（宽度 dialogCardWidth() / 圆角 32vp / 底部锚点 dy -110 /
   * 遮罩 #06000000 / 同一 ImmMaterial.dialog()），即出现在屏幕同一处。
   * 内容由顶层 BackupDialogCard 承载（标题区 + 两条分隔线 + 导出/导入两行 + 取消按钮）。
   */
  private backupDialogController: CustomDialogController = new CustomDialogController({
    builder: BackupDialogCard({
      isDark: $isDark,
      fontScale: $fontScale,
      // 导出：先写文案快照（宿主算好分类数）→ 关本弹窗 → 打开导出授权弹窗（语义与改造前一致）
      onExport: () => {
        this.exportDialogMessage = `将导出 ${this.categories.length} 个自定义分类及分类内帖子为 JSON 文件。`;
        this.showBackupDialog = false;
        this.showExportDialog = true;
      },
      // 导入：先关本弹窗再拉起系统文件选择器（语义与改造前一致）
      onImport: () => {
        this.showBackupDialog = false;
        this.beginImport();
      },
      onCancel: () => { this.closeBackupDialog(); }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Bottom,
    offset: { dx: 0, dy: -110 },
    maskColor: '#06000000',
    cornerRadius: 32,
    width: this.dialogCardWidth(),
    customStyle: false,
    systemMaterial: ImmMaterial.dialog(),
    openAnimation: { duration: 220, curve: Curve.EaseOut },
    closeAnimation: { duration: 200, curve: Curve.EaseInOut },
    // 点遮罩/返回键统一交给 closeBackupDialog（与自绘浮层时期语义一致）
    onWillDismiss: () => { this.closeBackupDialog(); }
  });

  /**
   * 导出授权弹窗控制器（系统 CustomDialog + API 26 沉浸光感）。
   * 位置 / 几何 / 材质与「备份 / 分类管理 / 确认」等弹窗**逐项一致**（同一 width / 圆角 32vp /
   * 底部锚点 dy -110 / 遮罩 #06000000 / 同一 `ImmMaterial.dialog()`），即出现在屏幕同一处。
   * `actionWidth` = 卡片宽 - 32vp，给卡内 SaveButton 安全控件用数值宽度（安全控件对百分比/calc 容错差）。
   */
  private exportDialogController: CustomDialogController = new CustomDialogController({
    builder: ExportDialogCard({
      isDark: $isDark,
      fontScale: $fontScale,
      dialogMessage: $exportDialogMessage,
      actionWidth: this.dialogCardWidth() - 32,
      onAuthorized: () => { this.confirmExport(); },
      onCancel: () => { this.closeExportDialog(); }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Bottom,
    offset: { dx: 0, dy: -110 },
    maskColor: '#06000000',
    cornerRadius: 32,
    width: this.dialogCardWidth(),
    customStyle: false,
    systemMaterial: ImmMaterial.dialog(),
    openAnimation: { duration: 220, curve: Curve.EaseOut },
    closeAnimation: { duration: 200, curve: Curve.EaseInOut },
    // 点遮罩/返回键统一交给 closeExportDialog
    onWillDismiss: () => { this.closeExportDialog(); }
  });

  /**
   * 弹窗卡片宽度（vp）= 屏幕宽 - 48vp，等价于改造前自绘浮层的 `calc(100% - 48vp)`。
   * ArkTS 的 Dimension 只接受数值 / 百分比 / 资源，不接受 calc 字符串，故换算成数值。
   * 取屏幕宽（display）而非窗口宽：弹窗容器宽度本身还受系统上限（默认 400vp）约束，
   * 分屏 / 折叠态由该上限兜底。
   */
  private dialogCardWidth(): number {
    const info: display.Display = display.getDefaultDisplaySync();
    const widthVp: number = info.width / info.densityPixels;
    // §4.3 改动七（2026-09-14 拍板「弹窗不拉伸」）：平板封顶 400（系统弹窗默认宽度上限），
    // 与 ThreadList §4.8 T-H 同款；手机档 312 < 400 逐像素不变。
    return Math.max(200, Math.min(400, widthVp - 48));
  }

  /** showPinConfirm 变化即驱动系统弹窗 open/close（保留既有 `this.showPinConfirm = x` 调用点） */
  onShowPinConfirmChanged(): void {
    // @Watch 一变量只挂一个，故此处代劳原先挂在 showPinConfirm 上的 syncBackState
    this.syncBackState();
    if (this.showPinConfirm) {
      this.pinConfirmController.open();
    } else {
      this.pinConfirmController.close();
    }
  }

  /** showDeleteConfirm 变化即驱动系统弹窗 open/close（同步刷新 favCanGoBack 回退判定） */
  onShowDeleteConfirmChanged(): void {
    this.syncBackState();
    if (this.showDeleteConfirm) {
      this.deleteConfirmController.open();
    } else {
      this.deleteConfirmController.close();
    }
  }

  /** showRemoveCatConfirm 变化即驱动系统弹窗 open/close（同步刷新 favCanGoBack 回退判定） */
  onShowRemoveCatConfirmChanged(): void {
    this.syncBackState();
    if (this.showRemoveCatConfirm) {
      this.removeCatConfirmController.open();
    } else {
      this.removeCatConfirmController.close();
    }
  }

  /** showCategoryManage 变化即驱动系统弹窗 open/close（保留既有 `this.showCategoryManage = x` 调用点） */
  onShowCategoryManageChanged(): void {
    // @Watch 一变量只挂一个，故此处代劳原先挂在 showCategoryManage 上的 syncBackState
    this.syncBackState();
    if (this.showCategoryManage) {
      this.categoryManageController.open();
    } else {
      this.categoryManageController.close();
    }
  }

  /**
   * manageTargetCat 变化 → 同步弹窗展示快照。
   * 重命名成功后宿主重指向新对象，快照随之刷新，弹窗信息行名称实时更新（与改造前行为一致）。
   * ⚠️ 清空（null）时刻意**保留上一次快照**：关闭动画期间弹窗仍在渲染，快照清空会让卡内内容突然变空。
   */
  onManageCatChanged(): void {
    const cat: FavCategory | null = this.manageTargetCat;
    if (!cat) {
      return;
    }
    this.manageCatName = cat.name;
    this.manageCatCover = cat.cover;
    this.manageCatIcon = cat.icon;
    this.manageCatCount = this.categoryCountOf(cat.id);
  }

  /** showBackupDialog 变化即驱动系统弹窗 open/close（保留既有 `this.showBackupDialog = x` 调用点） */
  onShowBackupDialogChanged(): void {
    // @Watch 一变量只挂一个，故此处代劳原先挂在 showBackupDialog 上的 syncBackState
    this.syncBackState();
    if (this.showBackupDialog) {
      this.backupDialogController.open();
    } else {
      this.backupDialogController.close();
    }
  }

  /** showExportDialog 变化即驱动系统弹窗 open/close（保留既有 `this.showExportDialog = x` 调用点） */
  onShowExportDialogChanged(): void {
    // @Watch 一变量只挂一个，故此处代劳原先挂在 showExportDialog 上的 syncBackState
    this.syncBackState();
    if (this.showExportDialog) {
      this.exportDialogController.open();
    } else {
      this.exportDialogController.close();
    }
  }

  // BUG-03 收藏本地搜索（匹配收藏帖子标题 / 吧名 / 分类名，不依赖网络接口）
  @State @Watch('syncBackState') searchMode: boolean = false;
  @State searchKeyword: string = '';
  @State backupBusy: boolean = false;
  @State draggingCatIndex: number = -1;   // v1.8 拖拽排序：当前被拖分类在 categories 内的下标（-1 = 未拖拽）
  @State draggingCatId: string = '';      // v1.15 拖拽中的分类 id（按 id 判断占位/避让，不依赖对象引用，避免 persistCategoryOrder 换新对象后 ForEach 复用旧 c 导致 indexOf=-1 全部误判为占位）
  @State dragTargetIndex: number = -1;    // v1.12 拖拽排序：目标插入位对应的 List 绝对下标（-1 = 无，高亮提示用）
  @State dragListBottomPad: number = 0;    // v1.15 拖拽期间给 List 加的底部 padding（让 List 可滚动总高增加一个卡位，translate 后卡落在内容范围内，配合 scrollBy 跟随避免裁切）
  @StorageLink('fontScale') fontScale: number = 1.0;
  /** 页面可见时自增，强制组件重建使字号实时生效 */
  @State fontSizeTick: number = 0;
  // 字号全局变更广播（2026-09-13）：@Watch 回写 fontScale 强制本页依赖刷新（离屏缓存不重绘兜底）
  @StorageLink('fontTick') @Watch('onFontTick') fontTick: number = 0;
  // 「列数调整」档位广播（2026-09-18，个性化 → 列数调整）：@Watch 回写本地档位 → 列数函数按新档返回并强制回到列表顶部
  // （离屏期间 @StorageLink 同步不重绘，故用 tick + 本地 @State 兜底，同 fontTick 范式）
  @StorageLink('columnModeTick') @Watch('onColumnModeTick') columnModeTick: number = 0;
  @State columnMode: number = 0;

  onPageShow(): void {
    this.fontSizeTick++;
    // v1.18 页面回到前台：先本地缓存回流（外部收藏/取消已即时写缓存，零网络），再按冷却决定是否网络同步
    if (this.accountId.length === 0) {
      return;
    }
    if (this.loading || this.syncRunning) {
      return; // loadAll/同步进行中，结束后自行触发
    }
    this.refreshFromCache().then(() => {
      if (this.accountId.length > 0 && !this.loading && !this.loadingMore && !this.syncRunning && !this.syncing) {
        this.tryNetSync();
      }
    }).catch(() => {
    });
  }
  @StorageLink('favEditing') favEditing: boolean = false;
  // BUG-01 系统返回：favCanGoBack = 收藏页当前是否处于可回退层级（Index.onBackPress 据此拦截/放行）；
  // favBackRequest = Index 转发来的返回请求自增计数，FavoriteTab 消费后逐级回退
  @StorageLink('favCanGoBack') @Watch('syncBackState') favCanGoBack: boolean = false;
  @StorageLink('favBackRequest') @Watch('onBackRequest') favBackRequest: number = 0;
  // 收藏页常驻（不随 Tab 切换重建）：登录/登出/换号通知（Index.refreshLoginState 检测到登录态变化时递增）
  @StorageLink('favLoginRefresh') @Watch('onLoginRefresh') favLoginRefresh: number = 0;
  // 深色模式切换通知：本页或宿主切换深色时递增 → 重读 isDarkMode()，保持与 ForumsTab/MineTab/HomeTab 同链路
  @StorageLink('darkTick') @Watch('onDarkTick') darkTick: number = 0;
  /**
   * 分类集合变更通知（2026-09-17）：详情页长按收藏钮 → 分类面板内新建分类 / 完成归类落库后由**写方**自增。
   * 本页是 Index 内常驻 @Component（非 @Entry，onPageShow 不回调），外部改分类没有任何回流通路，
   * 不订阅则新建的分类必须重启 App 才会出现在「自定义分类」里。
   */
  @StorageLink('favCatChanged') @Watch('onCatChanged') favCatChanged: number = 0;
  /**
   * 进入收藏页通知（2026-09-17）：宿主 Index.switchTab 切到收藏 Tab（含重复点击收藏 Tab）时自增。
   * 本页是常驻组件（非 @Entry，onPageShow 不回调）→ 此前切进来只能看到上次的内容，必须手动下拉刷新。
   * 回调走 silentRefresh()：本地缓存回流 + 云端首页增量合并，全程不置 loading/refreshing/syncing 任一亮态、
   * 不弹 toast；内容无变化时连 @State 都不写，列表零重绘（无感）。
   */
  @StorageLink('favEnterTick') @Watch('onEnterTick') favEnterTick: number = 0;
  private pageSize: number = 20;
  private accountId: string = '';
  // v1.15 拖拽分类列表：Scroller 用于拖拽中手动 scrollBy 跟随手指；lastAutoScrollTime 节流
  private categoryScroller: Scroller = new Scroller();
  /** §4.3 改动六·方案四：半屏排序面板内单列 List 的独立 Scroller（面板 / 主列表各自滚动，互不干扰） */
  private panelCategoryScroller: Scroller = new Scroller();
  /** §4.3 改动六 B 二次更正：分类内帖子排序面板独立 Scroller（WaterFlow 不支持 List 拖拽 → 帖子排序同收面板） */
  private panelThreadScroller: Scroller = new Scroller();
  private lastAutoScrollTime: number = 0;
  // v1.13 加载冷却：内容不足一屏时 onReachEnd 会连续触发，加冷却避免"不断加载中"刷屏
  private lastLoadMoreAt: number = 0;
  /** 进入页静默刷新的最小间隔（ms）：防切换动画期间/快速来回切 Tab 引发的请求风暴（2026-09-17） */
  private static readonly ENTER_REFRESH_MIN_GAP_MS: number = 3000;
  private lastEnterRefreshAt: number = 0;
  // v1.12 收藏夹/分类返回保持列表滚动位置：Scroller + 偏移记录（if/else 切换销毁 List 后 onAppear 恢复）
  private folderScroller: Scroller = new Scroller();
  private folderScrollOffset: number = 0;
  private categoryScrollOffset: number = 0;
  private avatarCache: Map<string, string> = forumAvatarMemoryCache;
  private knownTids: Set<string> = new Set<string>();
  // 吧头像加载队列（受限并发 + 在途去重 + 失败标记，防止吧数多时 frs/page 请求风暴触发风控/ANR）
  private avatarPending: Set<string> = new Set<string>();
  private avatarFailed: Set<string> = new Set<string>();
  private avatarQueue: string[] = [];
  private avatarInFlight: number = 0;
  private avatarDirty: boolean = false;
  // v1.17 性能：吧内最大收藏时间键预计算缓存（重建一次 O(T)，folderTimeOf 查表 O(1)，
  // 避免 rebuildFolders 对每个吧实时遍历全部帖子 O(吧×帖) 造成主线程卡顿）
  private threadTimeCache: Map<string, number> = new Map<string, number>();
  // v1.18 自动同步：缓存空标记 / 后台全量同步中（顶部轻提示） / 防重入 / 同步元数据（冷却 + 每日全量校正）
  private localCacheEmpty: boolean = false;
  @State syncing: boolean = false;
  private syncRunning: boolean = false;
  private syncMeta: SyncMeta = { lastNetAt: 0, fullAt: 0 };
  private static readonly AVATAR_CONCURRENCY: number = 2;
  // v1.18 自动同步参数：30min 网络冷却（冷却内进页零请求，本地缓存秒开）/ 每日一次全量校正 / 页间隔 300ms / 单次上限 100 页（超出交滚动触底）/ 每 20 页阶段落盘一次
  private static readonly SYNC_COOL_MS: number = 30 * 60 * 1000;
  private static readonly FULL_SYNC_INTERVAL_MS: number = 24 * 60 * 60 * 1000;
  private static readonly SYNC_PAGE_DELAY_MS: number = 300;
  private static readonly SYNC_MAX_PAGES: number = 100;
  private static readonly SYNC_FLUSH_STEP: number = 20;
  private static readonly AVATAR_CACHE_KEY: string = 'fav_avatar_map';
  // v1.8 拖拽排序：自定义分类 List 前置固定项数（占位 + 新建卡 + 未分类卡），拖拽索引转换用
  private static readonly CAT_LIST_PREPEND: number = 3;
  // v1.15 拖拽体验：分类卡固定高度（封面48 + 上下padding 16*2）与手动避让步长（卡高 + List间距12）
  private static readonly CATEGORY_CARD_HEIGHT: number = 80;
  private static readonly CATEGORY_CARD_STEP: number = 92;
  /** §4.3 帖子多列「列均衡」阈值（vp，方案 B 滞回，与 §4.9 同款）：轮转列与最短列估算高差超此值才补位 */
  private static readonly FAV_COL_BALANCE_THRESHOLD: number = 240;
  // BUG-04 自绘简约线条图标（Feather 风格 path，24x24 视口）
  private static readonly ICON_PIN: string = 'M21 10c0 7-9 13-9 13s-9-6-9-13a9 9 0 0 1 18 0z M12 10a3 3 0 1 0 0-6 3 3 0 0 0 0 6z';

  // 帖子列表视图顶部占位（沉浸式列表：避免顶栏遮挡首项 + 预留呼吸）；吧内帖子 / 分类内帖子统一，避免"占位依赖 selectedForum"导致分类内帖子上方空白过多
  private static readonly THREAD_TOP_PLACEHOLDER: number = 98;
  // 整页滑入期间豁免内部左右推拉转场：首次挂载（Tab 切换进入）用 IDENTITY 不播内部动画，
  // 避免与页面级滑入叠加成"双层动画"；之后点开/返回收藏夹（内部导航）firstMount 已为 false，照常播放
  private firstMount: boolean = true;
  // v1.16 分类 Tab（吧分类/自定义分类）切换动画期间标志：新视图挂载时豁免其内部列表过渡（listBaseTransition/detailPushTransition），
  // 避免"外层整页滑入 + 内层 -30% 微移淡入"双重动画叠加；动画结束后由 setTimeout 复位，恢复内部导航过渡
  private catTabSwitching: boolean = false;

  aboutToAppear(): void {
    MaterialManager.init();
    this.isDark = isDarkMode();
    this.accountId = AuthManager.getInstance().getUser()?.userId ?? '';
    // 顶部渐显带覆盖基准（平板收窄用）：取屏幕长边（竖屏视口高），窗口未 attach 时忽略
    try {
      const d: display.Display = display.getDefaultDisplaySync();
      this.fadeCoverVp = Math.max(d.width, d.height) / d.densityPixels;
      // §4.3 改动四：pageWidth / pageHeight 首帧初值（§6.2 第 6 步：形态判定须首帧就位，防多列闪变）
      this.pageWidth = d.width / d.densityPixels;
      this.pageHeight = d.height / d.densityPixels;
    } catch (e) {
      // 忽略：窗口未 attach，fadeCoverVp 保持 0 → topFadeStop() 回退手机比例；pageWidth=0 → favColumns()=1 安全方向
    }
    // 「列数调整」档位初值（2026-09-18）：冷启动首帧即按已选档渲染
    // （UsageHabitsManager.init 的 columnModeTick 可能早于本页构造，@Watch 不会补触发，故此处直读）
    this.columnMode = readColumnMode();
    this.syncBackState();
    this.initSortState();
    this.loadAll();
  }

  /**
   * 「列数调整」档位变化（个性化页写入 → `columnModeTick` 广播）：
   * 回写本地档位（列数函数随新档返回）→ 强制回到列表顶部（分类 / 收藏夹 / 分类面板 / 帖子面板四个列表）。
   * 默认档（0）与原自动适配逐像素一致，仅「用户显式选择」后才改变列数。
   */
  private onColumnModeTick(): void {
    this.columnMode = readColumnMode();
    try {
      this.categoryScroller.scrollTo({ xOffset: 0, yOffset: 0 });
      this.folderScroller.scrollTo({ xOffset: 0, yOffset: 0 });
      this.panelThreadScroller.scrollTo({ xOffset: 0, yOffset: 0 });
      this.panelCategoryScroller.scrollTo({ xOffset: 0, yOffset: 0 });
    } catch (e) {
    }
  }

  /** v1.11 加载排序偏好与本地收藏时间 / 分类内帖子自定义顺序（异步，不阻塞首屏） */
  private async initSortState(): Promise<void> {
    const store = FavoriteStore.getInstance();
    const mode: number = await store.loadSortMode(this.accountId);
    this.sortMode = mode as SortMode;
    this.collectTimes = await store.loadCollectTimes(this.accountId);
    this.threadOrders = await store.loadThreadOrders(this.accountId);
    // v1.17 收藏时间映射异步就绪后重建时间键缓存，避免 fetchPage 先于 initSortState 完成时排序时间缺失
    if (this.allThreads.length > 0) {
      this.rebuildTimeCache();
      this.rebuildFolders();
    }
  }

  private async loadAll(): Promise<void> {
    this.loadState = FavLoadState.Loading;
    this.loading = true;
    try {
      if (this.accountId.length === 0) {
        this.notLoggedIn = true;
        this.loadState = FavLoadState.Empty;
        return;
      }
      this.notLoggedIn = false;
      await this.loadAvatarCache();
      await this.loadSyncMeta();
      this.pinnedFolders = await FavoriteStore.getInstance().loadPinnedFolders(this.accountId);
      this.pinnedThreads = await FavoriteStore.getInstance().loadPinnedThreads(this.accountId);
      this.categories = await FavoriteStore.getInstance().loadCategories(this.accountId);
      this.mappings = await FavoriteStore.getInstance().loadMappings(this.accountId);
      // v1.18 秒开：本地缓存非空先直接渲染（不阻塞首屏），网络增量/全量随后台静默完成
      if (await this.showCachedIfAny()) {
        return;
      }
      await this.fetchPage(0, true);
      this.loadState = this.folders.length > 0 ? FavLoadState.Success : FavLoadState.Empty;
      // v1.18 缓存为空（重装/首装）：进入后自动后台全量预热，补齐计数/排序/本地缓存
      if (this.localCacheEmpty) {
        setTimeout(() => { this.tryNetSync(); }, 0);
      }
    } catch (e) {
      const message: string = e instanceof Error ? e.message : `${e}`;
      this.errorMsg = message.trim().length > 0 ? message : '收藏加载失败，请稍后重试';
      this.loadState = FavLoadState.Error;
    } finally {
      this.loading = false;
    }
  }

  /**
   * v1.18 秒开路径：本地收藏缓存非空 → 直接渲染并触发后台同步（冷却内零网络请求）；
   * 返回 true 表示已用缓存完成首屏（调用方无需再走网络首页）。
   */
  private async showCachedIfAny(): Promise<boolean> {
    try {
      const raw = await CacheManager.getInstance().get(`${CACHE_KEY.PERSONAL_COLLECTED}_${this.accountId}`);
      if (!raw || raw.length === 0) {
        this.localCacheEmpty = true;
        return false;
      }
      const cached = JSON.parse(raw) as PersonalContentItem[];
      if (!Array.isArray(cached) || cached.length === 0) {
        this.localCacheEmpty = true;
        return false;
      }
      this.localCacheEmpty = false;
      this.allThreads = this.mergeByTid(cached.concat(this.allThreads));
      for (const t of this.allThreads) {
        this.knownTids.add(t.tid);
      }
      this.loadState = this.allThreads.length > 0 ? FavLoadState.Success : FavLoadState.Empty;
      this.rebuildFolders();
      // 首屏后按冷却决定网络同步（loading 置 false 后执行）
      setTimeout(() => { this.tryNetSync(); }, 0);
      return true;
    } catch (e) {
      return false; // 解析失败回退网络路径
    }
  }

  /** 拉取云端收藏分页并合并本地缓存（增量聚合，严禁全量拉取） */
  private async fetchPage(offset: number, isFirst: boolean): Promise<void> {
    const cloud = await TiebaService.getInstance().fetchCollectedThreads(this.accountId, offset, this.pageSize);
    let base: PersonalContentItem[] = [];
    if (isFirst) {
      const cachedRaw = await CacheManager.getInstance().get(`${CACHE_KEY.PERSONAL_COLLECTED}_${this.accountId}`);
      // v1.17 记录本地缓存是否为空（重装后首次为 true，用于触发后台预热）
      this.localCacheEmpty = !cachedRaw;
      if (cachedRaw) {
        try {
          base = JSON.parse(cachedRaw) as PersonalContentItem[];
        } catch (e) {
          base = [];
        }
      }
    }
    this.allThreads = this.mergeByTid(base.concat(cloud).concat(isFirst ? [] : this.allThreads));
    for (const t of this.allThreads) {
      this.knownTids.add(t.tid);
    }
    await CacheManager.getInstance().put(`${CACHE_KEY.PERSONAL_COLLECTED}_${this.accountId}`, JSON.stringify(this.allThreads));
    this.hasMore = cloud.length >= this.pageSize;
    this.rebuildFolders();
  }

  /** 按 tid 去重，保留后出现（云端）记录 */
  private mergeByTid(items: PersonalContentItem[]): PersonalContentItem[] {
    const map: Map<string, PersonalContentItem> = new Map<string, PersonalContentItem>();
    for (const item of items) {
      if (item.accountId !== undefined && item.accountId !== this.accountId) {
        continue;
      }
      const key: string = item.tid.trim();
      if (key.length === 0) {
        continue;
      }
      map.set(key, item);
    }
    return Array.from(map.values());
  }

  /** 按吧名增量聚合收纳夹 */
  private rebuildFolders(): void {
    this.rebuildTimeCache();
    const pinMap: Map<string, number> = new Map<string, number>();
    for (const p of this.pinnedFolders) {
      pinMap.set(p.id, p.pinnedAt);
    }
    const group: Map<string, number> = new Map<string, number>();
    for (const t of this.allThreads) {
      const name: string = t.forumName || '贴吧';
      group.set(name, (group.get(name) ?? 0) + 1);
    }
    const list: FolderItem[] = [];
    group.forEach((count: number, name: string) => {
      list.push({
        forumName: name,
        avatarUrl: this.avatarCache.get(name) ?? '',
        threadCount: count,
        pinned: pinMap.has(name),
        pinnedAt: pinMap.get(name) ?? 0,
      });
    });
    // 排序：置顶恒顶（按置顶时间倒序），其余按 v1.11 排序模式（名称正/倒序、时间正/倒序）
    list.sort((a: FolderItem, b: FolderItem): number => {
      if (a.pinned !== b.pinned) {
        return a.pinned ? -1 : 1;
      }
      if (a.pinned && b.pinned) {
        return b.pinnedAt - a.pinnedAt;
      }
      if (this.sortMode === SortMode.TimeAsc || this.sortMode === SortMode.TimeDesc) {
        const ta: number = this.folderTimeOf(a.forumName);
        const tb: number = this.folderTimeOf(b.forumName);
        return this.sortMode === SortMode.TimeAsc ? ta - tb : tb - ta;
      }
      // 名称排序：英文首字母 + 中文拼音首字母全局混排，同首字母按完整名称拼音序
      return this.sortMode === SortMode.NameDesc
        ? compareByName(a.forumName, b.forumName, true)
        : compareByName(a.forumName, b.forumName, false);
    });
    this.folders = list;
    // v1.17 头像入队延后到宏任务，避免与首屏渲染 / 分页合并抢主线程（首字占位先展示，头像稍后填充）
    setTimeout(() => {
      for (const f of list) {
        if (f.avatarUrl.length === 0) {
          this.enqueueAvatarLoad(f.forumName);
        }
      }
    }, 0);
  }

  /** v1.17 预计算「吧 → 吧内最大收藏时间」映射（O(T) 一次遍历），供 folderTimeOf 查表 O(1) */
  private rebuildTimeCache(): void {
    const map: Map<string, number> = new Map<string, number>();
    for (const t of this.allThreads) {
      const ts: number | undefined = this.collectTimes[t.tid];
      let v: number = 0;
      if (typeof ts === 'number' && ts > 0) {
        v = ts;
      } else {
        const lastTime: number = parseInt(t.createTime, 10);
        v = isNaN(lastTime) ? 0 : lastTime * 1000;
      }
      if (v > 0) {
        const name: string = t.forumName || '贴吧';
        const cur: number = map.get(name) ?? 0;
        if (v > cur) {
          map.set(name, v);
        }
      }
    }
    this.threadTimeCache = map;
  }

  /** v1.11 收纳夹时间键（ms）：吧内帖子最大收藏时间（本地增量优先，兜底 lastTime 秒→ms） */
  private folderTimeOf(forumName: string): number {
    return this.threadTimeCache.get(forumName) ?? 0;
  }

  /** v1.11 帖子时间键（ms）：本地增量收藏时间优先，兜底 lastTime（秒级 → ms） */
  private threadTimeOf(card: PostCardItem): number {
    const ts: number | undefined = this.collectTimes[card.tid];
    if (typeof ts === 'number' && ts > 0) {
      return ts;
    }
    return card.lastTime > 0 ? card.lastTime * 1000 : 0;
  }

  /** v1.11 非置顶段帖子排序比较（custom 仅分类内使用，orderIndex 兜底接口序） */
  private compareThread(a: PostCardItem, b: PostCardItem, custom: boolean): number {
    switch (this.sortMode) {
      case SortMode.NameAsc:
        return compareByName(a.title, b.title, false);
      case SortMode.NameDesc:
        return compareByName(a.title, b.title, true);
      case SortMode.TimeAsc:
        return this.threadTimeOf(a) - this.threadTimeOf(b);
      case SortMode.TimeDesc:
        return this.threadTimeOf(b) - this.threadTimeOf(a);
      case SortMode.Custom:
        return custom ? 0 : a.orderIndex - b.orderIndex;
      default:
        return a.orderIndex - b.orderIndex;
    }
  }

  /** 从本地缓存恢复吧头像映射（避免进程重启后对全部吧重新请求触发风控） */
  private async loadAvatarCache(): Promise<void> {
    try {
      const raw = await CacheManager.getInstance().get(FavoriteTab.AVATAR_CACHE_KEY);
      if (raw) {
        const map = JSON.parse(raw) as Record<string, string>;
        for (const key of Object.keys(map)) {
          if (map[key].length > 0) {
            this.avatarCache.set(key, map[key]);
          }
        }
      }
    } catch (e) {
      // 解析失败忽略，走内存缓存
    }
  }

  private saveAvatarCache(): void {
    const obj: Record<string, string> = {};
    this.avatarCache.forEach((v: string, k: string) => {
      obj[k] = v;
    });
    CacheManager.getInstance().put(FavoriteTab.AVATAR_CACHE_KEY, JSON.stringify(obj)).catch(() => {});
  }

  /** 头像加载入队（在途去重 + 失败标记，重复触发与并发风暴均被拦截） */
  private enqueueAvatarLoad(forumName: string): void {
    if (forumName.length === 0) {
      return;
    }
    if (this.avatarCache.has(forumName) || this.avatarPending.has(forumName) || this.avatarFailed.has(forumName)) {
      return;
    }
    this.avatarPending.add(forumName);
    this.avatarQueue.push(forumName);
    this.drainAvatarQueue();
  }

  /** 受限并发消费队列（同一时间最多 AVATAR_CONCURRENCY 个 frs/page 请求） */
  private drainAvatarQueue(): void {
    while (this.avatarInFlight < FavoriteTab.AVATAR_CONCURRENCY && this.avatarQueue.length > 0) {
      const name = this.avatarQueue.shift();
      if (name === undefined) {
        break;
      }
      this.avatarInFlight++;
      this.loadForumAvatar(name).finally(() => {
        this.avatarInFlight--;
        this.avatarPending.delete(name);
        this.drainAvatarQueue();
      });
    }
    if (this.avatarInFlight === 0 && this.avatarQueue.length === 0 && this.avatarDirty) {
      this.avatarDirty = false;
      this.saveAvatarCache();
    }
  }

  /** 异步填充吧头像（失败走首字占位，本次会话不重试避免风暴）
   *  v1.17 成功回填改为局部更新对应卡片（不再整表 rebuildFolders），
   *  避免 N 张头像逐一触发 O(吧×帖) 时间重算与 List 全量重渲染 */
  private async loadForumAvatar(forumName: string): Promise<void> {
    try {
      const url = await TiebaService.getInstance().fetchForumAvatarByName(forumName);
      if (url.length > 0) {
        this.avatarCache.set(forumName, url);
        this.avatarDirty = true;
        const idx: number = this.folders.findIndex((f: FolderItem): boolean => f.forumName === forumName);
        if (idx >= 0) {
          const cur: FolderItem = this.folders[idx];
          const next: FolderItem[] = this.folders.slice();
          next[idx] = {
            forumName: cur.forumName,
            avatarUrl: url,
            threadCount: cur.threadCount,
            pinned: cur.pinned,
            pinnedAt: cur.pinnedAt,
          };
          this.folders = next;
        }
      } else {
        this.avatarFailed.add(forumName);
      }
    } catch (e) {
      this.avatarFailed.add(forumName);
    }
  }

  /** 吧内帖子列表（本地过滤 + 排序降级 + 置顶恒顶） */
  private forumThreads(): PostCardItem[] {
    const pinMap: Map<string, number> = new Map<string, number>();
    for (const p of this.pinnedThreads) {
      pinMap.set(p.id, p.pinnedAt);
    }
    const list: PostCardItem[] = [];
    const filtered: PersonalContentItem[] = this.allThreads.filter(
      (t: PersonalContentItem): boolean => t.forumName === this.selectedForum);
    for (let i = 0; i < filtered.length; i++) {
      const t = filtered[i];
      const lastTime: number = parseInt(t.createTime, 10);
      list.push({
        tid: t.tid,
        pid: t.id,
        title: t.title,
        abstract: t.abstract,
        forumName: t.forumName,
        author: t.author,
        replyNum: t.replyNum,
        coverUrl: '',
        lastTime: isNaN(lastTime) ? 0 : lastTime,
        pinned: pinMap.has(t.tid),
        pinnedAt: pinMap.get(t.tid) ?? 0,
        orderIndex: i,
      });
    }
    list.sort((a: PostCardItem, b: PostCardItem): number => {
      if (a.pinned !== b.pinned) {
        return a.pinned ? -1 : 1;
      }
      if (a.pinned && b.pinned) {
        return b.pinnedAt - a.pinnedAt;
      }
      return this.compareThread(a, b, false);
    });
    return list;
  }

  /** 统一 Toast（第四批 · 统一样式），省略 context 与类型默认 Info */
  private toast(message: string, type: ToastType = ToastType.Info): void {
    ToastUtil.show(this.getUIContext(), message, type);
  }

  // ===== 备份导出 / 导入（第七批 · P2-a，入口 §4.4，schema §2.5）=====

  /**
   * v1.15.9 备份入口（v1.15.11 起为系统 CustomDialog + API 26 沉浸光感，替代系统 ActionSheet，
   * 与其他弹窗同视觉；内容由顶层 BackupDialogCard 承载）。
   */
  private showBackupSheet(): void {
    if (this.backupBusy) {
      return;
    }
    Haptic.light();
    this.showBackupDialog = true;
  }

  /** 关闭备份弹窗（点遮罩 / 返回键 / 取消按钮 的统一入口，与其余弹窗写法一致） */
  private closeBackupDialog(): void {
    this.showBackupDialog = false;
  }

  /** 关闭导出授权弹窗（点遮罩 / 返回键 / 取消按钮 / 导出完成后 的统一入口） */
  private closeExportDialog(): void {
    this.showExportDialog = false;
  }

  /**
   * 导出执行（saveButton 安全控件授权成功后回调）：
   * 构建 JSON（schema §2.5）→ DocumentViewPicker.save 弹系统保存框（用户选位置）→ 写入目标 uri
   * 降级：save 面板不可用（异常）→ 写入沙箱 filesDir 并在 Toast 提示完整路径，保证任何环境都有文件产出
   */
  private async confirmExport(): Promise<void> {
    if (this.backupBusy) {
      return;
    }
    this.backupBusy = true;
    try {
      const store = FavoriteStore.getInstance();
      const folders = await store.buildBackupFolders(this.accountId, (tid: string): string => '');
      const payload: BackupPayload = {
        app: 'TiebaPura',
        version: 1,
        exportedAt: new Date().toISOString(),
        folders: folders
      };
      const jsonText: string = JSON.stringify(payload);
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const fileName: string = `tieba_favorite_backup_${Date.now()}.json`;
      let saveUris: string[] = [];
      try {
        // 系统保存面板（免权限，用户选择保存位置），返回目标 uri
        const documentPicker = new picker.DocumentViewPicker(context);
        saveUris = await documentPicker.save({ newFileNames: [fileName] });
      } catch (saveErr) {
        // 降级：系统保存面板不可用（无文件管理服务/模拟器）→ 写沙箱，路径提示用户
        const fallbackPath: string = `${context.filesDir}/${fileName}`;
        const fb = fileIo.openSync(fallbackPath, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
        fileIo.writeSync(fb.fd, jsonText);
        fileIo.closeSync(fb);
        this.toast(`系统保存面板不可用，备份已写入沙箱目录（${fileName}）`, ToastType.Info);
        return;
      }
      if (saveUris.length > 0) {
        const dest = fileIo.openSync(saveUris[0], fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
        fileIo.writeSync(dest.fd, jsonText);
        fileIo.closeSync(dest);
        this.toast('备份已导出', ToastType.Success);
      } else {
        this.toast('已取消导出');
      }
    } catch (e) {
      const errMsg: string = e instanceof Error ? e.message : `${e}`;
      this.toast(`导出失败：${errMsg}`, ToastType.Error);
    } finally {
      this.backupBusy = false;
      this.closeExportDialog();
    }
  }

  /**
   * 导入执行：DocumentViewPicker 选 JSON → 读取 → 校验（§6）→ 增量合并 → Toast 汇总
   * 校验：app ≠ TiebaPura 或 version ≠ 1 或 folders 非数组 → 整体拒绝 `备份文件版本不支持`
   */
  private async beginImport(): Promise<void> {
    if (this.backupBusy) {
      return;
    }
    this.backupBusy = true;
    try {
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const documentPicker = new picker.DocumentViewPicker(context);
      const result: string[] = await documentPicker.select({
        fileSuffixFilters: ['json', 'txt']
      });
      if (!result || result.length === 0 || result[0].length === 0) {
        return; // 用户取消选择
      }
      const file = fileIo.openSync(result[0], fileIo.OpenMode.READ_ONLY);
      const stat = fileIo.statSync(file.fd);
      const buf = new ArrayBuffer(stat.size);
      fileIo.readSync(file.fd, buf);
      fileIo.closeSync(file);
      const decoder = util.TextDecoder.create('utf-8');
      const jsonText: string = decoder.decodeToString(new Uint8Array(buf));
      let parsed: Record<string, Object>;
      try {
        parsed = JSON.parse(jsonText) as Record<string, Object>;
      } catch (parseErr) {
        this.toast('备份文件格式错误，无法解析', ToastType.Error);
        return;
      }
      if ((parsed.app as string) !== 'TiebaPura' || (parsed.version as number) !== 1 || !Array.isArray(parsed.folders)) {
        this.toast('备份文件版本不支持', ToastType.Error);
        return;
      }
      const folders: BackupFolder[] = parsed.folders as BackupFolder[];
      const store = FavoriteStore.getInstance();
      const summary: BackupImportSummary = await store.importBackup(this.accountId, folders,
        (tid: string): string => {
          const item = this.allThreads.find((t: PersonalContentItem): boolean => t.tid === tid);
          return item ? item.forumName : '';
        });
      this.categories = await store.loadCategories(this.accountId);
      this.mappings = await store.loadMappings(this.accountId);
      // v1.17 导入后先拉取最新云端收藏（失败静默），让备份分类内帖子及时显示
      try {
        await this.fetchPage(0, true);
      } catch (e) {
        // 网络失败不阻断导入结果提示
      }
      // v1.18 导入后后台受控全量补齐（不阻塞导入收尾），让备份分类内帖子尽量显示、计数准确
      setTimeout(() => { this.startFullSync(); }, 0);
      // v1.17 缺失统计：备份中不在本地收藏缓存/已拉列表的 tid（刷新收藏后可显示）
      const known: Set<string> = new Set<string>();
      for (const t of this.allThreads) {
        known.add(t.tid);
      }
      let missingCount: number = 0;
      for (const f of folders) {
        if (!f || !Array.isArray(f.threads)) {
          continue;
        }
        for (const t of f.threads) {
          if (t && typeof t.tid === 'string' && t.tid.trim().length > 0 && !known.has(t.tid)) {
            missingCount++;
          }
        }
      }
      Haptic.light();
      const missingTip: string = missingCount > 0
        ? `；其中 ${missingCount} 条帖子暂不在收藏缓存，刷新收藏后可显示`
        : '';
      this.toast(`成功导入 ${summary.added} 个新分类，合并 ${summary.merged} 个同名分类，跳过 ${summary.skipped} 条无效记录${missingTip}`,
        ToastType.Success);
    } catch (e) {
      const errMsg: string = e instanceof Error ? e.message : `${e}`;
      this.toast(`导入失败：${errMsg}`, ToastType.Error);
    } finally {
      this.backupBusy = false;
    }
  }

  private async loadMore(): Promise<void> {
    if (this.loading || this.loadingMore || !this.hasMore) {
      return;
    }
    // v1.13 冷却 800ms：内容不足一屏时 onReachEnd 会立即反复触发，避免连续拉取刷"加载中"
    const now: number = Date.now();
    if (now - this.lastLoadMoreAt < 800) {
      return;
    }
    this.lastLoadMoreAt = now;
    this.loadingMore = true;
    try {
      await this.fetchPage(this.allThreads.length, false);
    } catch (e) {
      this.toast('更多收藏加载失败，请稍后重试', ToastType.Error);
    } finally {
      this.loadingMore = false;
    }
  }

  // ===== v1.18 自动同步（进页秒开 + 后台补齐 + 变更回流 + 删除/幽灵校正）=====

  /**
   * 从本地缓存重读合并（外部收藏动作已即时写缓存，零网络）。
   * 仅在集合有差异时重建，避免每次可见都空转重渲染。
   */
  private async refreshFromCache(): Promise<void> {
    try {
      const raw = await CacheManager.getInstance().get(`${CACHE_KEY.PERSONAL_COLLECTED}_${this.accountId}`);
      if (!raw || raw.length === 0) {
        return;
      }
      const cached = JSON.parse(raw) as PersonalContentItem[];
      if (!Array.isArray(cached) || cached.length === 0) {
        return;
      }
      const merged: PersonalContentItem[] = this.mergeByTid(cached.concat(this.allThreads));
      const oldSet: Set<string> = new Set<string>();
      for (const t of this.allThreads) {
        oldSet.add(t.tid);
      }
      const cachedSet: Set<string> = new Set<string>();
      for (const c of cached) {
        cachedSet.add(c.tid);
      }
      let changed: boolean = merged.length !== this.allThreads.length;
      if (!changed) {
        for (const c of cached) {
          if (!oldSet.has(c.tid)) {
            changed = true;
            break;
          }
        }
      }
      if (!changed) {
        for (const t of this.allThreads) {
          if (!cachedSet.has(t.tid)) {
            changed = true;
            break;
          }
        }
      }
      if (!changed) {
        return;
      }
      this.allThreads = merged;
      const nextKnown: Set<string> = new Set<string>();
      for (const t of merged) {
        nextKnown.add(t.tid);
      }
      this.knownTids = nextKnown;
      // 外部取消收藏的帖（缓存已移除而本地仍有）即时清理残留映射与置顶，防分类计数虚高/幽灵残留
      const removedTids: string[] = [];
      for (const tid of oldSet) {
        if (!cachedSet.has(tid)) {
          removedTids.push(tid);
        }
      }
      if (removedTids.length > 0) {
        this.mappings = await FavoriteStore.getInstance().removeMappingsByTids(this.accountId, removedTids);
        await this.cleanupPins();
      }
      this.rebuildFolders();
    } catch (e) {
      // 解析失败忽略（走网络路径）
    }
  }

  /** 网络同步决策：缓存空 → 立即全量（重装预热）；30min 冷却内零请求；距上次全量 >24h 每日校正；否则轻量增量 */
  private tryNetSync(): void {
    if (this.localCacheEmpty) {
      this.startFullSync();
      return;
    }
    const now: number = Date.now();
    if (now - this.syncMeta.lastNetAt < FavoriteTab.SYNC_COOL_MS) {
      return;
    }
    if (now - this.syncMeta.fullAt > FavoriteTab.FULL_SYNC_INTERVAL_MS) {
      this.startFullSync();
    } else {
      this.syncIncremental();
    }
  }

  /**
   * 轻量增量：拉云端最新一页合并（发现新增/首页取消；写缓存一次并重建）。
   * 2026-09-17 起兼作"进入页无感刷新"的网络侧：内容与本地完全一致时零副作用返回（不赋值 @State /
   * 不落盘 / 不重建），全程无加载态与轻提示，用户感知不到刷新动作。
   */
  private async syncIncremental(): Promise<void> {
    if (this.loading || this.loadingMore || this.syncRunning) {
      return;
    }
    this.syncRunning = true;
    const started: number = Date.now();
    try {
      const cloud = await TiebaService.getInstance().fetchCollectedThreads(this.accountId, 0, this.pageSize);
      // 无感化（2026-09-17）：与本地完全一致 → 零副作用返回；有变化时合并顺序改为"本地在前 + 云端在后"，
      // 同 tid 由云端记录覆盖（字段刷新），已有项顺序保持不变、新项追加到末尾，尽量减小列表跳动。
      if (cloud.length > 0 && this.cloudDiffersFromLocal(cloud)) {
        this.allThreads = this.mergeByTid(this.allThreads.concat(cloud));
        for (const t of this.allThreads) {
          this.knownTids.add(t.tid);
        }
        await CacheManager.getInstance().put(`${CACHE_KEY.PERSONAL_COLLECTED}_${this.accountId}`, JSON.stringify(this.allThreads));
        this.rebuildFolders();
      }
    } catch (e) {
      // 静默：本地内容不受影响，用户可下拉刷新手动重试
    } finally {
      // 成功/失败均记录时间，避免 30min 内反复重试风暴
      this.markSyncTime(started);
      this.syncRunning = false;
    }
  }

  /**
   * v1.18 受控全量同步（升级自 v1.17 预热，解决"逐页全量重建+落盘"的性能与请求风暴问题）：
   * - 串行翻页 + 300ms 页间隔 + 每 20 页阶段落盘一次，期间不逐页 rebuild；
   * - 单次上限 100 页（约 2000 帖），超出交给滚动触底 loadMore；
   * - 用户下拉刷新/触底时让位（不全量剔除，避免误删未拉部分）；
   * - 全量完整且无打断时，以云为准剔除本地幽灵帖（云端已取消收藏的残留），
   *   并清理孤儿分类映射与失效置顶，最后一次性重建计数/排序；
   * - 失败静默保留已拉部分；期间顶部显示"正在同步收藏"轻提示，不阻塞 UI。
   */
  private async startFullSync(): Promise<void> {
    if (this.loading || this.loadingMore || this.syncRunning || this.syncing) {
      return;
    }
    this.syncRunning = true;
    this.syncing = true;
    const started: number = Date.now();
    const localBase: PersonalContentItem[] = this.allThreads.slice();
    const collected: PersonalContentItem[] = [];
    let full: boolean = false;     // 云端已拉尽
    let cleanRun: boolean = true;  // 期间无用户操作打断
    const cacheKey: string = `${CACHE_KEY.PERSONAL_COLLECTED}_${this.accountId}`;
    try {
      let offset: number = 0;
      let pages: number = 0;
      while (pages < FavoriteTab.SYNC_MAX_PAGES) {
        if (this.loadingMore || this.loading || this.refreshing) {
          cleanRun = false; // 用户触底/下拉：让位
          break;
        }
        const page: PersonalContentItem[] = await TiebaService.getInstance()
          .fetchCollectedThreads(this.accountId, offset, this.pageSize);
        if (page.length === 0) {
          full = true;
          break;
        }
        for (const p of page) {
          if (p.tid.trim().length > 0) {
            collected.push(p);
          }
        }
        offset += page.length;
        pages++;
        if (page.length < this.pageSize) {
          full = true;
          break;
        }
        if (pages % FavoriteTab.SYNC_FLUSH_STEP === 0) {
          // 阶段落盘：合并写缓存但不重建，避免逐页全量重建卡顿
          this.allThreads = this.mergeByTid(collected.concat(this.allThreads));
          for (const t of this.allThreads) {
            this.knownTids.add(t.tid);
          }
          await CacheManager.getInstance().put(cacheKey, JSON.stringify(this.allThreads));
        }
        await new Promise<void>((resolve: () => void) => {
          setTimeout(() => resolve(), FavoriteTab.SYNC_PAGE_DELAY_MS);
        });
      }
      if (full && cleanRun) {
        // 全量完整：以云为准（剔除本地已取消收藏的幽灵帖）
        const cloudSet: Set<string> = new Set<string>();
        for (const c of collected) {
          cloudSet.add(c.tid.trim());
        }
        this.allThreads = this.mergeByTid(collected.concat(localBase))
          .filter((t: PersonalContentItem): boolean => cloudSet.has(t.tid.trim()));
      } else {
        // 部分成功（上限/让位/异常）：仅追加合并，不剔除
        this.allThreads = this.mergeByTid(collected.concat(this.allThreads));
      }
      for (const t of this.allThreads) {
        this.knownTids.add(t.tid);
      }
      await CacheManager.getInstance().put(cacheKey, JSON.stringify(this.allThreads));
      if (full && cleanRun) {
        await this.cleanupAfterFullSync();
        this.syncMeta.fullAt = Date.now();
      }
      this.rebuildFolders();
    } catch (e) {
      // 失败静默：已拉部分阶段落盘过；有新增数据则再合并落盘一次
      try {
        this.allThreads = this.mergeByTid(collected.concat(this.allThreads));
        await CacheManager.getInstance().put(cacheKey, JSON.stringify(this.allThreads));
        this.rebuildFolders();
      } catch (e2) {
      }
    } finally {
      this.markSyncTime(started);
      this.syncing = false;
      this.syncRunning = false;
    }
  }

  /** 全量成功后清理：分类映射中已不在收藏的孤儿帖（防幽灵计数）+ 失效置顶 */
  private async cleanupAfterFullSync(): Promise<void> {
    const valid: Set<string> = new Set<string>();
    for (const t of this.allThreads) {
      valid.add(t.tid);
    }
    const orphanIds: string[] = [];
    const seen: Set<string> = new Set<string>();
    for (const m of this.mappings) {
      if (!valid.has(m.tid) && !seen.has(m.tid)) {
        seen.add(m.tid);
        orphanIds.push(m.tid);
      }
    }
    if (orphanIds.length > 0) {
      this.mappings = await FavoriteStore.getInstance().removeMappingsByTids(this.accountId, orphanIds);
    }
    await this.cleanupPins();
  }

  /** 读取同步元数据（按账号隔离；换号/登出后随 loadAll 重新读取） */
  private async loadSyncMeta(): Promise<void> {
    try {
      const raw = await CacheManager.getInstance().get(`${CACHE_KEY.PERSONAL_COLLECTED_META}_${this.accountId}`);
      if (raw) {
        const parsed: SyncMeta = JSON.parse(raw) as SyncMeta;
        this.syncMeta = {
          lastNetAt: typeof parsed.lastNetAt === 'number' ? parsed.lastNetAt : 0,
          fullAt: typeof parsed.fullAt === 'number' ? parsed.fullAt : 0,
        };
      } else {
        this.syncMeta = { lastNetAt: 0, fullAt: 0 };
      }
    } catch (e) {
      this.syncMeta = { lastNetAt: 0, fullAt: 0 };
    }
  }

  /** 记录一次网络同步时间（增量/全量成功或失败均记录，防 30min 内重复风暴） */
  private markSyncTime(at: number): void {
    this.syncMeta.lastNetAt = at;
    CacheManager.getInstance().put(
      `${CACHE_KEY.PERSONAL_COLLECTED_META}_${this.accountId}`,
      JSON.stringify(this.syncMeta)
    ).catch(() => {
    });
  }

  /** v1.18 顶部轻提示：后台全量同步进行中（插入收藏夹/分类列表首项前） */
  @Builder
  SyncHintRow() {
    Row({ space: 8 }) {
      LoadingProgress()
        .width(14)
        .height(14)
        .color(Theme.brand())
      Text('正在同步收藏…')
        .fontSize(fs(12, this.fontScale))
        .fontColor(Theme.textSecondary(this.isDark))
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ top: 10, bottom: 10 })
    .backgroundColor(Theme.bgCard(this.isDark))
    // 卡片圆角 26：与收藏页其余卡片、首页 ThreadCard、详情页卡片统一口径（不借用全局 Radius.lg）
    .borderRadius(26)
  }

  /** v1.12 恢复列表滚动位置：List 重建（if/else 切换销毁）后 onAppear 调用，offset<=0 跳过 */
  private restoreListScroll(scroller: Scroller, offset: number): void {
    if (offset <= 0) {
      return;
    }
    // 等一帧确保 List 布局完成后再滚动，避免 scrollTo 在重建首帧无效
    setTimeout(() => {
      scroller.scrollTo({ xOffset: 0, yOffset: offset, animation: { duration: 0 } });
    }, 0);
  }

  private async handleRefresh(): Promise<void> {
    if (this.refreshing) {
      return;
    }
    this.exitEditMode();
    this.refreshing = true;
    try {
      await this.fetchPage(0, true);
      await this.cleanupPins();
      // v1.18 手动下拉已同步云端首页，计入冷却避免紧随其后重复网络同步
      this.markSyncTime(Date.now());
      this.toast('刷新成功', ToastType.Success);
    } catch (e) {
      this.toast('刷新失败，请稍后重试', ToastType.Error);
    } finally {
      this.refreshing = false;
    }
  }

  /** 置顶清理口径：置顶项已不在"累计已拉取集合"则清除（禁仅比对刷新首页） */
  private async cleanupPins(): Promise<void> {
    const validThreads: PinRecord[] = this.pinnedThreads.filter(
      (p: PinRecord): boolean => this.knownTids.has(p.id));
    if (validThreads.length !== this.pinnedThreads.length) {
      this.pinnedThreads = validThreads;
      await FavoriteStore.getInstance().savePinnedThreads(this.accountId, validThreads);
    }
    const names: Set<string> = new Set<string>();
    for (const t of this.allThreads) {
      names.add(t.forumName);
    }
    const validFolders: PinRecord[] = this.pinnedFolders.filter(
      (p: PinRecord): boolean => names.has(p.id));
    if (validFolders.length !== this.pinnedFolders.length) {
      this.pinnedFolders = validFolders;
      await FavoriteStore.getInstance().savePinnedFolders(this.accountId, validFolders);
      this.rebuildFolders();
    }
  }

  private async togglePinFolder(forumName: string): Promise<void> {
    const pinned: boolean = this.pinnedFolders.some((p: PinRecord): boolean => p.id === forumName);
    this.pinnedFolders = await FavoriteStore.getInstance().setFolderPinned(this.accountId, forumName, !pinned);
    this.rebuildFolders();
    Haptic.light();
    this.toast(pinned ? `已取消置顶「${forumName}」` : `已置顶「${forumName}」`, ToastType.Success);
  }

  private async togglePinThread(tid: string): Promise<void> {
    const pinned: boolean = this.pinnedThreads.some((p: PinRecord): boolean => p.id === tid);
    this.pinnedThreads = await FavoriteStore.getInstance().setThreadPinned(this.accountId, tid, !pinned);
    Haptic.light();
    this.toast(pinned ? '已取消置顶该帖子' : '已置顶该帖子', ToastType.Success);
  }

  /** v1.11 排序下拉面板入口 */
  private openSortMenu(): void {
    this.showSortMenu = true;
  }

  /** v1.11 排序模式中文文案 */
  private sortModeLabel(mode: SortMode): string {
    switch (mode) {
      case SortMode.NameAsc:
        return '名称正序';
      case SortMode.NameDesc:
        return '名称倒序';
      case SortMode.TimeAsc:
        return '最早添加';
      case SortMode.TimeDesc:
        return '最新添加';
      default:
        return '自定义排序';
    }
  }

  /** v1.11 「自定义排序」是否可用：仅自定义分类 Tab（分类列表 + 分类内帖子），吧分类两界面置灰 */
  private canCustomSort(): boolean {
    return this.categoryTab === FavCategoryTab.Custom;
  }

  /**
   * §4.3 改动六·方案四：打开半屏排序面板（排序菜单「自定义排序」与长按分类卡两个入口共用）。
   * 打开即切 Custom（与手机点该项语义一致）：① 面板内 PostCard 长按让位于拖拽（sortMode !== Custom 守卫）；
   * ② 主列表多列立即按自定义顺序显示。
   */
  private openCategorySortPanel(): void {
    this.showSortMenu = false;
    this.sortMode = SortMode.Custom;
    FavoriteStore.getInstance().saveSortMode(this.accountId, SortMode.Custom as number).catch(() => {});
    this.rebuildFolders();
    Haptic.light();
    this.showSortPanel = true;
  }

  /** v1.11 应用排序模式（置灰项 Toast 提示不切换；持久化 + Toast） */
  private applySortMode(mode: SortMode, disabled: boolean): void {
    if (disabled) {
      this.toast('自定义排序仅支持自定义分类');
      return;
    }
    // §4.3 改动六·方案四（2026-09-14 拍板）：平板档「自定义排序」改为打开半屏排序面板
    // （面板内单列长按拖拽，确认后落盘 Custom 顺序）；入口 / 按钮数量不变，仅平板档行为分叉。
    if (mode === SortMode.Custom && this.favColumns() > 1) {
      this.openCategorySortPanel();
      return;
    }
    if (this.sortMode === mode) {
      this.showSortMenu = false;
      return;
    }
    this.sortMode = mode;
    FavoriteStore.getInstance().saveSortMode(this.accountId, mode as number).catch(() => {});
    this.rebuildFolders();
    this.showSortMenu = false;
    Haptic.light();
    this.toast(`已切换为${this.sortModeLabel(mode)}`, ToastType.Success);
  }

  // ===== 编辑态（第二批：批量取消收藏）=====
  private isSelected(tid: string): boolean {
    return this.selectedTids.indexOf(tid) >= 0;
  }

  private toggleSelect(tid: string): void {
    const idx: number = this.selectedTids.indexOf(tid);
    if (idx >= 0) {
      this.selectedTids = this.selectedTids.filter((t: string): boolean => t !== tid);
    } else {
      this.selectedTids = [...this.selectedTids, tid];
    }
    Haptic.light();
  }

  private selectedCategoryName(): string {
    return this.categories.find((c: FavCategory): boolean => c.id === this.selectedCategoryId)?.name ?? '未分类';
  }

  /** 当前上下文帖子列表（吧内 or 分类内） */
  private currentThreads(): PostCardItem[] {
    if (this.selectedCategoryId.length > 0) {
      return this.categoryThreads();
    }
    return this.forumThreads();
  }

  private allSelected(): boolean {
    const tids: string[] = this.currentThreads().map((c: PostCardItem): string => c.tid);
    return tids.length > 0 && tids.every((t: string): boolean => this.isSelected(t));
  }

  private toggleSelectAll(): void {
    const tids: string[] = this.currentThreads().map((c: PostCardItem): string => c.tid);
    this.selectedTids = this.allSelected() ? [] : tids;
  }

  // ===== 自定义分类（第三批：CRUD + 移入/移出 + 一帖多分类）=====
  private categoryCountOf(categoryId: string): number {
    if (categoryId === CATEGORY_DEFAULT_ID) {
      // 未分类 = 没有任何自定义分类映射的帖子数（一帖多分类下不能简单用"总数-映射数"）
      const mappedTids: Set<string> = new Set<string>();
      for (const m of this.mappings) {
        if (m.categoryId !== CATEGORY_DEFAULT_ID) {
          mappedTids.add(m.tid);
        }
      }
      let count: number = 0;
      for (const t of this.allThreads) {
        if (!mappedTids.has(t.tid)) {
          count++;
        }
      }
      return count;
    }
    let count: number = 0;
    for (const m of this.mappings) {
      if (m.categoryId === categoryId) {
        count++;
      }
    }
    return count;
  }

  /** 当前分类下的帖子（本地过滤，映射 tid → allThreads；未分类 = 无自定义映射） */
  private categoryThreads(): PostCardItem[] {
    const tidSet: Set<string> = new Set<string>();
    if (this.selectedCategoryId === CATEGORY_DEFAULT_ID) {
      for (const m of this.mappings) {
        if (m.categoryId !== CATEGORY_DEFAULT_ID) {
          tidSet.add(m.tid);
        }
      }
      const items: PersonalContentItem[] = this.allThreads.filter(
        (t: PersonalContentItem): boolean => !tidSet.has(t.tid));
      return this.reorderByCustom(this.toPostCards(items));
    }
    for (const m of this.mappings) {
      if (m.categoryId === this.selectedCategoryId) {
        tidSet.add(m.tid);
      }
    }
    const items: PersonalContentItem[] = [];
    for (const t of this.allThreads) {
      if (tidSet.has(t.tid)) {
        items.push(t);
      }
    }
    return this.reorderByCustom(this.toPostCards(items));
  }

  /** 原始帖子 → 卡片模型（排序：置顶恒顶 + 收藏时间倒序降级为本地索引序） */
  private toPostCards(items: PersonalContentItem[]): PostCardItem[] {
    const pinMap: Map<string, number> = new Map<string, number>();
    for (const p of this.pinnedThreads) {
      pinMap.set(p.id, p.pinnedAt);
    }
    const list: PostCardItem[] = [];
    for (let i = 0; i < items.length; i++) {
      const t = items[i];
      const lastTime: number = parseInt(t.createTime, 10);
      list.push({
        tid: t.tid,
        pid: t.id,
        title: t.title,
        abstract: t.abstract,
        forumName: t.forumName || '贴吧',
        author: t.author,
        replyNum: t.replyNum,
        coverUrl: '',
        lastTime: isNaN(lastTime) ? 0 : lastTime,
        pinned: pinMap.has(t.tid),
        pinnedAt: pinMap.get(t.tid) ?? 0,
        orderIndex: i,
      });
    }
    list.sort((a: PostCardItem, b: PostCardItem): number => {
      if (a.pinned !== b.pinned) {
        return a.pinned ? -1 : 1;
      }
      if (a.pinned && b.pinned) {
        return b.pinnedAt - a.pinnedAt;
      }
      return this.compareThread(a, b, false);
    });
    return list;
  }

  /** v1.11 自定义分类列表按当前排序模式重排（Custom = 拖拽 sortOrder 原序；持久化数据不动） */
  private sortedCategories(): FavCategory[] {
    const list: FavCategory[] = this.categories.slice();
    switch (this.sortMode) {
      case SortMode.NameAsc:
        list.sort((a: FavCategory, b: FavCategory): number => a.name.localeCompare(b.name));
        break;
      case SortMode.NameDesc:
        list.sort((a: FavCategory, b: FavCategory): number => b.name.localeCompare(a.name));
        break;
      case SortMode.TimeAsc:
        list.sort((a: FavCategory, b: FavCategory): number => a.createdAt - b.createdAt);
        break;
      case SortMode.TimeDesc:
        list.sort((a: FavCategory, b: FavCategory): number => b.createdAt - a.createdAt);
        break;
      default:
        list.sort((a: FavCategory, b: FavCategory): number => a.sortOrder - b.sortOrder);
        break;
    }
    return list;
  }

  /** v1.11 分类内帖子：Custom 模式按 threadOrders[selectedCategoryId] 重排（未记录 / 新增帖按原序排末尾） */
  private reorderByCustom(cards: PostCardItem[]): PostCardItem[] {
    if (this.sortMode !== SortMode.Custom) {
      return cards;
    }
    const order: string[] = this.threadOrders[this.selectedCategoryId] ?? [];
    if (order.length === 0) {
      return cards;
    }
    const pos: Map<string, number> = new Map<string, number>();
    for (let i = 0; i < order.length; i++) {
      pos.set(order[i], i);
    }
    const known: PostCardItem[] = [];
    const unknown: PostCardItem[] = [];
    for (const c of cards) {
      if (pos.has(c.tid)) {
        known.push(c);
      } else {
        unknown.push(c);
      }
    }
    known.sort((a: PostCardItem, b: PostCardItem): number => (pos.get(a.tid) ?? 0) - (pos.get(b.tid) ?? 0));
    return known.concat(unknown);
  }

  private beginCreateCategory(): void {
    this.categoryInputVisible = true;
    this.categoryEditingId = '';
    this.categoryInputValue = '';
  }

  private closeCategoryInput(): void {
    this.categoryInputVisible = false;
    this.categoryEditingId = '';
    this.categoryInputValue = '';
  }

  private async commitCategoryInput(): Promise<void> {
    const name: string = this.categoryInputValue.trim();
    if (name.length === 0) {
      this.toast('请输入分类名称');
      return;
    }
    if (name.length > 12) {
      this.toast('分类名称最多 12 个字');
      return;
    }
    // 重名拦截（与移入分类面板内「新建分类」同口径）：同名分类不再重复创建；
    // 改名时排除自身，避免未改名直接保存被误拦。
    const duplicated: boolean = this.categories.some((c: FavCategory): boolean =>
      c.name === name && c.id !== this.categoryEditingId);
    if (duplicated) {
      this.toast('该分类已存在');
      return;
    }
    const store = FavoriteStore.getInstance();
    if (this.categoryEditingId.length === 0) {
      this.categories = await store.addCategory(this.accountId, name, '📁');
    } else {
      this.categories = await store.renameCategory(this.accountId, this.categoryEditingId, name);
    }
    this.closeCategoryInput();
    Haptic.light();
    this.toast('已保存', ToastType.Success);
  }

  /** v1.15.8 分类管理弹窗内原地重命名：保存后刷新分类列表并同步弹窗内 manageTargetCat 对象 */
  private async commitCategoryRename(): Promise<void> {
    const name: string = this.categoryInputValue.trim();
    if (name.length === 0) {
      this.toast('请输入分类名称');
      return;
    }
    if (name.length > 12) {
      this.toast('分类名称最多 12 个字');
      return;
    }
    const cat = this.manageTargetCat;
    if (!cat) {
      this.cancelCategoryRename();
      return;
    }
    if (name === cat.name) {
      this.cancelCategoryRename();
      return;
    }
    // 重名拦截（与分类列表内改名同口径）：弹窗内重命名也排除自身比对
    const duplicated: boolean = this.categories.some((c: FavCategory): boolean =>
      c.name === name && c.id !== cat.id);
    if (duplicated) {
      this.toast('该分类已存在');
      return;
    }
    const store = FavoriteStore.getInstance();
    this.categories = await store.renameCategory(this.accountId, cat.id, name);
    // 用新对象重指向 manageTargetCat，@State 重新赋值触发弹窗信息行名称实时更新
    const updated = this.categories.find((c: FavCategory) => c.id === cat.id);
    if (updated) {
      this.manageTargetCat = updated;
    }
    this.categoryRenameMode = false;
    Haptic.light();
    this.toast('已保存', ToastType.Success);
  }

  /** v1.15.8 取消弹窗内重命名：退出编辑态，信息行恢复显示原名称 */
  private cancelCategoryRename(): void {
    this.categoryRenameMode = false;
    this.categoryInputValue = this.manageTargetCat?.name ?? '';
  }

  /** 删除分类二次确认（v1.15.10 起为系统 CustomDialog 玻璃卡，替掉 AlertDialog 白底居中弹窗） */
  private requestRemoveCategory(cat: FavCategory): void {
    // 先写弹窗展示快照，再置显隐（@Watch 立即 open，避免首帧读到旧文案）
    this.removeCatTarget = cat;
    this.removeCatMessage = `删除「${cat.name}」后，其中的 ${this.categoryCountOf(cat.id)} 条帖子将移回未分类，分类本身不可恢复。`;
    this.showRemoveCatConfirm = true;
  }

  /** 关闭分类删除确认弹窗（遮罩 / 返回键 / 取消 统一入口） */
  private closeRemoveCatConfirm(): void {
    this.showRemoveCatConfirm = false;
    this.removeCatTarget = null;
  }

  /** 确认删除分类：先取目标再关窗（closeRemoveCatConfirm 会清空 removeCatTarget） */
  private confirmRemoveCategoryDialog(): void {
    const cat: FavCategory | null = this.removeCatTarget;
    this.closeRemoveCatConfirm();
    if (cat) {
      this.confirmRemoveCategory(cat.id);
    }
  }

  private async confirmRemoveCategory(id: string): Promise<void> {
    const cat: FavCategory | undefined = this.categories.find((c: FavCategory): boolean => c.id === id);
    const cover: string = cat?.cover ?? '';
    const result = await FavoriteStore.getInstance().removeCategory(this.accountId, id);
    this.categories = result.categories;
    this.mappings = result.mappings;
    if (cover.length > 0) {
      try { fileIo.unlinkSync(cover); } catch (e) { /* 忽略 */ }
    }
    this.toast('分类已删除', ToastType.Success);
  }

  // ===== 移入分类（编辑态底部操作，多选勾选面板：一帖可同时在多个分类，§4.2）=====
  // 面板 UI / 勾选 / 新建分类入口已收敛到 components/FavCategoryPicker.ets（收藏页与详情页单一来源），
  // 此处只留两端：打开前的快照初始化、完成后的替换式落库。

  /** 打开移入面板：按当前选中帖快照初始化各分类勾选态（已含全部选中帖的分类默认勾选） */
  private openMovePanel(): void {
    const tids: string[] = this.selectedTids;
    if (tids.length === 0) {
      this.toast('请先选择要移入的帖子');
      return;
    }
    this.movePanelTids = [...tids];
    const checked: string[] = [];
    const allUnclassified: boolean = tids.every((tid: string) =>
      !this.mappings.some((m: CategoryMapping): boolean => m.tid === tid && m.categoryId !== CATEGORY_DEFAULT_ID));
    if (allUnclassified) {
      checked.push(CATEGORY_DEFAULT_ID);
    }
    for (const c of this.categories) {
      const included: number = tids.filter((tid: string) =>
        this.mappings.some((m: CategoryMapping): boolean => m.tid === tid && m.categoryId === c.id)).length;
      if (included === tids.length) {
        checked.push(c.id);
      }
    }
    this.moveChecked = checked;
    // 每次打开都回收起态：上次遗留的输入行不出现（组件内草稿由 beginCreate 自行清空）
    this.pickerCreating = false;
    this.showMovePanel = true;
  }

  /** 应用勾选：替换式写入（幂等，重复加入同分类自动去重）——由面板组件「完成」回调（onDone）驱动 */
  private async applyMove(checked: string[]): Promise<void> {
    const tids: string[] = this.movePanelTids;
    if (tids.length === 0) {
      return;
    }
    const moveToUnclassified: boolean = checked.indexOf(CATEGORY_DEFAULT_ID) >= 0;
    const targetIds: string[] = moveToUnclassified ? [] : checked;
    const store = FavoriteStore.getInstance();
    for (const tid of tids) {
      const item = this.allThreads.find((t: PersonalContentItem): boolean => t.tid === tid);
      this.mappings = await store.setThreadCategories(this.accountId, tid, item?.forumName ?? '', targetIds);
    }
    this.showMovePanel = false;
    this.exitEditMode();
    const names: string[] = checked.map((id: string) =>
      id === CATEGORY_DEFAULT_ID ? '未分类' : (this.categories.find((c: FavCategory): boolean => c.id === id)?.name ?? ''));
    const label: string = names.length > 0 ? names.join('、') : '未分类';
    Haptic.light();
    this.toast(`已移入「${label}」（帖子仍保留在吧分类）`, ToastType.Success);
  }

  private enterEditFor(tid: string): void {
    this.editMode = true;
    this.favEditing = true;
    this.selectedTids = [tid];
  }

  private exitEditMode(): void {
    this.editMode = false;
    this.favEditing = false;
    this.selectedTids = [];
  }

  /** BUG-01：任一子视图/编辑态/弹层状态变更后，同步"收藏页可回退标记"给 Index.onBackPress 判定 */
  private syncBackState(): void {
    const canBack: boolean = this.searchMode
      || this.selectedForum.length > 0
      || this.selectedCategoryId.length > 0
      || this.editMode
      || this.categoryInputVisible
      || this.showMovePanel
      || this.showCategoryManage
      || this.showPinConfirm
      || this.showDeleteConfirm
      || this.showRemoveCatConfirm
      || this.showBackupDialog
      || this.showExportDialog;
    AppStorage.setOrCreate<boolean>('favCanGoBack', canBack);
  }

  /** BUG-01：消费 Index.onBackPress 转发的系统返回请求，按优先级逐级回退：弹层 → 编辑态 → 分类内 → 吧内 → 根视图（放行） */
  private onBackRequest(): void {
    if (this.favBackRequest <= 0) {
      return;
    }
    if (this.searchMode) {
      this.exitSearch();
    } else if (this.categoryInputVisible) {
      this.closeCategoryInput();
    } else if (this.showMovePanel && this.pickerCreating) {
      // 面板内输入态：返回键先退输入行（与收藏页 categoryInputVisible 口径一致），不关面板
      this.pickerCreating = false;
    } else if (this.showMovePanel) {
      this.showMovePanel = false;
    } else if (this.showCategoryManage) {
      this.closeCategoryManage();
    } else if (this.showPinConfirm) {
      this.closePinConfirm();
    } else if (this.showDeleteConfirm) {
      this.closeDeleteConfirm();
    } else if (this.showRemoveCatConfirm) {
      this.closeRemoveCatConfirm();
    } else if (this.showBackupDialog) {
      this.closeBackupDialog();
    } else if (this.showExportDialog) {
      this.closeExportDialog();
    } else if (this.editMode) {
      this.exitEditMode();
    } else if (this.selectedCategoryId.length > 0) {
      this.selectedCategoryId = '';
      lastSelectedCategoryId = '';
    } else if (this.selectedForum.length > 0) {
      this.selectedForum = '';
      lastSelectedForum = '';
    }
    // 根视图：无层级可回退，Index 依据 favCanGoBack=false 放行系统默认（退出 App）
  }

  /** BUG-04：分类管理入口（v1.15.10 起改为系统 CustomDialog + API 26 沉浸光感材质，替掉自绘浮层） */
  private manageCategory(cat: FavCategory): void {
    // 先写展示快照（manageTargetCat 的 @Watch 同步 4 项），再置显隐（@Watch 立即 open，避免首帧读到上一条内容）
    this.manageTargetCat = cat;
    this.showCategoryManage = true;
  }

  /** 关闭分类管理弹窗（遮罩 / 返回键 / 取消按钮 / 删除分类 的统一入口） */
  private closeCategoryManage(): void {
    this.categoryRenameMode = false;
    this.manageTargetCat = null;
    this.showCategoryManage = false;
  }

  /**
   * 弹窗内「删除分类」：先取目标再关菜单弹窗，延时再弹确认框。
   * 300ms 覆盖菜单卡的 200ms 关闭动画 —— 否则两张卡会在同一位置短暂重叠。
   */
  private removeCategoryFromDialog(): void {
    const cat: FavCategory | null = this.manageTargetCat;
    this.closeCategoryManage();
    if (cat) {
      setTimeout(() => { this.requestRemoveCategory(cat); }, 300);
    }
  }

  /** BUG-05：置顶/取消置顶确认——先弹确认弹窗，确认后执行 */
  private requestPinFolder(folder: FolderItem): void {
    const targetPin: boolean = !folder.pinned;
    this.pinConfirmTarget = { forumName: folder.forumName, targetPin };
    // 先写弹窗展示快照，再置显隐（@Watch 立即 open，避免首帧读到旧文案）
    this.pinConfirmTitle = targetPin ? '置顶收纳夹' : '取消置顶';
    this.pinConfirmMessage = `确定${targetPin ? '置顶' : '取消置顶'}「${folder.forumName}」吗？`
      + (targetPin ? '置顶后将优先展示在列表最前。' : '');
    this.pinConfirmConfirmLabel = targetPin ? '置顶' : '取消置顶';
    this.showPinConfirm = true;
    Haptic.light();
  }

  /** 关闭置顶确认弹窗（遮罩 / 返回键 / 取消 / 确认后统一入口） */
  private closePinConfirm(): void {
    this.showPinConfirm = false;
    this.pinConfirmTarget = null;
  }

  private confirmPin(): void {
    // 先取目标再关闭（closePinConfirm 会清空 pinConfirmTarget）
    const t = this.pinConfirmTarget;
    this.closePinConfirm();
    if (t) {
      this.togglePinFolder(t.forumName);
    }
  }

  /** BUG-03：进入收藏本地搜索（编辑态先行退出） */
  private enterSearch(): void {
    if (this.editMode) {
      this.exitEditMode();
    }
    this.searchMode = true;
    this.searchKeyword = '';
  }

  private exitSearch(): void {
    this.searchMode = false;
    this.searchKeyword = '';
  }

  /** 登录状态变化（登录/登出/换号）：重读账号并回到收藏根视图重载数据 */
  private onLoginRefresh(): void {
    this.accountId = AuthManager.getInstance().getUser()?.userId ?? '';
    // 换号/登出后回到收藏根视图，避免停留在旧账号的收藏夹/分类/搜索态内
    this.selectedForum = '';
    this.selectedCategoryId = '';
    this.searchMode = false;
    this.editMode = false;
    this.loadAll();
  }

  /** darkTick 递增（本页或宿主/其它 Tab 切换深色）→ 重读全局深色状态，保证整页背景/文字/按钮/卡片同步翻档 */
  private onDarkTick(): void {
    this.isDark = isDarkMode();
  }

  /**
   * favCatChanged 递增（详情页长按收藏钮 → 面板内新建分类 / 完成归类落库）→ 重读分类与映射，
   * 本页「自定义分类」列表与各分类计数即时对齐（此前无通路，必须重启 App 才刷新）。
   * 只重读这两份本地数据（零网络）；收藏列表本身仍走 refreshFromCache 那条线，不在此触网。
   */
  private onCatChanged(): void {
    if (this.accountId.length === 0) {
      return; // loadAll 尚未完成：其自身会读到最新分类，无需在此抢先
    }
    this.reloadCategories().catch(() => {
    });
  }

  /** 重读分类集合与帖↔分类映射；当前停留的自定义分类若已被外部删除则回落分类根视图（避免停在已不存在的分类里） */
  private async reloadCategories(): Promise<void> {
    const store = FavoriteStore.getInstance();
    this.categories = await store.loadCategories(this.accountId);
    this.mappings = await store.loadMappings(this.accountId);
    if (this.selectedCategoryId.length > 0
      && !this.categories.some((c: FavCategory): boolean => c.id === this.selectedCategoryId)) {
      this.selectedCategoryId = '';
    }
  }

  /**
   * favEnterTick 递增（宿主 switchTab 切到收藏 Tab / 重复点收藏 Tab）→ 无感刷新内容。
   * 只在已登录且无进行中的加载/同步、且距上次进入刷新超过 ENTER_REFRESH_MIN_GAP_MS 时才真的触网。
   */
  private onEnterTick(): void {
    this.silentRefresh().catch(() => {
    });
  }

  /**
   * 进入收藏页的无感刷新（2026-09-17）：不再要求用户手动下拉。
   * ①本地缓存回流（refreshFromCache，零网络；覆盖详情页收藏/取消收藏的即时写入与幽灵清理）；
   * ②云端首页增量静默合并（syncIncremental，单请求；内容无变化时零副作用）。
   * 全程不置 refreshing/loading/syncing 任一亮态、不弹 toast、不改动滚动位置，故用户"看不出在刷新"。
   */
  private async silentRefresh(): Promise<void> {
    if (this.accountId.length === 0) {
      return; // 未登录：loadAll 已置空态，无需刷新
    }
    if (this.loading || this.loadingMore || this.syncRunning || this.syncing) {
      return; // 加载/同步进行中，结束后即为最新数据
    }
    const now: number = Date.now();
    if (now - this.lastEnterRefreshAt < FavoriteTab.ENTER_REFRESH_MIN_GAP_MS) {
      return; // 节流：切换动画期间/快速来回切 Tab 不重复请求
    }
    this.lastEnterRefreshAt = now;
    if (this.allThreads.length === 0) {
      // 空态或上次加载失败：无内容可保留，回落常规加载（此时只有显示加载态可选）
      this.loadAll();
      return;
    }
    try {
      await this.refreshFromCache();
    } catch (e) {
      // 本地回流失败忽略：仍走下面的网络增量
    }
    if (this.accountId.length === 0) {
      return;
    }
    // 后台静默增量（内部自带存在性判定，无变化时不写 @State/不落盘/不重建）
    this.syncIncremental();
  }

  /**
   * 无感刷新差异判定：云端首页条目相对本地集合，是否存在新增 tid 或同 tid 关键字段变化。
   * 全部一致 → 整个静默刷新过程零副作用（不赋值 @State、不落盘、不重建列表），用户完全无感。
   */
  private cloudDiffersFromLocal(cloud: PersonalContentItem[]): boolean {
    const map: Map<string, PersonalContentItem> = new Map<string, PersonalContentItem>();
    for (const t of this.allThreads) {
      map.set(t.tid, t);
    }
    for (const c of cloud) {
      const cur: PersonalContentItem | undefined = map.get(c.tid);
      if (cur === undefined) {
        return true; // 新增收藏
      }
      if (cur.title !== c.title || cur.author !== c.author || cur.forumName !== c.forumName
        || cur.abstract !== c.abstract || cur.replyNum !== c.replyNum || cur.createTime !== c.createTime) {
        return true; // 同帖字段更新（标题编辑、回复数增长等）
      }
    }
    return false;
  }

  /** fontTick 递增（字号设置写入 / 宿主返回广播）→ 显式回写 fontScale 强制本页字号依赖刷新 */
  private onFontTick(): void {
    this.fontScale = AppStorage.get<number>('fontScale') ?? 1.0;
  }

  /** BUG-03：收藏本地过滤——匹配帖子标题 / 吧名 / 分类名（分类名命中 → 该分类下帖子纳入） */
  private searchResults(): PostCardItem[] {
    const kw: string = this.searchKeyword.trim().toLowerCase();
    if (kw.length === 0) {
      return [];
    }
    const catTids: Set<string> = new Set<string>();
    for (const c of this.categories) {
      if (c.name.toLowerCase().includes(kw)) {
        for (const m of this.mappings) {
          if (m.categoryId === c.id) {
            catTids.add(m.tid);
          }
        }
      }
    }
    const pinMap: Map<string, number> = new Map<string, number>();
    for (const p of this.pinnedThreads) {
      pinMap.set(p.id, p.pinnedAt);
    }
    const list: PostCardItem[] = [];
    for (let i = 0; i < this.allThreads.length; i++) {
      const t = this.allThreads[i];
      if (t.title.toLowerCase().includes(kw) || t.forumName.toLowerCase().includes(kw) || catTids.has(t.tid)) {
        const lastTime: number = parseInt(t.createTime, 10);
        list.push({
          tid: t.tid,
          pid: t.id,
          title: t.title,
          abstract: t.abstract,
          forumName: t.forumName,
          author: t.author,
          replyNum: t.replyNum,
          coverUrl: '',
          lastTime: isNaN(lastTime) ? 0 : lastTime,
          pinned: pinMap.has(t.tid),
          pinnedAt: pinMap.get(t.tid) ?? 0,
          orderIndex: i,
        });
      }
    }
    return list;
  }

  private requestDeleteSelected(): void {
    if (this.selectedTids.length === 0) {
      this.toast('请先选择要删除的帖子');
      return;
    }
    const count: number = this.selectedTids.length;
    // 先写弹窗展示快照，再置显隐（@Watch 立即 open，避免首帧读到上一条文案）
    this.deleteConfirmMessage = `将取消收藏 ${count} 条帖子，云端与本地同步移除，确定继续吗？`;
    this.showDeleteConfirm = true;
    Haptic.light();
  }

  /** 关闭批量删除确认弹窗（遮罩 / 返回键 / 取消 / 确认后统一入口） */
  private closeDeleteConfirm(): void {
    this.showDeleteConfirm = false;
  }

  /** 弹窗确认回调：先取条数再关闭（confirmDeleteSelected 内部会退编辑态并清空选择） */
  private confirmDeleteSelectedDialog(): void {
    const count: number = this.selectedTids.length;
    this.closeDeleteConfirm();
    this.confirmDeleteSelected(count);
  }

  /**
   * 云端逐帖取消收藏 → 乐观更新（P1）：先本地移除并刷新 UI，再同步云端；失败项自动回滚恢复。
   * 本地侧级联清理：列表/置顶/映射/缓存/聚合。
   */
  private async confirmDeleteSelected(total: number): Promise<void> {
    const userId: string = this.accountId;
    const selTids: string[] = [...this.selectedTids];
    const selSet: Set<string> = new Set<string>(selTids);
    // 快照（回滚用）
    const snapshotThreads: PersonalContentItem[] = [...this.allThreads];
    const snapshotPins: PinRecord[] = [...this.pinnedThreads];
    const snapshotMappings: CategoryMapping[] = [...this.mappings];
    // ① 乐观移除本地
    const next: PersonalContentItem[] = [];
    for (const t of this.allThreads) {
      if (!selSet.has(t.tid)) {
        next.push(t);
      }
    }
    this.allThreads = next;
    for (const tid of selTids) {
      this.knownTids.delete(tid);
    }
    this.pinnedThreads = this.pinnedThreads.filter((p: PinRecord): boolean => !selSet.has(p.id));
    this.mappings = await FavoriteStore.getInstance().removeMappingsByTids(this.accountId, selTids);
    await CacheManager.getInstance().put(`${CACHE_KEY.PERSONAL_COLLECTED}_${this.accountId}`, JSON.stringify(this.allThreads));
    // v1.11 批量删除收藏同步清理本地收藏时间
    for (const t of selTids) {
      await FavoriteStore.getInstance().removeCollectTime(this.accountId, t);
    }
    this.rebuildFolders();
    // 当前吧帖子已删空则退回收纳夹列表
    if (this.selectedForum.length > 0 && this.allThreads.every((t: PersonalContentItem): boolean => t.forumName !== this.selectedForum)) {
      this.selectedForum = '';
      lastSelectedForum = '';
    }
    this.exitEditMode();
    Haptic.strong();
    this.toast(`已取消收藏 ${selTids.length} 条`, ToastType.Success);
    // ② 云端同步（失败/异常回滚恢复）
    try {
      const tbs: string = await TiebaService.getInstance().getOperationTbs();
      const byForum: Map<string, string[]> = new Map<string, string[]>();
      for (const t of snapshotThreads) {
        if (selSet.has(t.tid)) {
          const name: string = t.forumName || '贴吧';
          const arr: string[] = byForum.get(name) ?? [];
          arr.push(t.tid);
          byForum.set(name, arr);
        }
      }
      let failedTids: string[] = [];
      for (const entry of byForum) {
        const forumName: string = entry[0];
        const tids: string[] = entry[1];
        const failed: string[] = await TiebaService.getInstance().removeThreadCollections(forumName, tids, userId, tbs);
        failedTids = failedTids.concat(failed);
      }
      if (failedTids.length > 0) {
        await this.rollbackDelete(snapshotThreads, snapshotPins, snapshotMappings, failedTids);
        this.toast(`${selTids.length - failedTids.length} 条删除成功，${failedTids.length} 条失败已恢复`, ToastType.Error);
      }
    } catch (e) {
      await this.rollbackDelete(snapshotThreads, snapshotPins, snapshotMappings, selTids);
      const msg: string = (e as Error).message ?? '删除失败，请稍后重试';
      this.toast(msg.length > 28 ? `${msg.substring(0, 28)}...` : msg, ToastType.Error);
    }
  }

  /** 删除失败回滚：恢复列表/置顶/映射/缓存/聚合 */
  private async rollbackDelete(snapshotThreads: PersonalContentItem[], snapshotPins: PinRecord[],
    snapshotMappings: CategoryMapping[], tids: string[]): Promise<void> {
    if (tids.length === 0) {
      return;
    }
    const rollbackSet: Set<string> = new Set<string>(tids);
    // 恢复帖子列表（合并去重，保留已在列表中的）
    const merged: PersonalContentItem[] = [...this.allThreads];
    for (const t of snapshotThreads) {
      if (rollbackSet.has(t.tid) && !merged.some((m: PersonalContentItem): boolean => m.tid === t.tid)) {
        merged.push(t);
      }
    }
    this.allThreads = this.mergeByTid(merged);
    for (const t of this.allThreads) {
      this.knownTids.add(t.tid);
    }
    // 恢复置顶
    const restorePins: PinRecord[] = snapshotPins.filter((p: PinRecord): boolean => rollbackSet.has(p.id));
    if (restorePins.length > 0) {
      const pins: PinRecord[] = [...this.pinnedThreads];
      for (const p of restorePins) {
        if (!pins.some((x: PinRecord): boolean => x.id === p.id)) {
          pins.push(p);
        }
      }
      this.pinnedThreads = pins;
      await FavoriteStore.getInstance().savePinnedThreads(this.accountId, pins);
    }
    // 恢复映射（原映射中属于回滚帖子的记录）
    const restoreMappings: CategoryMapping[] = snapshotMappings.filter((m: CategoryMapping): boolean => rollbackSet.has(m.tid));
    if (restoreMappings.length > 0) {
      const mergedMap: CategoryMapping[] = [...this.mappings];
      for (const m of restoreMappings) {
        if (!mergedMap.some((x: CategoryMapping): boolean => x.tid === m.tid && x.categoryId === m.categoryId)) {
          mergedMap.push(m);
        }
      }
      this.mappings = mergedMap;
      await FavoriteStore.getInstance().saveMappings(this.accountId, mergedMap);
    }
    await CacheManager.getInstance().put(`${CACHE_KEY.PERSONAL_COLLECTED}_${this.accountId}`, JSON.stringify(this.allThreads));
    this.rebuildFolders();
  }

  private placeholderHeight(): number {
    // v1.11 顶部让位：TopBar(98) + Tab(44，胶囊加高 40 + 行内呼吸 4) + Tab 与首卡间隙(6，原 14 偏大收紧) = 148
    return this.selectedForum.length > 0 ? 98 : 148;
  }

  private openThread(tid: string): void {
    // 点击即预取：利用跳转动画窗口后台取详情，详情页打开即命中缓存秒开
    TiebaService.getInstance().prefetchThreadDetail(tid, '');
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/ThreadDetail',
      params: { tid, forum: this.selectedForum }
    }).catch(() => {
      this.toast('页面打开失败，请稍后重试');
    });
  }

  /** 槽位高度：根态 = 98 + 分类胶囊行 50；其余形态（搜索 / 编辑 / 分类内 / 吧内）胶囊行不显示 = 98。
   *  显示条件与 FavContent 内 CategoryTabs 的挂载条件逐项一致。 */
  private favTitleBarHeight(): number {
    const showCatTabs: boolean = !this.searchMode && this.selectedForum.length === 0 && this.selectedCategoryId.length === 0;
    return showCatTabs ? FAV_TITLE_BAR_HEIGHT + FAV_CAT_TAB_ROW_HEIGHT : FAV_TITLE_BAR_HEIGHT;
  }

  build() {
    if (FAV_OFFICIAL_TITLE_BAR) {
      // 官方槽位路径（§6.10 同机制）：Navigation + 自定义 title（height 固定 98，与改造前悬浮 TopBar 几何一致）
      // barStyle STACK：内容区延伸到标题栏之下（官方建议，标题栏材质获得最佳沉浸体验的前提）
      // backgroundColor 显式透明：避免标题栏自带底色压住滚动经过的内容
      Navigation() {
        this.FavContent()
      }
      .title({ builder: this.FavTitleBar(), height: this.favTitleBarHeight() },
        { barStyle: BarStyle.STACK, backgroundColor: Color.Transparent })
      .mode(NavigationMode.Stack)
      .hideTitleBar(false)
      .hideBackButton(true)
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Transparent)
      .clip(false)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    } else {
      this.FavContent()
    }
  }

  /** 页面主体层：原 build() 根 Stack 原样抽成（分类视图 / 搜索态 / 各浮层与排序锚点 / bindSheet 全在其中）。
   *  TopBar 仅在兜底路径（FAV_OFFICIAL_TITLE_BAR = false）挂在层内；槽位路径由 Navigation title 承载。 */
  @Builder
  FavContent() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 帖流页顶部满宽渐变：铺在内容底层，避免被卡片圆角裁出右边缺口
      if (!this.searchMode && (this.selectedForum.length > 0 || this.selectedCategoryId.length > 0)) {
        this.TopGradientLayer()
      }

      if (this.searchMode) {
        this.SearchResultView()
      } else if (this.categoryTab === FavCategoryTab.Forums) {
        // v1.16 分类 Tab 滑动转场：@Builder 调用返回 void 无法链式 transition，用 Column 外壳承载；
        // 首次挂载（底部 Tab 切进收藏页）豁免动画，避免与整页滑入叠加成双层动画
        Column() {
          this.ForumsView()
        }
        .width('100%')
        .height('100%')
        .transition(this.firstMount ? TransitionEffect.IDENTITY : this.catTabTransition(-1))
      } else {
        Column() {
          this.CustomView()
        }
        .width('100%')
        .height('100%')
        .transition(this.firstMount ? TransitionEffect.IDENTITY : this.catTabTransition(1))
      }
      // 兜底路径才挂自绘 TopBar；槽位路径由 Navigation.title 承载（FavTitleBar）
      if (!FAV_OFFICIAL_TITLE_BAR) {
        this.TopBar()
      }
      // 兜底路径才挂自绘 CategoryTabs；槽位路径由 Navigation.title 第二行承载（FavTitleBar）
      if (!FAV_OFFICIAL_TITLE_BAR && !this.searchMode && this.selectedForum.length === 0 && this.selectedCategoryId.length === 0) {
        this.CategoryTabs()
      }
      if (!this.searchMode && this.editMode && (this.selectedForum.length > 0 || this.selectedCategoryId.length > 0)) {
        this.EditBar()
      }
      // §4.3 真机三次修复（2026-09-14）：顶部满宽渐显带改 Stack 顶层背景色渐变条（zIndex 8）——
      // 盖住各列表内容顶部（视觉渐隐），低于 EditBar(15) / 兜底胶囊行(13)，槽位顶栏在 Navigation title 层更高
      this.TopFadeBand()
      /**
       * 移入分类面板（§6.8 系统半模态）：UI / 勾选 / 新建分类已收敛到共用组件 FavCategoryPicker，
       * 组件自身 0×0 不参与本页布局，`bindSheet` 挂在组件内部（见 components/FavCategoryPicker.ets）。
       * 本页只驱动开合（showMovePanel）并在「完成」回调里落库（applyMove），
       * 故下滑 / 点遮罩关闭 = 零副作用。
       */
      FavCategoryPicker({
        show: $showMovePanel,
        categories: $categories,
        mappings: $mappings,
        checked: $moveChecked,
        creating: $pickerCreating,
        targets: this.movePanelTids,
        accountId: this.accountId,
        isDark: this.isDark,
        fontScale: this.fontScale,
        onDone: (checked: string[]) => { this.applyMove(checked); }
      })
      // 备份 / 导出授权 / 置顶确认 / 批量删除确认 / 分类管理 已全部换成系统 CustomDialog（由 controller 驱动，无需在此挂载）
      /**
       * 排序菜单锚点（§6.9：自绘下拉浮层 → 系统 bindMenu）。
       * 原自绘面板是 `position({ top: 100, right: 16 })`（三种 TopBar 形态共用）；这里用 1×1 隐形锚点 +
       * `Placement.BottomRight` 把菜单右下角精确落回同一坐标（排序钮右侧还有编辑/搜索钮，直接挂按钮会左移）。
       * 锚点不参与视觉与交互：1×1 + 全透明 + hitTestBehavior(None)，弹出仍由各形态的 TopBar 排序钮发起。
       */
      Row()
        .width(1)
        .height(1)
        .position({ top: 99, right: 16 })
        .hitTestBehavior(HitTestMode.None)
        .bindMenu(this.showSortMenu, this.SortMenuContent(), {
          placement: Placement.BottomRight,
          targetSpace: LengthMetrics.vp(0),
          systemMaterial: ImmMaterial.menu(),
          onDisappear: () => { this.showSortMenu = false; }
        })
        // §4.3 改动六·方案四：平板「自定义排序」半屏面板（state 驱动，BOTTOM 弹出与锚点位置无关；
        // 与「移入分类面板」同机制同材质档 ImmMaterial.sheet()）
        .bindSheet($$this.showSortPanel, this.CategorySortPanelContent(), {
          height: '62%',
          preferType: SheetType.BOTTOM,
          showClose: false,
          dragBar: false,
          maskColor: '#66000000',
          radius: { topLeft: 24, topRight: 24 },
          systemMaterial: ImmMaterial.sheet(),
          onDisappear: () => {
            this.showSortPanel = false;
            this.resetCatDragState();
          }
        })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg(this.isDark))
    // §4.3 改动四：根容器实宽 / 实高 → 形态判定与列数（首帧由 aboutToAppear 的 fadeCoverVp 同源取值兜底）
    .onAreaChange((_old: Area, n: Area) => {
      this.pageWidth = n.width as number;
      this.pageHeight = n.height as number;
    })
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder
  EditBar() {
    Column() {
      Row() {
        Button() {
          Text(this.allSelected() ? '取消全选' : '全选')
            .fontSize(fs(15, this.fontScale))
            .fontColor($r('sys.color.font_primary'))
            .fontWeight(this.allSelected() ? FontWeight.Medium : FontWeight.Regular)
        }
        .height(44)
        .padding({ left: 16, right: 16 })
        .backgroundColor(Theme.segGlass(this.isDark, false))
        .border({ width: 0.5, color: Theme.manualGlassBorder() })
        .backgroundBlurStyle(BlurStyle.Regular, { scale: 0.85 })
        .shadow(Theme.segGlassShadow(this.isDark, false))
        .borderRadius(Radius.full)
        .accessibilityText('全选切换')
        .onClick(() => { this.toggleSelectAll(); })

        Blank()

        Button() {
          Text('移入')
            .fontSize(fs(15, this.fontScale))
            .fontColor($r('sys.color.font_primary'))
            .fontWeight(FontWeight.Medium)
        }
        .height(44)
        .padding({ left: 18, right: 18 })
        .backgroundColor(Theme.segGlass(this.isDark, false))
        .border({ width: 0.5, color: Theme.manualGlassBorder() })
        .backgroundBlurStyle(BlurStyle.Regular, { scale: 0.85 })
        .shadow(Theme.segGlassShadow(this.isDark, false))
        .borderRadius(Radius.full)
        .margin({ right: Spacing.sm })
        .accessibilityText('移入分类')
        .onClick(() => { this.openMovePanel(); })

        Button() {
          Text(`删除 (${this.selectedTids.length})`)
            .fontSize(fs(15, this.fontScale))
            .fontColor(Color.White)
        }
        .height(44)
        .padding({ left: 20, right: 20 })
        .backgroundColor(Theme.danger())
        .borderRadius(Radius.full)
        .accessibilityText('批量删除收藏')
        .onClick(() => { this.requestDeleteSelected(); })
      }
      .width('100%')
      // 与改动前几何完全一致：左右 lg、上 6、下 20；仅移除 Theme.bottomGlass 背景条
      .padding({ left: Spacing.lg, right: Spacing.lg, top: 6, bottom: 20 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.End)
    .hitTestBehavior(HitTestMode.Transparent)
    .zIndex(15)
    // 编辑态操作栏显隐过渡（P1 · FAB 动画）
    .transition(
      TransitionEffect.OPACITY
        .combine(TransitionEffect.move(TransitionEdge.BOTTOM))
        .animation({ duration: 220, curve: Curve.EaseOut })
    )
  }

  @Builder
  ForumsView() {
    if (this.notLoggedIn) {
      EmptyView({
        message: '请先登录后查看收藏',
        icon: '★',
        actionText: '去登录',
        action: () => {
          this.getUIContext().getRouter().pushUrl({ url: 'pages/Login' });
        }
      }).layoutWeight(1)
    } else if (this.loadState === FavLoadState.Loading) {
      Column() {
        // v1.11 加载态顶部让位：与内容态 FolderListView 的 placeholderHeight() 一致，
        // 避免骨架被状态栏/标题/Tab 压住；count=6 减少底部裁切，让视觉重心下移。
        Column().width('100%').height(this.placeholderHeight())
        ListRowSkeleton({ count: 6 })
          .width('100%')
          .layoutWeight(1)
      }
      .width('100%')
      .layoutWeight(1)
    } else if (this.loadState === FavLoadState.Error) {
      ErrorView({ message: this.errorMsg, onRetry: () => { this.loadAll(); } }).layoutWeight(1)
    } else if (this.loadState === FavLoadState.Empty) {
      EmptyView({ message: '还没有收藏的帖子\n去帖子详情页点「收藏」试试', icon: '★' }).layoutWeight(1)
    } else {
      if (this.selectedForum.length > 0) {
        Column() {
          this.ForumThreadsView()
        }
        .width('100%')
        .height('100%')
        .transition(this.firstMount || this.catTabSwitching ? TransitionEffect.IDENTITY : this.detailPushTransition())
        .onAppear(() => {
          this.firstMount = false;
        })
      } else {
        Column() {
          this.FolderListView()
        }
        .width('100%')
        .height('100%')
        .transition(this.firstMount || this.catTabSwitching ? TransitionEffect.IDENTITY : this.listBaseTransition())
        .onAppear(() => {
          this.firstMount = false;
        })
      }
    }
  }

  /** 收藏夹打开/返回过渡：对齐系统页面转场（右滑推入/收回），与「点开帖子→详情页」右滑入统一 */
  private detailPushTransition(): TransitionEffect {
    return TransitionEffect.asymmetric(
      // 出现（点开收藏夹）：从右侧推入，同 router 右滑入
      TransitionEffect.translate({ x: '100%' })
        .combine(TransitionEffect.opacity(0))
        .animation({ duration: 320, curve: Curve.EaseOut }),
      // 消失（返回列表）：向右侧收回，同系统返回
      TransitionEffect.translate({ x: '100%' })
        .combine(TransitionEffect.opacity(0))
        .animation({ duration: 280, curve: Curve.EaseInOut })
    );
  }

  /** 收纳夹列表视图过渡：点开收藏夹时向左让位（前页被推开），返回时从左侧回位（与系统页面转场同构） */
  private listBaseTransition(): TransitionEffect {
    return TransitionEffect.asymmetric(
      // 出现（返回列表）：从左侧回位
      TransitionEffect.translate({ x: '-30%' })
        .combine(TransitionEffect.opacity(0))
        .animation({ duration: 320, curve: Curve.EaseOut }),
      // 消失（点开收藏夹）：向左让位
      TransitionEffect.translate({ x: '-30%' })
        .combine(TransitionEffect.opacity(0))
        .animation({ duration: 280, curve: Curve.EaseInOut })
    );
  }

  /** v1.16 分类 Tab（吧分类/自定义分类）切换滑动转场：dir=-1 左侧页（吧分类），dir=1 右侧页（自定义分类）。
   *  进出都从/向本侧平移，切换时旧页滑出 + 新页滑入，效果等同底部 Tab 的"推开"。
   *  不加透明度，避免两页交错时透出背景显得生硬；保持不透明，两页互推更贴近原生分段切换。 */
  private catTabTransition(dir: number): TransitionEffect {
    const x: string = dir < 0 ? '-100%' : '100%';
    return TransitionEffect.asymmetric(
      // 出现：从本侧滑入
      TransitionEffect.translate({ x: x })
        .animation({ duration: 300, curve: Curve.EaseOut }),
      // 消失：向本侧滑出
      TransitionEffect.translate({ x: x })
        .animation({ duration: 280, curve: Curve.EaseInOut })
    );
  }

  /** v1.16 分类 Tab 切换统一入口：清空内部导航层级（返回收藏夹列表）+ 退出编辑态 + 置切换标志（豁免新视图内部过渡）+ 记录模块级恢复态 */
  private switchCategoryTab(target: number): void {
    if (target === this.categoryTab && this.selectedForum.length === 0 && this.selectedCategoryId.length === 0) {
      return; // 已停在目标 Tab 且无内部层级：忽略重复点击
    }
    this.selectedForum = '';
    this.selectedCategoryId = '';
    this.exitEditMode();
    this.catTabSwitching = true;
    this.categoryTab = target;
    lastSelectedForum = '';
    lastSelectedCategoryId = '';
    lastCategoryTab = target;
    // 外层滑动动画结束后复位，恢复"点开/返回收藏夹"的内部导航过渡（时长取外层动画 300ms 上限 + 余量）
    setTimeout(() => { this.catTabSwitching = false; }, 400);
  }

  /** §4.3 改动二：收藏夹列表通栏头（顶部让位 + 同步提示）—— ListItemGroup.header 恒占满整行；
   *  真机修复（2026-09-14）：header 与首卡间距（lanes 组内项不吃 List space → header 底部 margin 补偿） */
  @Builder
  FolderListHeader() {
    Column() {
      Column().width('100%').height(this.placeholderHeight())
      if (this.syncing) {
        this.SyncHintRow()
      }
    }
    .width('100%')
    .margin({ bottom: Spacing.md })
  }

  /** §4.3 改动二：收藏夹列表通栏尾（底部 90 让位） */
  @Builder
  FolderListFooter() {
    Column().width('100%').height(90)
  }

  @Builder
  FolderListView() {
    Refresh({ refreshing: this.refreshing, offset: 48, friction: 62 }) {
      List({ space: Spacing.md, scroller: this.folderScroller }) {
        // §4.3 改动二（2026-09-14 拍板 lanes）：通栏项（顶部让位 / 同步提示 / 底部占位）收进
        // ListItemGroup 的 header / footer —— lanes 下组内 ListItem 分列、header / footer 恒占满整行；
        // 收藏夹卡等高（80）→ lanes 等分无留白，不需要瀑布流。lanes(1) = 手机原布局逐像素同款。
        ListItemGroup({ header: this.FolderListHeader(), footer: this.FolderListFooter() }) {
          ForEach(this.folders, (folder: FolderItem) => {
            ListItem() {
              this.FolderCard(folder)
            }
            // 真机修复（2026-09-14）：`List({ space })` 不作用于 ListItemGroup 组内项 → lanes 行距全丢；
            // 用 margin 补回等值行距（手机档同步生效，与原 space 观感一致）
            .margin({ bottom: Spacing.md })
          }, (folder: FolderItem) => `folder_${folder.forumName}_${folder.pinned}`)
        }
      }
      .lanes(Math.max(1, this.favColumns()), Spacing.md)
      .layoutWeight(1)
      .padding({ left: Spacing.lg, right: Spacing.lg, bottom: Spacing.lg })
      .scrollBar(BarState.Off)
      .clip(false)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .onReachEnd(() => { this.loadMore(); })
      .onAppear(() => { this.restoreListScroll(this.folderScroller, this.folderScrollOffset); })
      .onAreaChange((oldValue: Area, newValue: Area) => { this.restoreListScroll(this.folderScroller, this.folderScrollOffset); })
    }
    .layoutWeight(1)
    // §4.3 真机修复（2026-09-14）：Refresh 显式全宽——未挂 width 时遮罩（width('100%') 相对 Refresh 测量）
    // 解析为内容固有宽 → 渐显带右边缺一条竖带（四界面同源，用户截图实证）
    .width('100%')
    .onRefreshing(() => { this.handleRefresh(); })
  }

  @Builder
  FolderCard(folder: FolderItem) {
    Row({ space: Spacing.md }) {
      Stack() {
        if (folder.avatarUrl.length > 0) {
          Image(folder.avatarUrl)
            .width(48)
            .height(48)
            .borderRadius(24)
            .objectFit(ImageFit.Cover)
        } else {
          Text(folder.forumName.charAt(0))
            .fontSize(fs(20, this.fontScale))
            .fontWeight(FontWeight.Bold)
            .fontColor(Color.White)
            .width(48)
            .height(48)
            .textAlign(TextAlign.Center)
            .borderRadius(24)
            .backgroundColor(Theme.brand())
        }
        if (folder.pinned) {
          Stack() {
            SymbolGlyph($r('sys.symbol.pin_fill'))
              .fontColor([Color.White])
              .fontSize(fs(9, this.fontScale))
          }
          .width(18)
          .height(18)
          .borderRadius(9)
          .backgroundColor(Theme.brand())
          .border({ width: 2, color: Theme.bgCard(this.isDark) })
          .shadow({ radius: 4, color: '#26000000', offsetY: 1 })
          .position({ x: 32, y: -2 })
        }
      }
      .width(48)
      .height(48)

      Column({ space: 4 }) {
        Row({ space: 6 }) {
          Text(folder.forumName)
            .fontSize(fs(16, this.fontScale))
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.textPrimary(this.isDark))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(VerticalAlign.Center)

        Text(`${folder.threadCount} 个收藏`)
          .fontSize(fs(13, this.fontScale))
          .fontColor(Theme.textSecondary(this.isDark))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(fs(16, this.fontScale))
        .fontColor([$r('sys.color.icon_tertiary')])
    }
    .width('100%')
    .padding(Spacing.lg)
    .backgroundColor(Theme.bgCard(this.isDark))
    // 卡片圆角 26：与收藏页其余卡片、首页 ThreadCard、详情页卡片统一口径（不借用全局 Radius.lg）
    .borderRadius(26)
    .accessibilityText(`${folder.forumName}，${folder.threadCount} 个收藏${folder.pinned ? '，已置顶' : ''}`)
    .accessibilityDescription('点击进入，长按置顶或取消置顶')
    .onClick(() => {
      this.folderScrollOffset = this.folderScroller.currentOffset().yOffset;
      this.selectedForum = folder.forumName;
      lastSelectedForum = folder.forumName;
    })
    .gesture(LongPressGesture({ fingers: 1, repeat: false, duration: 350 })
      .onAction(() => { this.requestPinFolder(folder); }))
  }

  /**
   * §4.3 改动三（2026-09-14 三次更正）：PostCard 高度随文本行数可变 → 多列不能 lanes（行内留白）；
   * 首改 `WaterFlow` 后真机复现 **floor-vanish**（虚拟滚动容器视口剔除，docs/floor-vanish-viewport-fix.md）
   * → 终版 = **Scroll + Column 全量渲染 + 「列内独立堆叠」分桶**（PostColumnsBlock，方案 B 带滞回最短列），
   * 多列观感与瀑布流一致且彻底绕开视口剔除 bug；等高卡的收藏夹列表维持 lanes 分叉不变。
   * 手机档（favColumns()=1）走原 List 单列，逐像素不变。
   */
  @Builder
  ForumThreadsView() {
    Refresh({ refreshing: this.refreshing, offset: 48, friction: 62 }) {
      Column() {
        if (this.forumThreads().length === 0 && !this.loading) {
          // 空态：该吧还没有收藏时提示
          Column({ space: 10 }) {
            Text('⭐')
              .fontSize(fs(44, this.fontScale))
            Text('这个吧还没有收藏的帖子')
              .fontSize(fs(15, this.fontScale))
              .fontWeight(FontWeight.Medium)
              .fontColor(Theme.textSecondary(this.isDark))
            Text('去帖子详情页点「收藏」试试')
              .fontSize(fs(12, this.fontScale))
              .fontColor(Theme.textTertiary(this.isDark))
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
        } else {
          // 真机修复（2026-09-14，floor-vanish 同源）：`WaterFlow` 与 `List` 同属虚拟滚动容器，
          // 在「clip(false) + expandSafeArea 沉浸 + 底部悬浮 Tab」场景下视口剔除错位 → 卡片整层消失
          // （docs/floor-vanish-viewport-fix.md）。按其结论换 **Scroll + Column 全量渲染** 绕过；
          // 多列观感由「列内独立堆叠 + 方案 B 带滞回最短列分桶」承担（与 §4.9 ThreadDetail 同款成熟结构）。
          Scroll() {
            Column({ space: Spacing.md }) {
              Column().width('100%').height(FavoriteTab.THREAD_TOP_PLACEHOLDER)
              this.PostColumnsBlock(this.forumThreads(), false)
              // 底部占位：给 74vp 底部 Tab 栏让位 + 缓冲（全量渲染下随内容滚动）
              Column().width('100%').height(90)
            }
            .width('100%')
          }
          .width('100%')
          .layoutWeight(1)
          // 真机修复（2026-09-14）：padding / 渐显遮罩 / 沉浸**恢复挂滚动层本身**（与原 List 逐项同口径）——
          // 挂带 padding 的包裹 Column 上时遮罩宽不满屏（漏一边）且渐隐区下移盖到首卡（用户真机驳回）；
          // scrollBar 必须显式 Off（默认 Auto 的滚动条绘制在遮罩之上 → 右缘竖条 + 渐显带「缺一块」观感）
          .padding({ left: Spacing.lg, right: Spacing.lg, bottom: Spacing.lg })
          .scrollBar(BarState.Off)
          .clip(false)
          .align(Alignment.TopStart)
          .edgeEffect(EdgeEffect.Spring)
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        }
      }
      .width('100%')
      .layoutWeight(1)
    }
    // §4.3 真机修复（2026-09-14）：Refresh 显式全宽——未挂 width 时遮罩（width('100%') 相对 Refresh 测量）
    // 解析为内容固有宽 → 渐显带右边缺一条竖带（四界面同源，用户截图实证）
    .width('100%')
    .onRefreshing(() => { this.handleRefresh(); })
  }

  /** 帖子同属的自定义分类数（不含当前所在分类，展示 +N 用） */
  private extraCategoryCount(tid: string): number {
    let count: number = 0;
    for (const m of this.mappings) {
      if (m.tid === tid && m.categoryId !== CATEGORY_DEFAULT_ID) {
        count++;
      }
    }
    return Math.max(0, count - 1);
  }

  @Builder
  PostCard(card: PostCardItem, showForumBadge: boolean) {
    Column({ space: 2 }) {
      Row({ space: 8 }) {
        if (card.pinned) {
          Row({ space: 3 }) {
            SymbolGlyph($r('sys.symbol.pin_fill'))
              .fontColor([Color.White])
              .fontSize(fs(10, this.fontScale))
            Text('置顶')
              .fontSize(fs(11, this.fontScale))
              .fontColor(Color.White)
          }
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .backgroundColor(Theme.badgePin(this.isDark))
          .borderRadius(4)
        }
        Text(card.title || '楼主暂无标题')
          .fontSize(fs(16, this.fontScale))
          .lineHeight(fs(22, this.fontScale))
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textPrimary(this.isDark))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (this.editMode) {
          Stack() {
            if (this.isSelected(card.tid)) {
              // 自绘对勾：圆头描边路径（起点-拐点-终点），替代细弱字符 ✓，笔画与圆圈视觉重量协调
              Path()
                // ⚠️ Path.commands 坐标单位是 px（非 vp），须用 vp2px 换算，否则低密度下缩小且锚定左上角
                .commands(`M${vp2px(6)} ${vp2px(11.6)} L${vp2px(9.8)} ${vp2px(15.3)} L${vp2px(16.2)} ${vp2px(7.4)}`)
                .width(22)
                .height(22)
                .stroke(Color.White)
                .strokeWidth(2.4)
                .fillOpacity(0)
                .strokeLineCap(LineCapStyle.Round)
                .strokeLineJoin(LineJoinStyle.Round)
                .transition(
                  TransitionEffect.OPACITY
                    .combine(TransitionEffect.scale({ x: 0.6, y: 0.6 }))
                    .animation({ duration: 220, curve: Curve.Friction })
                )
            }
          }
          .width(22)
          .height(22)
          .borderRadius(11)
          .backgroundColor(this.isSelected(card.tid) ? Theme.brand() : Color.Transparent)
          .border({ width: 2, color: this.isSelected(card.tid) ? Color.Transparent : Theme.textTertiary(this.isDark) })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
      if (card.abstract.length > 0) {
        Text(card.abstract)
          .fontSize(fs(13, this.fontScale))
          .fontColor(Theme.textSecondary(this.isDark))
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      Row() {
        Text(card.author)
          .fontSize(fs(11, this.fontScale))
          .fontColor(Theme.textSecondary(this.isDark))
        Blank()
        Text(`${card.replyNum} 回复`)
          .fontSize(fs(11, this.fontScale))
          .fontColor(Theme.textTertiary(this.isDark))
        if (!this.editMode) {
          Text('分享')
            .fontSize(fs(12, this.fontScale))
            .fontColor(Theme.brand())
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .backgroundColor(Theme.bgElevated(this.isDark))
            .borderRadius(Radius.full)
            .margin({ left: 8 })
            .accessibilityText('分享帖子')
            .onClick(() => {
              const payload: ThreadSharePayload = {
                tid: card.tid,
                title: card.title,
                forumName: card.forumName,
                author: card.author,
                abstract: card.abstract,
                firstImage: card.coverUrl
              };
              ShareUtil.shareThread(this.getUIContext(),
                this.getUIContext().getHostContext() as common.UIAbilityContext, payload);
            })
        }
      }
      .width('100%')
      if (showForumBadge) {
        Row({ space: 6 }) {
          Stack() {
            if (this.avatarCache.has(card.forumName)) {
              Image(this.avatarCache.get(card.forumName) as string)
                .width(20)
                .height(20)
                .borderRadius(10)
                .objectFit(ImageFit.Cover)
            } else {
              Text(card.forumName.charAt(0))
                .fontSize(fs(9, this.fontScale))
                .fontWeight(FontWeight.Bold)
                .fontColor(Color.White)
                .width(20)
                .height(20)
                .textAlign(TextAlign.Center)
                .borderRadius(10)
                .backgroundColor(Theme.brand())
            }
          }
          .width(20)
          .height(20)

          Text(card.forumName)
            .fontSize(fs(11, this.fontScale))
            .fontColor(Theme.textSecondary(this.isDark))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.extraCategoryCount(card.tid) > 0) {
            Text(`+${this.extraCategoryCount(card.tid)} 个收藏夹`)
              .fontSize(fs(11, this.fontScale))
              .fontColor(Theme.textTertiary(this.isDark))
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
    }
    .width('100%')
    .padding(Spacing.lg)
    .backgroundColor(Theme.bgCard(this.isDark))
    // 卡片圆角 26：与收藏页其余卡片、首页 ThreadCard、详情页卡片统一口径（不借用全局 Radius.lg）
    .borderRadius(26)
    .accessibilityText(`${card.title || '楼主暂无标题'}，作者 ${card.author}，${card.replyNum} 回复${card.pinned ? '，已置顶' : ''}`)
    .accessibilityDescription(this.editMode ? '点击切换勾选' : '点击打开详情，长按进入编辑')
    .onClick(() => {
      if (this.editMode) {
        this.toggleSelect(card.tid);
      } else {
        this.openThread(card.tid);
      }
    })
    .gesture(LongPressGesture({ fingers: 1, repeat: false, duration: 350 })
      .onAction(() => {
        if (this.editMode) {
          this.toggleSelect(card.tid);
        } else if (this.sortMode !== SortMode.Custom) {
          // v1.11：Custom 模式下长按让位于 List 拖拽（自定义排序），编辑仍可经顶栏「编辑」进入
          this.enterEditFor(card.tid);
        }
      }))
  }

  @Builder
  CustomView() {
    Column() {
      if (this.selectedCategoryId.length > 0) {
        Column() {
          this.CategoryThreadsView()
        }
        .width('100%')
        .height('100%')
        .transition(this.firstMount || this.catTabSwitching ? TransitionEffect.IDENTITY : this.detailPushTransition())
        .onAppear(() => {
          this.firstMount = false;
        })
      } else {
        Column() {
          this.CategoryListView()
        }
        .width('100%')
        .height('100%')
        .transition(this.firstMount || this.catTabSwitching ? TransitionEffect.IDENTITY : this.listBaseTransition())
        .onAppear(() => {
          this.firstMount = false;
        })
      }
    }
    .width('100%')
    .height('100%')
  }

  /** 自定义分类 - 分类列表（未分类 + 自定义，长按管理） */
  @Builder
  CategoryListView() {
    Refresh({ refreshing: this.refreshing, offset: 48, friction: 62 }) {
      if (this.favColumns() > 1) {
        // §4.3 改动六·方案四（2026-09-14 拍板）：平板多列浏览态——lanes 分列、**无拖拽**（排序收进半屏面板，
        // 长按回归管理语义）；通栏项（占位 / 同步提示 / 新建卡 / 未分类卡）收进 ListItemGroup.header 恒占满整行
        List({ space: Spacing.md, scroller: this.categoryScroller }) {
          ListItemGroup({ header: this.CategoryListHeader() }) {
            // 真机修复（2026-09-14）：新建卡 / 未分类卡从通栏 header 移进组体参与分列（否则 0 自定义分类时
            // 整页只见两张整行卡，观感像没适配）；行距同收藏夹列表用 margin 补（List space 不作用于组内项）
            ListItem() {
              this.NewCategoryCard()
            }
            .margin({ bottom: Spacing.md })
            ListItem() {
              this.CategoryCard(
                { id: CATEGORY_DEFAULT_ID, name: '未分类', icon: '📂', sortOrder: 0, createdAt: 0, cover: '' },
                this.categoryCountOf(CATEGORY_DEFAULT_ID),
                false,
                false)
            }
            .margin({ bottom: Spacing.md })
            ForEach(this.sortedCategories(), (c: FavCategory) => {
              ListItem() {
                this.CategoryCard(c, this.categoryCountOf(c.id), true, false)
              }
              .margin({ bottom: Spacing.md })
              // §4.3 改动六·方案四补充（2026-09-14）：平板多列浏览态长按分类卡 → 唤起半屏排序面板
              // （与排序菜单「自定义排序」同一入口；该分支仅平板多列挂载，与手机拖拽 / 面板内拖拽零冲突）
              .gesture(LongPressGesture({ fingers: 1, repeat: false, duration: 350 })
                .onAction(() => {
                  if (!this.showSortPanel) {
                    this.openCategorySortPanel();
                  }
                }))
            }, (c: FavCategory) => `catm_${c.id}_${c.name}`)
          }
        }
        .lanes(this.favColumns(), Spacing.md)
        .layoutWeight(1)
        .padding({ left: Spacing.lg, right: Spacing.lg, bottom: Spacing.xl })
        .scrollBar(BarState.Off)
        .clip(false)
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        .onReachEnd(() => { this.loadMore(); })
      } else {
      List({ space: Spacing.md, scroller: this.categoryScroller }) {
        ListItem() {
          Column().width('100%').height(this.placeholderHeight())
        }
        .backgroundColor(Color.Transparent)

        if (this.syncing) {
          ListItem() {
            this.SyncHintRow()
          }
        }

        ListItem() {
          this.NewCategoryCard()
        }

        ListItem() {
          this.CategoryCard(
            { id: CATEGORY_DEFAULT_ID, name: '未分类', icon: '📂', sortOrder: 0, createdAt: 0, cover: '' },
            this.categoryCountOf(CATEGORY_DEFAULT_ID),
            false,
            false)
        }

        ForEach(this.sortedCategories(), (c: FavCategory) => {
          ListItem() {
            if (this.draggingCatId === c.id) {
              // v1.15.3 拖动卡原位塌陷：让前后 ListItem 自然靠拢避让（虚线占位框作为预览跟手移动）
              Column().width('100%').height('100%')
            } else {
              this.CategoryCard(c, this.categoryCountOf(c.id), true,
                this.dragTargetIndex === FavoriteTab.CAT_LIST_PREPEND + this.catIndexById(c.id))
            }
          }
          // v1.15.3 拖动卡原位 ListItem 高度 0 → 列表其它项自然靠拢避让
          .height(this.draggingCatId === c.id ? 0 : FavoriteTab.CATEGORY_CARD_HEIGHT)
          // v1.15.4 智能让位：拖动卡原位塌陷外，按拖动方向平移让出目标位（ListItem 整体平移，避免 Column.translate 的 clip 透明问题）
          .translate({ y: this.displaceOffsetOf(this.catIndexById(c.id)) })
          // v1.15.8 修复：key 加入 name。仅用 id 时，重命名（id 不变）会被 ForEach 判定为"无变化"而复用旧卡片不刷新；
          // 加入 name 后改名 → key 变 → 该项重建，分类名在弹窗取消后立即更新（新建/删除/拖拽按 id 判断，不受影响）
        }, (c: FavCategory) => `cat_${c.id}_${c.name}`)
      }
      .editMode(true)
      .layoutWeight(1)
      .padding({ left: Spacing.lg, right: Spacing.lg, bottom: Spacing.xl + this.dragListBottomPad })
      .scrollBar(BarState.Off)
      .clip(false)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .onReachEnd(() => { this.loadMore(); })
      .onAppear(() => { this.restoreListScroll(this.categoryScroller, this.categoryScrollOffset); })
      .onAreaChange((oldValue: Area, newValue: Area) => { this.restoreListScroll(this.categoryScroller, this.categoryScrollOffset); })
      // v1.8 拖拽排序：前置固定项（占位/新建/未分类）不响应拖拽，仅自定义分类可拖
      .onItemDragStart((event: ItemDragInfo, itemIndex: number) => {
        // v1.19 防闪退：拖拽激活帧内**不要**改被拖源 ListItem 自身高度、**不要** animateTo List padding。
        // 仅记录索引 + 触觉 + 返回 preview；draggingCatId / dragListBottomPad 延后到 onItemDragMove 首帧守卫
        // （手指真动起来、框架拖拽会话已稳定）再赋值，避免在系统正在生成拖拽会话的同帧对被拖源做几何突变。
        // （§4.3 改动六·方案四：回调本体抽为 catDragBegin / catDragMove / catDrop 共享方法，见下方）
        this.catDragBegin(itemIndex, FavoriteTab.CAT_LIST_PREPEND);
        if (this.draggingCatIndex < 0) {
          return;
        }
        // v1.15.4 必须返回自定义预览 builder：不返回时系统不生成预览 → 拖动卡原位又塌陷，视觉上"拖动卡消失"。
        // 中间卡避让由 displaceOffsetOf 手动让位
        const sorted: FavCategory[] = this.sortedCategories();
        return this.CategoryDragPreview(sorted[this.draggingCatIndex]);
      })
      // v1.12 拖动过程实时记录目标插入位，用于高亮提示（返回自定义预览时系统不再自动让位，需自行反馈）
      .onItemDragMove((event: ItemDragInfo, itemIndex: number, insertIndex: number) => {
        this.catDragMove(itemIndex, insertIndex, FavoriteTab.CAT_LIST_PREPEND, this.categoryScroller);
      })
      .onItemDrop((event: ItemDragInfo, itemIndex: number, insertIndex: number, isSuccess: boolean) => {
        this.catDrop(insertIndex, isSuccess, FavoriteTab.CAT_LIST_PREPEND);
      })
    }
    }
    .layoutWeight(1)
    // §4.3 真机修复（2026-09-14）：Refresh 显式全宽——未挂 width 时遮罩（width('100%') 相对 Refresh 测量）
    // 解析为内容固有宽 → 渐显带右边缺一条竖带（四界面同源，用户截图实证）
    .width('100%')
    .onRefreshing(() => { this.handleRefresh(); })
  }

  /** §4.3 改动六：自定义分类多列浏览态通栏头（顶部让位 + 同步提示）——恒占满整行；新建 / 未分类卡已移进组体分列；
   *  真机修复（2026-09-14）：header 底部 margin 补偿组内间距（同 FolderListHeader） */
  @Builder
  CategoryListHeader() {
    Column() {
      Column().width('100%').height(this.placeholderHeight())
      if (this.syncing) {
        this.SyncHintRow()
      }
    }
    .width('100%')
    .margin({ bottom: Spacing.md })
  }

  /** v1.15 补位避让：拖动卡原位留空（渲染占位），原位与插入位之间的卡向原位方向平移一个卡位补上，插入位腾出空位给拖动卡；按 id 定位索引 */
  private catIndexById(id: string): number {
    return this.sortedCategories().findIndex((cat: FavCategory): boolean => cat.id === id);
  }

  /**
   * §4.3 改动六·方案四（2026-09-14 拍板）：平板「自定义排序」半屏面板。
   * 壳 = bindSheet 半模态 + `ImmMaterial.sheet()`（与「移入分类面板」同机制同材质档；本页 §6.8 已实证
   * 半模态为官方沉浸光感 A 档槽位——更正方案讨论时「bindSheet 无光感」的误判）。
   * 面板内**单列 List 完整复用现有拖拽状态机**（长按拖动 / 塌陷让位 / 跟随滚动 / 落位持久化），
   * 与主列表仅两处不同：① prepend = 1（面板只有一枚小占位）；② 跟随滚动用面板独立 Scroller。
   * 主列表多列浏览态无拖拽（editMode 默认 false）→ 两套 List 回调互不干扰；面板打开时排序语义 = Custom。
   */
  @Builder
  CategorySortPanelContent() {
    Column() {
      Row() {
        Column({ space: 2 }) {
          Text('自定义排序')
            .fontSize(fs(17, this.fontScale))
            .fontWeight(FontWeight.Bold)
            .fontColor($r('sys.color.font_primary'))
          Text(this.selectedCategoryId.length > 0 ? '长按拖动帖子调整顺序' : '长按拖动分类卡调整顺序')
            .fontSize(fs(12, this.fontScale))
            .fontColor(Theme.textTertiary(this.isDark))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text('完成')
          .fontSize(fs(15, this.fontScale))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_emphasize'))
          .padding({ left: 16, right: 4, top: 8, bottom: 8 })
          .accessibilityText('完成排序')
          .onClick(() => { this.showSortPanel = false; })
      }
      .width('100%')
      .padding({ left: Spacing.lg, right: Spacing.lg, top: 16, bottom: 8 })

      if (this.selectedCategoryId.length > 0) {
        // §4.3 改动六 B 二次更正：分类内帖子改 WaterFlow 后（多列）拖拽收进面板——面板内是 List，拖拽保留
        List({ space: Spacing.md, scroller: this.panelThreadScroller }) {
          ListItem() {
            Column().width('100%').height(4)
          }

          ForEach(this.categoryThreads(), (card: PostCardItem) => {
            ListItem() {
              this.PostCard(card, true)
            }
          }, (card: PostCardItem) => `spanel_th_${card.tid}`)
        }
        .editMode(true)
        .layoutWeight(1)
        .width('100%')
        .padding({ left: Spacing.lg, right: Spacing.lg, bottom: Spacing.xl })
        .scrollBar(BarState.Off)
        .clip(false)
        .onItemDragStart((event: ItemDragInfo, itemIndex: number) => {
          // 面板前置仅 1 枚小占位 → threadIndex = itemIndex - 1（与主列表单列同基准）
          if (itemIndex < 1) {
            return;
          }
          const cards: PostCardItem[] = this.categoryThreads();
          const threadIndex: number = itemIndex - 1;
          if (threadIndex >= cards.length) {
            return;
          }
          this.draggingThreadIndex = threadIndex;
          Haptic.light();
          return this.ThreadDragPreview(cards[threadIndex]);
        })
        .onItemDrop((event: ItemDragInfo, itemIndex: number, insertIndex: number, isSuccess: boolean) => {
          if (!isSuccess || this.draggingThreadIndex < 0) {
            this.draggingThreadIndex = -1;
            return;
          }
          const from: number = this.draggingThreadIndex;
          const list: PostCardItem[] = this.categoryThreads().slice();
          const moved: PostCardItem = list.splice(from, 1)[0];
          let to: number = insertIndex - 1;
          if (to < 0) {
            to = 0;
          }
          if (to > list.length) {
            to = list.length;
          }
          list.splice(to, 0, moved);
          this.draggingThreadIndex = -1;
          this.persistThreadOrder(list);
        })
      } else {
        List({ space: Spacing.md, scroller: this.panelCategoryScroller }) {
          ListItem() {
            Column().width('100%').height(4)
          }

          ForEach(this.sortedCategories(), (c: FavCategory) => {
            ListItem() {
              if (this.draggingCatId === c.id) {
                Column().width('100%').height('100%')
              } else {
                this.CategoryCard(c, this.categoryCountOf(c.id), true,
                  this.dragTargetIndex === 1 + this.catIndexById(c.id))
              }
            }
            .height(this.draggingCatId === c.id ? 0 : FavoriteTab.CATEGORY_CARD_HEIGHT)
            .translate({ y: this.displaceOffsetOf(this.catIndexById(c.id), 1) })
          }, (c: FavCategory) => `spanel_${c.id}_${c.name}`)
        }
        .editMode(true)
        .layoutWeight(1)
        .width('100%')
        .padding({ left: Spacing.lg, right: Spacing.lg, bottom: Spacing.xl + this.dragListBottomPad })
        .scrollBar(BarState.Off)
        .clip(false)
        .onItemDragStart((event: ItemDragInfo, itemIndex: number) => {
          this.catDragBegin(itemIndex, 1);
          if (this.draggingCatIndex < 0) {
            return;
          }
          const sorted: FavCategory[] = this.sortedCategories();
          return this.CategoryDragPreview(sorted[this.draggingCatIndex]);
        })
        .onItemDragMove((event: ItemDragInfo, itemIndex: number, insertIndex: number) => {
          this.catDragMove(itemIndex, insertIndex, 1, this.panelCategoryScroller);
        })
        .onItemDrop((event: ItemDragInfo, itemIndex: number, insertIndex: number, isSuccess: boolean) => {
          this.catDrop(insertIndex, isSuccess, 1);
        })
      }
    }
    .width('100%')
    .height('100%')
  }

  /** 面板关闭（含下滑手势）时复位拖拽状态，防中途退出残留塌陷 / 让位 */
  private resetCatDragState(): void {
    this.draggingCatIndex = -1;
    this.draggingCatId = '';
    this.dragTargetIndex = -1;
    this.dragListBottomPad = 0;
  }

  /** v1.15.4 智能让位：拖动卡原位 ListItem 塌陷（高度 0）让列表自然靠拢，
   *  再用 ListItem.translate 按拖动方向让其它卡平移，腾出目标位空间给拖动卡预览：
   *  - 向上拖（origin > target）：目标位到原位之间的卡向下平移 STEP 让出目标位；原位之后的卡平移 HEIGHT 抵消"塌陷顺势上移"
   *  - 向下拖（origin < target）：目标位之后的卡平移 HEIGHT（抵消顺势上移 + 让出目标位）；中间卡靠塌陷顺势上移自然补位
   *  用 ListItem.translate 而非 Column.translate：ListItem 整体平移不触发 v1.15 的"clip 变透明"问题 */
  /** prepend 参数化（§4.3 改动六·方案四）：主列表前置 3 项 / 半屏面板仅 1 枚小占位，同一套让位算术复用 */
  private displaceOffsetOf(catIndex: number, prepend: number = FavoriteTab.CAT_LIST_PREPEND): number {
    if (this.draggingCatIndex < 0 || this.dragTargetIndex < 0 || catIndex < 0) {
      return 0;
    }
    const STEP: number = FavoriteTab.CATEGORY_CARD_STEP;
    const HEIGHT: number = FavoriteTab.CATEGORY_CARD_HEIGHT;
    const origin: number = this.draggingCatIndex + prepend;
    const target: number = this.dragTargetIndex;
    const cur: number = prepend + catIndex;
    if (cur === origin) {
      return 0; // 拖动卡原位（高度已塌陷 0）
    }
    if (origin > target) {
      // 向上拖：中间卡向下让位，原位之后的卡抵消塌陷顺势上移
      if (cur < origin) {
        return cur >= target ? STEP : 0;
      }
      return HEIGHT;
    }
    // 向下拖：目标位之后的卡抵消塌陷顺势上移并让出目标位
    if (cur > target) {
      return HEIGHT;
    }
    return 0;
  }

  // ===== §4.3 改动六·方案四：拖拽回调抽方法（主列表 / 半屏面板共用，仅 prepend 与跟随 Scroller 不同）=====

  /** 拖拽开始：记录源索引（无效则保持 -1，调用方据此跳过 preview） */
  private catDragBegin(itemIndex: number, prepend: number): void {
    this.draggingCatIndex = -1;
    if (itemIndex < prepend) {
      return;
    }
    const sorted: FavCategory[] = this.sortedCategories();
    const catIndex: number = itemIndex - prepend;
    if (catIndex >= sorted.length) {
      return;
    }
    this.draggingCatIndex = catIndex;
    this.dragTargetIndex = -1;
    Haptic.light();
  }

  /** 拖拽移动：首帧守卫（塌陷 + 底部让位垫高）+ 目标位高亮 + 跟随滚动（scroller 由调用方按所在列表传入） */
  private catDragMove(itemIndex: number, insertIndex: number, prepend: number, scroller: Scroller): void {
    if (this.draggingCatId.length === 0 && this.draggingCatIndex >= 0) {
      const sorted: FavCategory[] = this.sortedCategories();
      if (this.draggingCatIndex < sorted.length) {
        this.draggingCatId = sorted[this.draggingCatIndex].id;
      }
      this.dragListBottomPad = FavoriteTab.CATEGORY_CARD_STEP;
    }
    const max: number = prepend + this.categories.length;
    const target: number = Math.max(prepend, Math.min(insertIndex, max));
    if (target !== this.dragTargetIndex) {
      this.dragTargetIndex = target;
      if (this.draggingCatId.length > 0) {
        const now: number = Date.now();
        if (now - this.lastAutoScrollTime > 120) {
          const dragAbs: number = prepend + this.draggingCatIndex;
          const step: number = 40;
          if (target > dragAbs) {
            scroller.scrollBy(0, step);
          } else if (target < dragAbs) {
            scroller.scrollBy(0, -step);
          }
          this.lastAutoScrollTime = now;
        }
      }
    }
  }

  /** 拖拽落位 / 取消：成功 → 数据重排 + 持久化（含自动切 Custom）；失败 → 平滑回弹复位 */
  private catDrop(insertIndex: number, isSuccess: boolean, prepend: number): void {
    if (!isSuccess || this.draggingCatIndex < 0) {
      animateTo({ duration: 180, curve: Curve.EaseOut }, () => {
        this.draggingCatIndex = -1;
        this.draggingCatId = '';
        this.dragTargetIndex = -1;
        this.dragListBottomPad = 0;
      });
      return;
    }
    const from: number = this.draggingCatIndex;
    const list: FavCategory[] = this.sortedCategories().slice();
    const moved: FavCategory = list.splice(from, 1)[0];
    let to: number = insertIndex - prepend;
    if (to < 0) {
      to = 0;
    }
    if (to > list.length) {
      to = list.length;
    }
    list.splice(to, 0, moved);
    this.draggingCatIndex = -1;
    this.draggingCatId = '';
    this.dragTargetIndex = -1;
    this.dragListBottomPad = 0;
    const switchedToCustom: boolean = this.sortMode !== SortMode.Custom;
    if (switchedToCustom) {
      this.sortMode = SortMode.Custom;
      FavoriteStore.getInstance().saveSortMode(this.accountId, SortMode.Custom as number).catch(() => {});
    }
    this.persistCategoryOrder(list, switchedToCustom);
  }

  /** v1.8 拖拽松手持久化顺序（sortOrder 重写 1..n）
   *  v1.15 本地沿用 list 的旧对象引用（只同步 sortOrder），避免替换为新对象后 ForEach 按 key 复用旧 c，
   *       导致 catIndexById/findIndex 在旧引用上失效而误判占位；store 层仍用新对象持久化 */
  private async persistCategoryOrder(list: FavCategory[], switchedToCustom: boolean = false): Promise<void> {
    const ordered: FavCategory[] = list.slice();
    ordered.forEach((cat: FavCategory, i: number) => { cat.sortOrder = i + 1; });
    this.categories = ordered;
    await FavoriteStore.getInstance().reorderCategories(this.accountId, ordered);
    Haptic.light();
    this.toast(switchedToCustom ? '已切换为自定义排序，顺序已更新' : '顺序已更新', ToastType.Success);
  }

  /** v1.11 分类内帖子拖拽松手持久化自定义顺序（threadOrders[selectedCategoryId]） */
  private async persistThreadOrder(cards: PostCardItem[]): Promise<void> {
    const tids: string[] = cards.map((c: PostCardItem): string => c.tid);
    const store = FavoriteStore.getInstance();
    await store.saveThreadOrder(this.accountId, this.selectedCategoryId, tids);
    this.threadOrders = await store.loadThreadOrders(this.accountId);
    Haptic.light();
    this.toast('顺序已更新', ToastType.Success);
  }

  @Builder
  NewCategoryCard() {
    if (this.categoryInputVisible) {
      Row({ space: 8 }) {
        TextInput({ placeholder: '分类名称', text: this.categoryInputValue })
          .layoutWeight(1)
          .fontSize(fs(14, this.fontScale))
          .fontColor(Theme.textPrimary(this.isDark))
          .backgroundColor(Theme.bgElevated(this.isDark))
          .borderRadius(Radius.full)
          .height(40)
          .defaultFocus(true)
          .onChange((v: string) => { this.categoryInputValue = v; })
          .onSubmit(() => { this.commitCategoryInput(); })

        Button() {
          Text('取消')
            .fontSize(fs(13, this.fontScale))
            .fontColor(Theme.textSecondary(this.isDark))
        }
        .height(40)
        .padding({ left: 12, right: 12 })
        .backgroundColor(Theme.manualGlass(this.isDark))
        .border({ width: 0.5, color: Theme.manualGlassBorder() })
        .shadow(Theme.glassShadowStyle()).backgroundEffect(ImmBlur.control())
        .systemMaterial(ImmMaterial.control())
        .borderRadius(Radius.full)
        .onClick(() => { this.closeCategoryInput(); })

        Button() {
          Text('保存')
            .fontSize(fs(13, this.fontScale))
            .fontColor(Color.White)
        }
        .height(40)
        .padding({ left: 14, right: 14 })
        .backgroundColor(Theme.brand())
        .borderRadius(Radius.full)
        .onClick(() => { this.commitCategoryInput(); })
      }
      .width('100%')
      .padding({ top: 10, bottom: 4 })
    } else {
      Row({ space: Spacing.md }) {
        Text('＋')
          .fontSize(fs(24, this.fontScale))
          .fontColor(Theme.brand())
          .width(48)
          .height(48)
          .textAlign(TextAlign.Center)
          .backgroundColor(Theme.bgElevated(this.isDark))
          .borderRadius(24)

        Text('新建分类')
          .fontSize(fs(15, this.fontScale))
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textPrimary(this.isDark))
          .layoutWeight(1)

        SymbolGlyph($r('sys.symbol.plus'))
          .fontColor([$r('sys.color.icon_primary')])
          .fontSize(fs(18, this.fontScale))
      }
      .width('100%')
      .padding(Spacing.lg)
      .backgroundColor(Theme.bgCard(this.isDark))
      // 卡片圆角 26：与收藏页其余卡片统一（不借用全局 Radius.lg）
      .borderRadius(26)
      .accessibilityText('新建分类')
      .onClick(() => { this.beginCreateCategory(); })
    }
  }

  /** v1.14 分类封面：有 cover 显示图片（等比裁剪），无 cover 走扁平 SymbolGlyph 兜底
   *  弃用 emoji（📁/📂 跨设备渲染色杂、立体感强），统一 HarmonyOS 系统矢量符号：未分类=line folder，自定义=fill folder */
  @Builder
  CategoryCover(cover: string, icon: string, name: string, isDefault: boolean = false) {
    if (cover.length > 0) {
      // 数据库存的是裸绝对路径（如 /data/.../files/cat_cover_xxx.png），Image 需 file:// 前缀
      Image(cover.startsWith('file://') ? cover : `file://${cover}`)
        .width(48)
        .height(48)
        .objectFit(ImageFit.Cover)
        .borderRadius(24)
        .clip(true)
        .syncLoad(true)
        .accessibilityText('封面图')
    } else {
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph($r(isDefault ? 'sys.symbol.folder' : 'sys.symbol.folder_fill'))
          .fontSize(fs(24, this.fontScale))
          .fontColor([Theme.brand()])
      }
      .width(48)
      .height(48)
      .backgroundColor(Theme.bgElevated(this.isDark))
      .borderRadius(24)
      .accessibilityText(`${name} 分类图标`)
    }
  }

  /**
   * 分类卡。长按唤起排序面板的手势**不挂在本卡**：挂主列表多列分支的 ListItem（见 ForEach 处）——
   * 手机单列主列表 editMode 长按拖拽会与卡片自身 LongPressGesture 抢事件，面板内长按也必须留给拖拽。
   */
  @Builder
  CategoryCard(cat: FavCategory, count: number, editable: boolean, highlighted: boolean) {
    Row({ space: Spacing.md }) {
      this.CategoryCover(cat.cover, cat.icon, cat.name)

      Column({ space: 4 }) {
        Text(cat.name)
          .fontSize(fs(16, this.fontScale))
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textPrimary(this.isDark))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(`${count} 个收藏`)
          .fontSize(fs(11, this.fontScale))
          .fontColor(Theme.textTertiary(this.isDark))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (editable) {
        // v1.8：≡ 管理图标（点按弹管理菜单；长按整张卡由 editMode 接管进入拖拽）
        SymbolGlyph($r('sys.symbol.line_3_horizontal'))
          .fontColor([$r('sys.color.icon_secondary')])
          .fontSize(fs(20, this.fontScale))
          .padding(8)
          .accessibilityText('管理分类')
          .accessibilityDescription('点击重命名或删除')
          .onClick(() => { this.manageCategory(cat); })
      } else {
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontColor([$r('sys.color.icon_tertiary')])
          .fontSize(fs(16, this.fontScale))
      }
    }
    .width('100%')
    .padding(Spacing.lg)
    .backgroundColor(Theme.bgCard(this.isDark))
    // v1.12 拖拽目标高亮：品牌色描边 + 弱阴影（不参与布局，避免跳动）
    .border({ width: 2, color: highlighted ? Theme.brand() : Color.Transparent })
    .shadow(highlighted
      ? { radius: 12, color: '#333477FF', offsetY: 2 }
      : { radius: 0, color: Color.Transparent, offsetY: 0 })
    // 卡片圆角 26：与收藏页其余卡片统一（不借用全局 Radius.lg）
    .borderRadius(26)
    .accessibilityText(`${cat.name}，${count} 个收藏`)
    .accessibilityDescription(editable ? '点击进入，点击右侧图标管理（重命名/删除），长按可拖拽排序' : '点击进入')
    .onClick(() => {
      this.categoryScrollOffset = this.categoryScroller.currentOffset().yOffset;
      this.selectedCategoryId = cat.id;
      lastSelectedCategoryId = cat.id;
    })
  }

  /** v1.15.4 拖拽预览：真实卡跟手移动（与静态 CategoryCard 完全同宽同 R 角，**无阴影**，外层 Column 缩进复刻 List.padding 缩进）。
   *  onItemDragStart 必须返回该 builder，否则系统不生成预览 → 拖动卡原位又塌陷，视觉上"拖动卡消失"。
   *  v1.15.4 不在 Row 上用 margin（width('100%') 时 margin 会被吃掉导致贴屏），改用外层 Column.padding 缩进；删 shadow（ArkUI 预览层渲染异常，截图显示左下深色块） */
  @Builder
  CategoryDragPreview(cat: FavCategory) {
    Column() {
      Row({ space: Spacing.md }) {
        this.CategoryCover(cat.cover, cat.icon, cat.name, cat.id === CATEGORY_DEFAULT_ID)

        Column({ space: 4 }) {
          Text(cat.name)
            .fontSize(fs(16, this.fontScale))
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.textPrimary(this.isDark))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(`${this.categoryCountOf(cat.id)} 个收藏`)
            .fontSize(fs(11, this.fontScale))
            .fontColor(Theme.textTertiary(this.isDark))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        if (cat.id !== CATEGORY_DEFAULT_ID) {
          // v1.15.4 拖动预览占满管理图标位（保持与静态卡视觉一致）
          SymbolGlyph($r('sys.symbol.line_3_horizontal'))
            .fontColor([$r('sys.color.icon_secondary')])
            .fontSize(fs(20, this.fontScale))
            .padding(8)
        } else {
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontColor([$r('sys.color.icon_tertiary')])
            .fontSize(fs(16, this.fontScale))
        }
      }
      .width('100%')
      .padding(Spacing.lg)
      .backgroundColor(Theme.bgCard(this.isDark))
      // 圆角 26：与静态分类卡一致，拖拽抬起/落下时圆角不跳变
      .borderRadius(26)
    }
    .width('100%')
    // 外层 padding 复刻 List.padding(Spacing.lg)：保证预览卡左右缩进与静态卡一致
    .padding({ left: Spacing.lg, right: Spacing.lg })
  }

  /** v1.11 帖子拖拽预览：标题 + 作者 + 回复数（放大 1.05 + 阴影，与分类卡预览同范式） */
  @Builder
  ThreadDragPreview(card: PostCardItem) {
    Column({ space: 6 }) {
      Text(card.title)
        .fontSize(fs(15, this.fontScale))
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.textPrimary(this.isDark))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
      Row() {
        Text(card.author)
          .fontSize(fs(11, this.fontScale))
          .fontColor(Theme.textSecondary(this.isDark))
        Blank()
        Text(`${card.replyNum} 回复`)
          .fontSize(fs(11, this.fontScale))
          .fontColor(Theme.textTertiary(this.isDark))
      }
      .width('100%')
    }
    .width('100%')
    .padding(Spacing.lg)
    .backgroundColor(Theme.bgCard(this.isDark))
    // 圆角 26：与静态帖子卡一致，拖拽抬起/落下时圆角不跳变
    .borderRadius(26)
    .scale({ x: 1.05, y: 1.05 })
    .shadow({ radius: 24, color: '#40000000', offsetY: 8 })
  }

  /** 分类内帖子列表（本地过滤映射 + 排序 + 置顶恒顶） */
  @Builder
  CategoryThreadsView() {
    Refresh({ refreshing: this.refreshing, offset: 48, friction: 62 }) {
      if (this.favColumns() > 1) {
        // §4.3 改动六 B 二次更正（2026-09-14）：PostCard 高度可变（与收藏夹点开列表同因）→ lanes 改 **WaterFlow**；
        // `editMode / onItemDragStart` 拖拽 API 为 List 专有、WaterFlow 不支持 → 帖子自定义排序按方案四同款
        // **收进半屏排序面板**（面板内单列 List 长按拖拽，见 CategorySortPanelContent）
        if (this.categoryThreads().length === 0 && !this.loadingMore && !this.loading) {
          Column({ space: 10 }) {
            Text('📂')
              .fontSize(fs(44, this.fontScale))
            Text('这个收藏夹还没有帖子')
              .fontSize(fs(15, this.fontScale))
              .fontWeight(FontWeight.Medium)
              .fontColor(Theme.textSecondary(this.isDark))
            Text('在帖子编辑态点「移入」\n即可把帖子收藏到这个夹子里')
              .fontSize(fs(12, this.fontScale))
              .fontColor(Theme.textTertiary(this.isDark))
              .textAlign(TextAlign.Center)
              .lineHeight(fs(18, this.fontScale))
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
        } else {
          // 真机修复（2026-09-14，floor-vanish 同源）：WaterFlow → Scroll + Column 全量渲染（同 ForumThreadsView）；
          // 分页改 Scroll.onReachEnd 驱动（文档 §5：全量渲染下懒回收哨兵失效，必须用滚动容器自身触底回调）；
          // padding / 渐显遮罩 / 沉浸挂 Scroll 本身（与原 List 同口径，包裹 Column 方案真机驳回：遮罩漏边 + 盖内容）
          Scroll() {
            Column({ space: Spacing.md }) {
              Column().width('100%').height(FavoriteTab.THREAD_TOP_PLACEHOLDER)
              this.PostColumnsBlock(this.categoryThreads(), true)
              if (this.loadingMore) {
                LoadingView({ message: '加载中...' })
                  .width('100%')
                  .height(72)
              }
              Column().width('100%').height(90)
            }
            .width('100%')
          }
          .width('100%')
          .layoutWeight(1)
          .padding({ left: Spacing.lg, right: Spacing.lg, bottom: Spacing.lg })
          .scrollBar(BarState.Off)
          .clip(false)
          .align(Alignment.TopStart)
          .edgeEffect(EdgeEffect.Spring)
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
          .onReachEnd(() => {
            if (this.categoryThreads().length === 0) {
              return;
            }
            this.loadMore();
          })
        }
      } else {
      List({ space: Spacing.md }) {
        ListItem() {
          Column().width('100%').height(FavoriteTab.THREAD_TOP_PLACEHOLDER)
        }
        .backgroundColor(Color.Transparent)
        ForEach(this.categoryThreads(), (card: PostCardItem) => {
          ListItem() {
            this.PostCard(card, true)
          }
        }, (card: PostCardItem) => `ct_${card.tid}`)
        // 空态：分类内无帖子时提示（占位 + 空态 + 底部占位超一屏，onReachEnd 不再空转刷"加载中"）
        if (this.categoryThreads().length === 0 && !this.loadingMore && !this.loading) {
          ListItem() {
            Column({ space: 10 }) {
              Text('📂')
                .fontSize(fs(44, this.fontScale))
              Text('这个收藏夹还没有帖子')
                .fontSize(fs(15, this.fontScale))
                .fontWeight(FontWeight.Medium)
                .fontColor(Theme.textSecondary(this.isDark))
              Text('在帖子编辑态点「移入」\n即可把帖子收藏到这个夹子里')
                .fontSize(fs(12, this.fontScale))
                .fontColor(Theme.textTertiary(this.isDark))
                .textAlign(TextAlign.Center)
                .lineHeight(fs(18, this.fontScale))
            }
            .width('100%')
            .height('68%')
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
          }
          .backgroundColor(Color.Transparent)
        }
        if (this.loadingMore) {
          ListItem() {
            LoadingView({ message: '加载中...' })
              .width('100%')
              .height(72)
          }
          .backgroundColor(Color.Transparent)
        }
        // 底部占位：给 74vp 底部 Tab 栏让位 + 缓冲
        ListItem() {
          Column().width('100%').height(90)
        }
        .backgroundColor(Color.Transparent)
      }
      .layoutWeight(1)
      .padding({ left: Spacing.lg, right: Spacing.lg, bottom: Spacing.lg })
      .scrollBar(BarState.Off)
      .clip(false)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .onReachEnd(() => {
        if (this.categoryThreads().length === 0) {
          return;
        }
        this.loadMore();
      })
      // v1.11 自定义排序拖拽：仅 Custom 模式且非编辑态可拖（长按 item，松手持久化 threadOrders）
      .editMode(this.sortMode === SortMode.Custom && !this.editMode)
      .onItemDragStart((event: ItemDragInfo, itemIndex: number) => {
        if (itemIndex < 1) {
          return;
        }
        const threadIndex: number = itemIndex - 1;
        const cards: PostCardItem[] = this.categoryThreads();
        if (threadIndex >= cards.length) {
          return;
        }
        this.draggingThreadIndex = threadIndex;
        Haptic.light();
        return this.ThreadDragPreview(cards[threadIndex]);
      })
      .onItemDrop((event, itemIndex: number, insertIndex: number, isSuccess: boolean) => {
        if (!isSuccess || this.draggingThreadIndex < 0) {
          this.draggingThreadIndex = -1;
          return;
        }
        const from: number = this.draggingThreadIndex;
        const list: PostCardItem[] = this.categoryThreads().slice();
        const moved: PostCardItem = list.splice(from, 1)[0];
        let to: number = insertIndex - 1;
        if (to < 0) {
          to = 0;
        }
        if (to > list.length) {
          to = list.length;
        }
        list.splice(to, 0, moved);
        this.draggingThreadIndex = -1;
        this.persistThreadOrder(list);
      })
    }
    }
    .layoutWeight(1)
    // §4.3 真机修复（2026-09-14）：Refresh 显式全宽——未挂 width 时遮罩（width('100%') 相对 Refresh 测量）
    // 解析为内容固有宽 → 渐显带右边缺一条竖带（四界面同源，用户截图实证）
    .width('100%')
    .onRefreshing(() => { this.handleRefresh(); })
  }

  /**
   * §4.3 帖子多列内容块（floor-vanish 修复配套，2026-09-14）：多列 = 「列内独立堆叠」Row
   * （`i % 列数` 轮转 + 滞回最短列补位，方案 B，与 §4.9 ThreadDetail 同款）——观感与瀑布流一致
   * （无行内对齐留白），但不依赖任何虚拟滚动容器视口（Scroll 全量渲染，绕开 floor-vanish 剔除 bug）。
   * 分桶为前缀稳定贪心：翻页追加从头重算、旧卡落列不变（不跳位）。
   */
  @Builder
  PostColumnsBlock(cards: PostCardItem[], inSearch: boolean) {
    Row({ space: Spacing.md }) {
      ForEach(this.postColumnsData(cards), (col: PostCardItem[], colIdx: number) => {
        Column({ space: Spacing.md }) {
          ForEach(col, (card: PostCardItem) => {
            this.PostCard(card, inSearch)
          }, (card: PostCardItem) => `pc_${inSearch ? 1 : 0}_${card.tid}`)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }, (col: PostCardItem[], colIdx: number) => `pcol_${inSearch ? 1 : 0}_${colIdx}_${col.length}_${col[0]?.tid ?? 'e'}`)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
  }

  /** 帖子分桶（方案 B 带滞回最短列）：默认轮转保序，高差 > FAV_COL_BALANCE_THRESHOLD 才补位 */
  private postColumnsData(cards: PostCardItem[]): PostCardItem[][] {
    const cols: number = this.favColumns();
    const buckets: PostCardItem[][] = [];
    const heights: number[] = [];
    for (let c = 0; c < cols; c++) {
      buckets.push([]);
      heights.push(0);
    }
    // 列宽（估算换行用）：窗口宽 − 横向 padding(lg×2) − 列间 gap(md×(cols−1))
    const colWidth: number = (this.pageWidth - Spacing.lg * 2 - Spacing.md * (cols - 1)) / cols;
    for (let i = 0; i < cards.length; i++) {
      let target: number = i % cols;
      let shortest: number = 0;
      for (let c = 1; c < cols; c++) {
        if (heights[c] < heights[shortest]) {
          shortest = c;
        }
      }
      if (heights[target] - heights[shortest] > FavoriteTab.FAV_COL_BALANCE_THRESHOLD) {
        target = shortest;
      }
      buckets[target].push(cards[i]);
      heights[target] += this.estimatePostCardHeight(cards[i], colWidth) + Spacing.md;
    }
    return buckets;
  }

  /** PostCard 估算高（vp，仅供列均衡，不求像素准只求相对准）：基线 + 标题 ≤2 行 + 摘要 ≤3 行 */
  private estimatePostCardHeight(card: PostCardItem, colWidth: number): number {
    let h: number = 108;
    const title: string = card.title ?? '';
    if (title.length > 0) {
      const cpl: number = Math.max(6, Math.floor(colWidth / 17));
      h += Math.min(Math.ceil(title.length / cpl), 2) * 24;
    }
    const abs: string = card.abstract ?? '';
    if (abs.length > 0) {
      const cpl2: number = Math.max(8, Math.floor(colWidth / 14));
      h += Math.min(Math.ceil(abs.length / cpl2), 3) * 22 + 6;
    }
    return h;
  }

  /** BUG-03：收藏本地搜索结果视图（列表复用 PostCard；空关键词 / 无结果显示提示态） */
  @Builder
  SearchResultView() {
    Column() {
      if (this.searchKeyword.trim().length === 0) {
        Column({ space: Spacing.md }) {
          SymbolGlyph($r('sys.symbol.magnifyingglass'))
            .fontColor([$r('sys.color.icon_tertiary')])
            .fontSize(fs(40, this.fontScale))
          Text('搜索收藏帖子、吧或分类')
            .fontSize(fs(14, this.fontScale))
            .fontColor(Theme.textSecondary(this.isDark))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.searchResults().length === 0) {
        Column({ space: Spacing.md }) {
          SymbolGlyph($r('sys.symbol.magnifyingglass'))
            .fontColor([$r('sys.color.icon_tertiary')])
            .fontSize(fs(40, this.fontScale))
          Text('未找到相关收藏')
            .fontSize(fs(14, this.fontScale))
            .fontColor(Theme.textSecondary(this.isDark))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        // §4.3 改动五（2026-09-14 三次更正）：多列 = Scroll 全量渲染 + 列内独立堆叠（floor-vanish 修复 +
        // 遮罩挂滚动层与原 List 同口径）；**手机单列恢复原 List**（WaterFlow 单列属虚拟滚动容器，同有
        // floor-vanish 风险，且原手机行为零回归红线）
        if (this.favColumns() > 1) {
          Scroll() {
            Column({ space: Spacing.md }) {
              Column().width('100%').height(FavoriteTab.THREAD_TOP_PLACEHOLDER)
              this.PostColumnsBlock(this.searchResults(), true)
              Column().width('100%').height(90)
            }
            .width('100%')
          }
          .width('100%')
          .layoutWeight(1)
          .padding({ left: Spacing.lg, right: Spacing.lg, bottom: Spacing.lg })
          .scrollBar(BarState.Off)
          .clip(false)
          .align(Alignment.TopStart)
          .edgeEffect(EdgeEffect.Spring)
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        } else {
          List({ space: Spacing.md }) {
            ListItem() {
              Column().width('100%').height(FavoriteTab.THREAD_TOP_PLACEHOLDER)
            }
            .backgroundColor(Color.Transparent)
            ForEach(this.searchResults(), (card: PostCardItem) => {
              ListItem() {
                this.PostCard(card, true)
              }
            }, (card: PostCardItem) => `search_${card.tid}`)
            // 底部占位：给 74vp 底部 Tab 栏让位 + 缓冲
            ListItem() {
              Column().width('100%').height(90)
            }
            .backgroundColor(Color.Transparent)
          }
          .width('100%')
          .layoutWeight(1)
          .padding({ left: Spacing.lg, right: Spacing.lg, bottom: Spacing.lg })
          .scrollBar(BarState.Off)
          .clip(false)
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        }
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  TopBar() {
    Row() {
      if (this.searchMode) {
        // §4.3 改动五结论二（已定稿）：返回圆钮内嵌进搜索框内部左侧（与槽位路径同步）
        Stack({ alignContent: Alignment.Start }) {
          TextInput({ placeholder: '搜索收藏帖子、吧或分类', text: this.searchKeyword })
            .width('100%')
            .height(40)
            .fontSize(fs(15, this.fontScale))
            .backgroundColor(Color.Transparent)
            .shadow(Theme.glassShadowStyle()).backgroundEffect(ImmBlur.control())
            .systemMaterial(ImmMaterial.control())
            .borderRadius(Radius.full)
            .padding({ left: 46, right: 14 })
            .defaultFocus(true)
            .onChange((v: string) => { this.searchKeyword = v; })
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontColor([$r('sys.color.icon_primary')])
            .fontSize(fs(28, this.fontScale))
            .margin({ left: 12 })
            .hitTestBehavior(HitTestMode.Block)
            .accessibilityText('退出搜索')
            .onClick((): void => { this.exitSearch(); })
        }
        .width('100%')
        .height(44)
      } else if (this.editMode) {
        Button() {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontColor([$r('sys.color.icon_primary')])
            .fontSize(fs(28, this.fontScale))
        }
        .width(44)
        .height(44)
        .backgroundColor(Theme.segGlass(this.isDark, false))
        .border({ width: 0.5, color: Theme.manualGlassBorder() })
        .backgroundBlurStyle(BlurStyle.Thin, { scale: 0.85 })
        .shadow(Theme.segGlassShadow(this.isDark, false))
        .borderRadius(Radius.full)
        .margin({ right: Spacing.sm })
        .accessibilityText('退出编辑')
        .onClick(() => { this.exitEditMode(); })

        Text(`已选 ${this.selectedTids.length} 项`)
          .fontSize(fs(18, this.fontScale))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      } else if (this.selectedCategoryId.length > 0) {
        Button() {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontColor([$r('sys.color.icon_primary')])
            .fontSize(fs(28, this.fontScale))
        }
        .width(44)
        .height(44)
        .backgroundColor(Theme.segGlass(this.isDark, false))
        .border({ width: 0.5, color: Theme.manualGlassBorder() })
        .backgroundBlurStyle(BlurStyle.Thin, { scale: 0.85 })
        .shadow(Theme.segGlassShadow(this.isDark, false))
        .borderRadius(Radius.full)
        .margin({ right: Spacing.sm })
        .accessibilityText('返回')
        .onClick(() => {
          this.selectedCategoryId = '';
          lastSelectedCategoryId = '';
        })

        Text(this.selectedCategoryName())
          .fontSize(fs(22, this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)

        Row() {
          Text('⇅')
            .fontSize(fs(20, this.fontScale))
            .fontColor(Theme.textPrimary(this.isDark))
        }
        .width(44)
        .height(44)
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .backgroundColor(Theme.segGlass(this.isDark, false))
        .border({ width: 0.5, color: Theme.manualGlassBorder() })
        .backgroundBlurStyle(BlurStyle.Thin, { scale: 0.85 })
        .borderRadius(Radius.full)
        .margin({ left: Spacing.sm })
        .accessibilityText('排序')
        .accessibilityDescription(this.sortModeLabel(this.sortMode))
        .onClick(() => { this.openSortMenu(); })

        Button() {
          Text('编辑')
            .fontSize(fs(14, this.fontScale))
            .fontColor($r('sys.color.font_primary'))
        }
        .height(40)
        .padding({ left: 14, right: 14 })
        .backgroundColor(Theme.segGlass(this.isDark, false))
        .border({ width: 0.5, color: Theme.manualGlassBorder() })
        .backgroundBlurStyle(BlurStyle.Thin, { scale: 0.85 })
        .shadow(Theme.segGlassShadow(this.isDark, false))
        .borderRadius(Radius.full)
        .margin({ left: Spacing.sm })
        .accessibilityText('编辑')
        .onClick(() => {
          this.editMode = true;
          this.favEditing = true;
          this.selectedTids = [];
        })
      } else if (this.selectedForum.length > 0) {
        Button() {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontColor([$r('sys.color.icon_primary')])
            .fontSize(fs(28, this.fontScale))
        }
        .width(44)
        .height(44)
        .backgroundColor(Theme.segGlass(this.isDark, false))
        .border({ width: 0.5, color: Theme.manualGlassBorder() })
        .backgroundBlurStyle(BlurStyle.Thin, { scale: 0.85 })
        .shadow(Theme.segGlassShadow(this.isDark, false))
        .borderRadius(Radius.full)
        .margin({ right: Spacing.sm })
        .accessibilityText('返回')
        .onClick(() => { this.selectedForum = ''; })

        Text(this.selectedForum)
          .fontSize(fs(22, this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)

        Row() {
          Text('⇅')
            .fontSize(fs(20, this.fontScale))
            .fontColor(Theme.textPrimary(this.isDark))
        }
        .width(44)
        .height(44)
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .backgroundColor(Theme.segGlass(this.isDark, false))
        .border({ width: 0.5, color: Theme.manualGlassBorder() })
        .backgroundBlurStyle(BlurStyle.Thin, { scale: 0.85 })
        .borderRadius(Radius.full)
        .accessibilityText('排序')
        .accessibilityDescription(this.sortModeLabel(this.sortMode))
        .onClick(() => { this.openSortMenu(); })

        Button() {
          Text('编辑')
            .fontSize(fs(14, this.fontScale))
            .fontColor($r('sys.color.font_primary'))
        }
        .height(40)
        .padding({ left: 14, right: 14 })
        .backgroundColor(Theme.segGlass(this.isDark, false))
        .border({ width: 0.5, color: Theme.manualGlassBorder() })
        .backgroundBlurStyle(BlurStyle.Thin, { scale: 0.85 })
        .shadow(Theme.segGlassShadow(this.isDark, false))
        .borderRadius(Radius.full)
        .margin({ left: Spacing.sm })
        .accessibilityText('编辑')
        .onClick(() => {
          this.editMode = true;
          this.favEditing = true;
          this.selectedTids = [];
        })
      } else {
        Text('收藏')
          .fontSize(fs(22, this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.font_primary'))

        Blank()

        if (this.categoryTab === FavCategoryTab.Custom) {
          Button() {
            Text('备份')
              .fontSize(fs(14, this.fontScale))
              .fontColor($r('sys.color.font_primary'))
          }
          .height(40)
          .padding({ left: 14, right: 14 })
          .backgroundColor(Theme.segGlass(this.isDark, false))
          .border({ width: 0.5, color: Theme.manualGlassBorder() })
          .backgroundBlurStyle(BlurStyle.Thin, { scale: 0.85 })
          .borderRadius(Radius.full)
          .margin({ left: Spacing.sm })
          .accessibilityText('备份')
          .onClick(() => { this.showBackupSheet(); })
        }

        Row() {
          Text('⇅')
            .fontSize(fs(20, this.fontScale))
            .fontColor(Theme.textPrimary(this.isDark))
        }
        .width(44)
        .height(44)
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .backgroundColor(Theme.segGlass(this.isDark, false))
        .border({ width: 0.5, color: Theme.manualGlassBorder() })
        .backgroundBlurStyle(BlurStyle.Thin, { scale: 0.85 })
        .borderRadius(Radius.full)
        .margin({ left: 12 })
        .accessibilityText('排序')
        .accessibilityDescription(this.sortModeLabel(this.sortMode))
        .onClick(() => { this.openSortMenu(); })

        Button() {
          SymbolGlyph($r('sys.symbol.magnifyingglass'))
            .fontColor([$r('sys.color.icon_primary')])
            .fontSize(fs(20, this.fontScale))
        }
        .width(44)
        .height(44)
        .backgroundColor(Theme.segGlass(this.isDark, false))
        .border({ width: 0.5, color: Theme.manualGlassBorder() })
        .backgroundBlurStyle(BlurStyle.Thin, { scale: 0.85 })
        .borderRadius(Radius.full)
        .margin({ left: 12 })
        .accessibilityText('搜索')
        .onClick(() => { this.enterSearch(); })
      }
    }
    .width('100%')
    .padding({ left: Spacing.lg, right: Spacing.lg, top: 44, bottom: 10 })
    .backgroundColor(Color.Transparent)
    .zIndex(14)
  }

  /** 槽内 44 圆钮（返回/搜索）：Button 必须显式 backgroundColor(Color.Transparent) 清默认品牌蓝填充，
   *  材质 = ImmMaterial.seg(false)（THIN 中性档，与首页/进吧/详情页顶栏同一套材质语言）；
   *  旧写法的 segGlass / border / backgroundBlurStyle / segGlassShadow 四项按官方口径全部删除（坑 24）。 */
  @Builder
  FavSlotCircleBtn(symbol: Resource, symbolSize: number, accessText: string, m: Margin, onTap: () => void) {
    Button() {
      SymbolGlyph(symbol)
        .fontColor([$r('sys.color.icon_primary')])
        .fontSize(fs(symbolSize, this.fontScale))
    }
    .width(44)
    .height(44)
    .backgroundColor(Color.Transparent)
    .systemMaterial(ImmMaterial.seg(false))
    .borderRadius(Radius.full)
    .margin(m)
    .accessibilityText(accessText)
    .onClick(onTap)
  }

  /** 槽内排序钮（⇅）：Row 无默认填充无需清底，直接挂 ImmMaterial.seg(false)；几何与旧写法逐项一致。 */
  @Builder
  FavSlotSortBtn(m: Margin) {
    Row() {
      Text('⇅')
        .fontSize(fs(20, this.fontScale))
        .fontColor(Theme.textPrimary(this.isDark))
    }
    .width(44)
    .height(44)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .systemMaterial(ImmMaterial.seg(false))
    .borderRadius(Radius.full)
    .margin(m)
    .accessibilityText('排序')
    .accessibilityDescription(this.sortModeLabel(this.sortMode))
    .onClick(() => { this.openSortMenu(); })
  }

  /** 槽内文字胶囊钮（编辑/备份）：Button 清默认品牌蓝填充 + ImmMaterial.seg(false)；几何与旧写法逐项一致。 */
  @Builder
  FavSlotTextBtn(label: string, accessText: string, m: Margin, onTap: () => void) {
    Button() {
      Text(label)
        .fontSize(fs(14, this.fontScale))
        .fontColor($r('sys.color.font_primary'))
    }
    .height(40)
    .padding({ left: 14, right: 14 })
    .backgroundColor(Color.Transparent)
    .systemMaterial(ImmMaterial.seg(false))
    .borderRadius(Radius.full)
    .margin(m)
    .accessibilityText(accessText)
    .onClick(onTap)
  }

  /**
   * 官方槽位标题栏（§6.10 同机制）：TopBar 五种形态（搜索态 / 编辑态 / 分类内 / 吧内 / 根态）塞进同一
   * 个 title builder 条件渲染，几何（top 44 / bottom 10 / 左右 Spacing.lg / 圆钮 44 / 文字钮 40 / 边距）
   * 与旧 TopBar 逐项一致；玻璃换成槽内子元素各自的 systemMaterial。
   * 搜索态 TextInput 原挂的 ImmMaterial.control() 在页面 body 属 out of scope 从不渲染（一直是
   *  backgroundEffect 在撑观感），进槽位后首次真正生效 → 按坑 24 口径删掉与其双叠的 shadow + backgroundEffect。
   * 无 zIndex / 无底色：槽内不需要叠层序，title options 已显式透明。
   */
  @Builder
  FavTitleBarRow() {
    Row() {
      if (this.searchMode) {
        // §4.3 改动五结论二（已定稿）：返回圆钮内嵌进搜索框内部左侧 → 搜索框左右边缘与卡片网格严格对齐
        Stack({ alignContent: Alignment.Start }) {
          TextInput({ placeholder: '搜索收藏帖子、吧或分类', text: this.searchKeyword })
            .width('100%')
            .height(40)
            .fontSize(fs(15, this.fontScale))
            .backgroundColor(Color.Transparent)
            .systemMaterial(ImmMaterial.control())
            .borderRadius(Radius.full)
            .padding({ left: 46, right: 14 })
            .defaultFocus(true)
            .onChange((v: string) => { this.searchKeyword = v; })
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontColor([$r('sys.color.icon_primary')])
            .fontSize(fs(28, this.fontScale))
            .margin({ left: 12 })
            .hitTestBehavior(HitTestMode.Block)
            .accessibilityText('退出搜索')
            .onClick((): void => { this.exitSearch(); })
        }
        .width('100%')
        .height(44) // 与旧 44 圆钮同高 → 槽位高度 98 不变
      } else if (this.editMode) {
        this.FavSlotCircleBtn($r('sys.symbol.chevron_left'), 28, '退出编辑', { right: Spacing.sm }, (): void => { this.exitEditMode(); })

        Text(`已选 ${this.selectedTids.length} 项`)
          .fontSize(fs(18, this.fontScale))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      } else if (this.selectedCategoryId.length > 0) {
        this.FavSlotCircleBtn($r('sys.symbol.chevron_left'), 28, '返回', { right: Spacing.sm }, (): void => {
          this.selectedCategoryId = '';
          lastSelectedCategoryId = '';
        })

        Text(this.selectedCategoryName())
          .fontSize(fs(22, this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)

        this.FavSlotSortBtn({ left: Spacing.sm })
        this.FavSlotTextBtn('编辑', '编辑', { left: Spacing.sm }, (): void => {
          this.editMode = true;
          this.favEditing = true;
          this.selectedTids = [];
        })
      } else if (this.selectedForum.length > 0) {
        this.FavSlotCircleBtn($r('sys.symbol.chevron_left'), 28, '返回', { right: Spacing.sm }, (): void => { this.selectedForum = ''; })

        Text(this.selectedForum)
          .fontSize(fs(22, this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)

        this.FavSlotSortBtn({})
        this.FavSlotTextBtn('编辑', '编辑', { left: Spacing.sm }, (): void => {
          this.editMode = true;
          this.favEditing = true;
          this.selectedTids = [];
        })
      } else {
        Text('收藏')
          .fontSize(fs(22, this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.font_primary'))

        Blank()

        if (this.categoryTab === FavCategoryTab.Custom) {
          this.FavSlotTextBtn('备份', '备份', { left: Spacing.sm }, (): void => { this.showBackupSheet(); })
        }

        this.FavSlotSortBtn({ left: 12 })
        this.FavSlotCircleBtn($r('sys.symbol.magnifyingglass'), 20, '搜索', { left: 12 }, (): void => { this.enterSearch(); })
      }
    }
    .width('100%')
    .padding({ left: Spacing.lg, right: Spacing.lg, top: 44, bottom: 10 })
  }

  /**
   * 官方槽位标题栏（§6.10 同机制）：第一行 = 五形态按钮行（`FavTitleBarRow`），
   * 第二行 = 「吧分类 / 自定义分类」胶囊（仅根态显示，条件与 `favTitleBarHeight()` 逐项一致）。
   * 胶囊玻璃换成 `ImmMaterial.seg(active)`（选中 REGULAR / 未选中 THIN —— 与旧 Regular/Thin 双档模糊同构，
   * 选中感仍由文字强调色 + 字重承担），四项自绘玻璃（segGlass / border / backgroundBlurStyle / segGlassShadow）
   * 按坑 24 全删；Button 显式 backgroundColor(Color.Transparent) 清默认品牌蓝填充；
   * 显式 height(40)（用户反馈 32 偏扁，加高为参考图饱满胶囊）；padding top 2 = 原 top:100 - TopBar 98。
   * 旧 CategoryTabs 的 zIndex(13) 与 listBaseTransition 左让位动画不再适用（槽内无叠层序；进退收藏夹时
   * 胶囊行改为随 title 高度直接出现/消失，不再随内容区滑动 —— 观感偏差已记入文档落地清单）。
   */
  @Builder
  FavTitleBar() {
    Column() {
      this.FavTitleBarRow()

      if (!this.searchMode && this.selectedForum.length === 0 && this.selectedCategoryId.length === 0) {
        Row({ space: Spacing.sm }) {
          Button('吧分类')
            .fontSize(fs(12, this.fontScale))
            .fontWeight(this.categoryTab === FavCategoryTab.Forums ? FontWeight.Bold : FontWeight.Medium)
            .fontColor(this.categoryTab === FavCategoryTab.Forums
              ? $r('sys.color.font_emphasize') : $r('sys.color.font_secondary'))
            .backgroundColor(Color.Transparent)
            .systemMaterial(ImmMaterial.seg(this.categoryTab === FavCategoryTab.Forums))
            .borderRadius(Radius.full)
            .height(40)
            // §4.3 改动一：平板（多列档）胶囊按内容自适应宽 + 整行靠左；手机保持等分铺满
            .layoutWeight(this.favColumns() > 1 ? 0 : 1)
            .padding({ left: 22, right: 22 })
            .accessibilityText('吧分类')
            .onClick(() => { this.switchCategoryTab(FavCategoryTab.Forums); })
          Button('自定义分类')
            .fontSize(fs(12, this.fontScale))
            .fontWeight(this.categoryTab === FavCategoryTab.Custom ? FontWeight.Bold : FontWeight.Medium)
            .fontColor(this.categoryTab === FavCategoryTab.Custom
              ? $r('sys.color.font_emphasize') : $r('sys.color.font_secondary'))
            .backgroundColor(Color.Transparent)
            .systemMaterial(ImmMaterial.seg(this.categoryTab === FavCategoryTab.Custom))
            .borderRadius(Radius.full)
            .height(40)
            .layoutWeight(this.favColumns() > 1 ? 0 : 1)
            .padding({ left: 22, right: 22 })
            .accessibilityText('自定义分类')
            .onClick(() => { this.switchCategoryTab(FavCategoryTab.Custom); })
          if (this.favColumns() > 1) {
            // 平板：剩余宽度全部吸到右侧，两胶囊自然贴左（§4.3 改动一）
            Blank()
          }
        }
        .width('100%')
        .padding({ left: Spacing.lg, right: Spacing.lg, top: 2, bottom: Spacing.sm })
      }
    }
    .width('100%')
  }

  /** 帖流页顶部满宽渐变层：铺在内容底层，让顶部渐变左右贯通，不被卡片圆角裁切 */
  @Builder
  TopGradientLayer() {
    Column()
      .width('100%')
      .height(136)
      .linearGradient({
        direction: GradientDirection.Bottom,
        colors: [
          [this.isDark ? '#CC1B1E24' : '#E6FFFFFF', 0.0],
          [this.isDark ? '#001B1E24' : '#00FFFFFF', 1.0]
        ]
      })
      .hitTestBehavior(HitTestMode.None)
  }

  /**
   * 排序菜单内容（系统 `bindMenu` 的 CustomBuilder）。
   * 原自绘浮层的外壳（全屏遮罩 / `position` / 玻璃自绘 / 弹出动画）已全部交给 `bindMenu`：
   * 定位 → 隐形锚点 + `Placement.BottomRight`；背景 / 圆角 / 描边 / 阴影 → `options.systemMaterial`。
   * 此处只保留菜单项本体（宽度 210、内边距、选中高亮 + ✓、「自定义排序」置灰全部零改动）。
   */
  @Builder
  SortMenuContent() {
    Column({ space: 2 }) {
      this.SortMenuItem(SortMode.NameAsc, '名称正序', false)
      this.SortMenuItem(SortMode.NameDesc, '名称倒序', false)
      this.SortMenuItem(SortMode.TimeAsc, '最早添加', false)
      this.SortMenuItem(SortMode.TimeDesc, '最新添加', false)
      this.SortMenuItem(SortMode.Custom, '自定义排序', !this.canCustomSort())
    }
    .padding({ top: 6, bottom: 6 })
  }

  @Builder
  SortMenuItem(mode: SortMode, label: string, disabled: boolean) {
    Row({ space: 10 }) {
      Text(label)
        .fontSize(fs(14, this.fontScale))
        .fontWeight(FontWeight.Medium)
        .fontColor(disabled ? Theme.textTertiary(this.isDark)
          : (this.sortMode === mode ? Theme.brand() : Theme.textPrimary(this.isDark)))
        .layoutWeight(1)
      if (this.sortMode === mode) {
        Text('✓')
          .fontSize(fs(13, this.fontScale))
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.brand())
      }
    }
    .width(210)
    .padding({ left: 16, right: 16, top: 13, bottom: 13 })
    .borderRadius(Radius.md)
    .onClick(() => { this.applySortMode(mode, disabled); })
  }

  @Builder
  CategoryTabs() {
    Row({ space: Spacing.sm }) {
      Button('吧分类')
        .fontSize(fs(12, this.fontScale))
        .fontWeight(this.categoryTab === FavCategoryTab.Forums ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(this.categoryTab === FavCategoryTab.Forums ? $r('sys.color.font_emphasize') : $r('sys.color.font_secondary'))
        .backgroundColor(Theme.segGlass(this.isDark, this.categoryTab === FavCategoryTab.Forums))
        .border({ width: 0.5, color: Theme.manualGlassBorder() })
        .backgroundBlurStyle(this.categoryTab === FavCategoryTab.Forums ? BlurStyle.Regular : BlurStyle.Thin,
          { scale: this.categoryTab === FavCategoryTab.Forums ? 0.8 : 0.85 })
        .borderRadius(Radius.full)
        .height(40)
        // §4.3 改动一：平板（多列档）胶囊按内容自适应宽 + 整行靠左；手机保持等分铺满（与槽位路径同步）
        .layoutWeight(this.favColumns() > 1 ? 0 : 1)
        .padding({ left: 22, right: 22 })
        .accessibilityText('吧分类')
        .onClick(() => { this.switchCategoryTab(FavCategoryTab.Forums); })
      Button('自定义分类')
        .fontSize(fs(12, this.fontScale))
        .fontWeight(this.categoryTab === FavCategoryTab.Custom ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(this.categoryTab === FavCategoryTab.Custom ? $r('sys.color.font_emphasize') : $r('sys.color.font_secondary'))
        .backgroundColor(Theme.segGlass(this.isDark, this.categoryTab === FavCategoryTab.Custom))
        .border({ width: 0.5, color: Theme.manualGlassBorder() })
        .backgroundBlurStyle(this.categoryTab === FavCategoryTab.Custom ? BlurStyle.Regular : BlurStyle.Thin,
          { scale: this.categoryTab === FavCategoryTab.Custom ? 0.8 : 0.85 })
        .borderRadius(Radius.full)
        .height(40)
        .layoutWeight(this.favColumns() > 1 ? 0 : 1)
        .padding({ left: 22, right: 22 })
        .accessibilityText('自定义分类')
        .onClick(() => { this.switchCategoryTab(FavCategoryTab.Custom); })
      if (this.favColumns() > 1) {
        Blank()
      }
    }
    .width('100%')
    .padding({ left: Spacing.lg, right: Spacing.lg, top: 100, bottom: Spacing.sm })
    .zIndex(13)
    // 点开/返回收藏夹时随内容区同步左让位/回位，避免内容从按钮条下方穿过的突兀感
    .transition(this.firstMount ? TransitionEffect.IDENTITY : this.listBaseTransition())
  }

  /** v1.15.6 分类管理操作行（居中卡片风格）：系统 SymbolGlyph 图标 + 标题 + 右箭头，透明底 + 行间分隔线，危险操作用 Theme.danger */
  @Builder
  ActionRow(symbol: Resource, title: string, danger: boolean, onTap: () => void) {
    Row({ space: Spacing.md }) {
      SymbolGlyph(symbol)
        .fontColor([danger ? Theme.danger() : Theme.textPrimary(this.isDark)])
        .fontSize(fs(19, this.fontScale))
      Text(title)
        .fontSize(fs(15, this.fontScale))
        .fontWeight(FontWeight.Medium)
        .fontColor(danger ? Theme.danger() : Theme.textPrimary(this.isDark))
        .layoutWeight(1)
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontColor([$r('sys.color.icon_tertiary')])
        .fontSize(fs(14, this.fontScale))
    }
    .width('100%')
    .padding({ left: Spacing.md, right: Spacing.md, top: 12, bottom: 12 })
    .accessibilityText(title)
    .onClick(onTap)
  }

  /**
   * 顶部满宽渐显带（真机三次修复终版，2026-09-14）：原「整页 DST_IN 遮罩 + blendMode OFFSCREEN」方案的
   * 离屏层宽度在手机上解析异常——四个界面渐显带右缘同缺一条竖带、平板正常（Refresh 全宽 / 挂点回迁均无效）
   * → 改为 **Stack 顶层满宽背景色渐变条**（ThreadList TopFadeBand 成品同款思路）：
   * 下层是纯背景色，背景色渐变条叠加 = 视觉等价渐隐，宽度跟随 FavContent Stack（全宽已被页面背景实证），
   * 彻底不依赖列表宿主宽度解析。
   * 高 132 = TopBar 98 + 分段切换区 ~34（只盖按钮与标题区，用户拍板口径）；hitTestBehavior(None) 不挡交互；
   * zIndex 8：盖住列表内容，低于 EditBar(15) / 兜底 CategoryTabs(13)，槽位顶栏在 Navigation title 层更高。
   * 渐变**从顶部即线性渐变、无全实段**（真机四修，2026-09-14）：首版 [bg,0]→[bg,0.5]→[透明,1] 的前半段
   * 全实背景色会让内容一进条顶就被盖死（硬切感，用户真机驳回）——改 [bg,0]→[transparent,1] 线性后与
   * 首页挖洞式「内容从顶栏下渐现」观感一致。
   */
  @Builder
  TopFadeBand() {
    Column()
      .width('100%')
      .height(132)
      .linearGradient({
        direction: GradientDirection.Bottom,
        colors: [
          [Theme.bg(this.isDark), 0.0],
          [this.isDark ? '#00101114' : '#00F2F4F7', 1.0]
        ]
      })
      .hitTestBehavior(HitTestMode.None)
  }
}
