import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';

export interface WeiboUploadImage {
  data: ArrayBuffer;
  mimeType: string;
  fileName: string;
}

/** Picker grants access only to selected URIs; no broad photo-library permission. */
export async function prepareWeiboImage(uri: string): Promise<WeiboUploadImage> {
  const file: fileIo.File = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
  let source: image.ImageSource | null = null;
  let pixelMap: image.PixelMap | null = null;
  let packer: image.ImagePacker | null = null;
  try {
    const size: number = (await fileIo.stat(file.fd)).size;
    if (size <= 0 || size > 30 * 1024 * 1024) {
      throw new Error('请选择不超过 30 MB 的图片');
    }
    if (size < 6) { throw new Error('图片读取不完整，请重新选择'); }
    const signature: ArrayBuffer = new ArrayBuffer(6);
    let signatureRead: number = 0;
    while (signatureRead < 6) {
      const chunk: ArrayBuffer = new ArrayBuffer(6 - signatureRead);
      fileIo.lseek(file.fd, signatureRead, fileIo.WhenceType.SEEK_SET);
      const count: number = await fileIo.read(file.fd, chunk, { length: 6 - signatureRead });
      if (count <= 0) { throw new Error('图片读取不完整，请重新选择'); }
      new Uint8Array(signature).set(new Uint8Array(chunk, 0, count), signatureRead);
      signatureRead += count;
    }
    const bytes: Uint8Array = new Uint8Array(signature);
    if (bytes[0] === 0x47 && bytes[1] === 0x49 && bytes[2] === 0x46) {
      if (size > 10 * 1024 * 1024) { throw new Error('GIF 请控制在 10 MB 以内'); }
      const data: ArrayBuffer = new ArrayBuffer(size);
      let read: number = 0;
      while (read < size) {
        const chunk: ArrayBuffer = new ArrayBuffer(size - read);
        fileIo.lseek(file.fd, read, fileIo.WhenceType.SEEK_SET);
        const count: number = await fileIo.read(file.fd, chunk, { length: size - read });
        if (count <= 0) { throw new Error('图片读取不完整，请重新选择'); }
        new Uint8Array(data).set(new Uint8Array(chunk, 0, count), read);
        read += count;
      }
      return { data: data, mimeType: 'image/gif', fileName: 'weibo.gif' };
    }
    fileIo.lseek(file.fd, 0, fileIo.WhenceType.SEEK_SET);
    source = image.createImageSource(file.fd);
    const info: image.ImageInfo = await source.getImageInfo();
    const scale: number = Math.min(1, 2000 / Math.max(info.size.width, info.size.height));
    pixelMap = await source.createPixelMap({
      desiredSize: { width: Math.max(1, Math.round(info.size.width * scale)), height: Math.max(1, Math.round(info.size.height * scale)) }
    });
    packer = image.createImagePacker();
    // JPEG conversion handles HEIC/PNG/WebP and limits upload memory/data costs.
    const data: ArrayBuffer = await packer.packToData(pixelMap, { format: 'image/jpeg', quality: 90 });
    if (data.byteLength > 10 * 1024 * 1024) { throw new Error('图片过大，请选择较小的图片'); }
    return { data: data, mimeType: 'image/jpeg', fileName: 'weibo.jpg' };
  } finally {
    try { if (packer !== null) { await packer.release(); } } catch (_error) {}
    try { if (pixelMap !== null) { await pixelMap.release(); } } catch (_error) {}
    try { if (source !== null) { await source.release(); } } catch (_error) {}
    await fileIo.close(file.fd);
  }
}
