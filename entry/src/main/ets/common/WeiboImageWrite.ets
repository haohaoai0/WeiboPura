import { fileIo } from '@kit.CoreFileKit';

/** fileIo.write may complete short. Never report a truncated photo as saved. */
export async function writeWeiboImage(fd: number, bytes: ArrayBuffer): Promise<void> {
  if (bytes.byteLength === 0) { throw new Error('图片内容为空'); }
  let written: number = 0;
  while (written < bytes.byteLength) {
    const count: number = await fileIo.write(fd, bytes.slice(written));
    if (count <= 0 || count > bytes.byteLength - written) { throw new Error('图片保存不完整，请重试'); }
    written += count;
  }
}
