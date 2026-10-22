// Screenshots of the visible page, whole or a selected part. Runs in the
// background (OffscreenCanvas exists in Chrome's service worker too).

export interface Area { x: number; y: number; width: number; height: number }

/** Crops a captureVisibleTab image to an area given in CSS pixels. */
export async function cropCapture(dataUrl: string, area: Area | null, viewport: { width: number; height: number }): Promise<Blob> {
  const blob = await (await fetch(dataUrl)).blob();
  if (!area) return blob;
  const image = await createImageBitmap(blob);
  // The capture is in device pixels; work out the ratio from it rather than
  // trusting devicePixelRatio, which page zoom changes.
  const scale = image.width / viewport.width;
  const x = Math.round(area.x * scale), y = Math.round(area.y * scale);
  const width = Math.max(1, Math.min(image.width - x, Math.round(area.width * scale)));
  const height = Math.max(1, Math.min(image.height - y, Math.round(area.height * scale)));
  const canvas = new OffscreenCanvas(width, height);
  canvas.getContext('2d')!.drawImage(image, x, y, width, height, 0, 0, width, height);
  image.close();
  return canvas.convertToBlob({ type: 'image/png' });
}

/** "Screenshot 2026-10-22 at 10.51.16", like macOS names them. */
export function screenshotName(now = new Date()): string {
  const two = (n: number) => String(n).padStart(2, '0');
  return `Screenshot ${now.getFullYear()}-${two(now.getMonth() + 1)}-${two(now.getDate())} at ${two(now.getHours())}.${two(now.getMinutes())}.${two(now.getSeconds())}`;
}
