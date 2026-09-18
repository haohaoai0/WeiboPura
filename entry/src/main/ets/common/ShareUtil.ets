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
import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';
import { pasteboard, BusinessError } from '@kit.BasicServicesKit';
import { UIContext } from '@kit.ArkUI';
import { ThreadSharePayload } from '../components/CommonComponents';
import { ToastUtil, ToastType } from './ToastUtil';

/**
 * 帖子分享统一工具（第七批 · P2-a 分享复用提炼）。
 * 自 Index.ets/ThreadList.ets 的 shareThread + copyShareToClipboard 提炼，行为保持一致：
 * - 主路径：@kit.ShareKit → systemShare.SharedData(HYPERLINK) + ShareController.show()
 * - 兜底：ShareKit 不可用/面板拉起失败 → 写入系统剪贴板，提示用户手动粘贴
 * - 排障：最外层 try/catch 捕获所有异常 → Toast 显式反馈，避免用户感觉"点了没反应"
 * 收藏模块（Favorite.ets 帖子卡）复用本工具。
 */
export class ShareUtil {
  static shareThread(
    uiContext: UIContext,
    abilityCtx: common.UIAbilityContext | undefined | null,
    data: ThreadSharePayload
  ): void {
    try {
      if (!data || data.tid.length === 0) {
        ToastUtil.show(uiContext, '帖子信息缺失，无法分享', ToastType.Error);
        return;
      }
      const threadUrl: string = `https://tieba.baidu.com/p/${data.tid}`;
      const titleLine: string =
        data.forumName.length > 0 ? `[${data.forumName}] ${data.title}` : data.title;
      const rawAbstract: string = data.abstract ?? '';
      const descriptionText: string =
        rawAbstract.length > 0
          ? (rawAbstract.length > 140 ? `${rawAbstract.substring(0, 140)}…` : rawAbstract)
          : '';
      ShareUtil.shareLink(uiContext, abilityCtx, threadUrl, titleLine, descriptionText);
    } catch (outerErr) {
      const errMsg: string = outerErr instanceof Error ? outerErr.message : String(outerErr);
      ToastUtil.show(uiContext, `分享异常：${errMsg}`, ToastType.Error);
    }
  }

  /** Share an app-owned URL instead of assuming every card is a Tieba thread. */
  static shareLink(
    uiContext: UIContext,
    abilityCtx: common.UIAbilityContext | undefined | null,
    url: string,
    title: string,
    description: string
  ): void {
    try {
      if (url.length === 0) {
        ToastUtil.show(uiContext, '链接缺失，无法分享', ToastType.Error);
        return;
      }
      const fullText: string = description.length > 0 ? `${title}\n${description}\n${url}` : `${title}\n${url}`;
      if (!abilityCtx) {
        // Context 拿不到：直接兜底剪贴板
        ToastUtil.show(uiContext, '系统分享不可用，正在复制链接', ToastType.Info);
        ShareUtil.copyShareToClipboard(uiContext, fullText, title, url);
        return;
      }

      // ========== 主路径：Share Kit 系统分享面板 ==========
      try {
        // ★ 官方Codelabs L426-438 纯链接分享：utd.UniformDataType.HYPERLINK + content字段（图片才用uri+fileUri）
        const sharedData: systemShare.SharedData = new systemShare.SharedData({
          utd: utd.UniformDataType.HYPERLINK,
          content: url,
          title: title,
          description: description
        });
        const controller: systemShare.ShareController = new systemShare.ShareController(sharedData);
        // ★ 官方Codelabs关键修正：controller.show()返回Promise，必须单独.catch()才能捕获异步错误
        controller.show(abilityCtx, {
          previewMode: systemShare.SharePreviewMode.DETAIL,
          selectionMode: systemShare.SelectionMode.SINGLE
        }).then(() => {
          // Promise.resolve = 系统分享面板已成功拉起（用户可能取消/成功，都算面板弹了）
          ToastUtil.show(uiContext, '系统分享面板已弹出', ToastType.Info);
        }).catch((showErr: BusinessError) => {
          // Promise异步reject：这里是面板拉起失败（权限/UTD不支持/其他），把code+msg全量Toast便于定位
          const code: string = showErr?.code !== undefined ? `${showErr.code}` : 'unknown';
          const msg: string = showErr?.message ?? String(showErr);
          ToastUtil.show(uiContext, `分享面板失败[${code}]：${msg}`, ToastType.Error);
          ShareUtil.copyShareToClipboard(uiContext, fullText, title, url);
        });
        return;
      } catch (shareErr) {
        ToastUtil.show(uiContext, '系统分享不可用，正在复制链接', ToastType.Info);
        ShareUtil.copyShareToClipboard(uiContext, fullText, title, url);
      }
    } catch (outerErr) {
      // 全局兜底：任何异常都弹Toast，避免用户感觉点了没反应
      const errMsg: string = outerErr instanceof Error ? outerErr.message : String(outerErr);
      ToastUtil.show(uiContext, `分享异常：${errMsg}`, ToastType.Error);
    }
  }

  /**
   * 兜底：写入系统剪贴板，保证分享失败时用户仍可粘贴发送（pasteboard @kit.BasicServicesKit）
   * 任何内部异常都会被外层 shareThread 捕获弹 Toast，避免二次静默失败
   */
  private static copyShareToClipboard(uiContext: UIContext, fullText: string, title: string, url: string): void {
    try {
      const sysPasteboard = pasteboard.getSystemPasteboard();
      const pasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, fullText);
      sysPasteboard.setData(pasteData, (err: BusinessError | undefined) => {
        if (err) {
          ToastUtil.show(uiContext, `复制失败：${err.message || String(err)}`, ToastType.Error);
        } else {
          ToastUtil.show(uiContext, `已复制「${title}」链接，粘贴即可分享`, ToastType.Success);
        }
      });
    } catch (clipboardErr) {
      const errMsg: string = clipboardErr instanceof Error ? clipboardErr.message : String(clipboardErr);
      ToastUtil.show(uiContext, `剪贴板不可用：${errMsg}；帖子链接：${url}`, ToastType.Error);
    }
  }
}
