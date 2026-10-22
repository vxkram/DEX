// Crop-box maths, ported from MediaModel/CropMath.swift.

export interface Size { width: number; height: number }
export interface Rect { x: number; y: number; width: number; height: number }

export type CropHandle = 'move' | 'topLeft' | 'top' | 'topRight' | 'right' | 'bottomRight' | 'bottom' | 'bottomLeft' | 'left';

/** The eight draggable handles around the box. */
export const edgeHandles: CropHandle[] = ['topLeft', 'top', 'topRight', 'right', 'bottomRight', 'bottom', 'bottomLeft', 'left'];

export const isCorner = (h: CropHandle) => h === 'topLeft' || h === 'topRight' || h === 'bottomRight' || h === 'bottomLeft';

export const minimumSide = 16;

/** Intersection with an image of `size`, or null if nothing is left. */
export function clamped(rect: Rect, size: Size): Rect | null {
  const left = Math.max(0, rect.x), top = Math.max(0, rect.y);
  const right = Math.min(size.width, rect.x + rect.width), bottom = Math.min(size.height, rect.y + rect.height);
  if (right <= left || bottom <= top) return null;
  return { x: left, y: top, width: right - left, height: bottom - top };
}

export const sameRect = (a: Rect, b: Rect) => a.x === b.x && a.y === b.y && a.width === b.width && a.height === b.height;

/**
 * Moves or resizes `start` by a drag, keeping it inside the image and, when
 * `ratio` (width / height) is set, at that aspect ratio.
 */
export function adjust(start: Rect, handle: CropHandle, dx: number, dy: number, size: Size, ratio: number | null): Rect {
  dx = Math.round(dx);
  dy = Math.round(dy);
  if (handle === 'move') {
    const x = Math.min(Math.max(start.x + dx, 0), size.width - start.width);
    const y = Math.min(Math.max(start.y + dy, 0), size.height - start.height);
    return { x, y, width: start.width, height: start.height };
  }
  let left = start.x, top = start.y, right = start.x + start.width, bottom = start.y + start.height;
  if (handle === 'topLeft' || handle === 'left' || handle === 'bottomLeft') left += dx;
  if (handle === 'topRight' || handle === 'right' || handle === 'bottomRight') right += dx;
  if (handle === 'topLeft' || handle === 'top' || handle === 'topRight') top += dy;
  if (handle === 'bottomLeft' || handle === 'bottom' || handle === 'bottomRight') bottom += dy;

  left = Math.min(Math.max(left, 0), right - minimumSide);
  top = Math.min(Math.max(top, 0), bottom - minimumSide);
  right = Math.max(Math.min(right, size.width), left + minimumSide);
  bottom = Math.max(Math.min(bottom, size.height), top + minimumSide);

  if (ratio != null) {
    // Corner drags only: derive height from width, anchored at the opposite
    // corner, shrinking both if that would leave the image.
    const anchorsTop = handle === 'bottomLeft' || handle === 'bottomRight';
    const anchorsLeft = handle === 'topRight' || handle === 'bottomRight';
    let width = right - left;
    let height = Math.round(width / ratio);
    const room = anchorsTop ? size.height - top : bottom;
    if (height > room) {
      height = room;
      width = Math.round(height * ratio);
    }
    if (anchorsLeft) right = left + width; else left = right - width;
    if (anchorsTop) bottom = top + height; else top = bottom - height;
  }
  return { x: left, y: top, width: right - left, height: bottom - top };
}

/** The largest rect of `ratio` centred in the image. */
export function centred(ratio: number, size: Size): Rect {
  let width = size.width;
  let height = Math.round(width / ratio);
  if (height > size.height) {
    height = size.height;
    width = Math.round(height * ratio);
  }
  return { x: Math.floor((size.width - width) / 2), y: Math.floor((size.height - height) / 2), width, height };
}

/** Aspect presets for the crop tool. */
export const cropAspects = ['1:1', '4:3', '3:4', '16:9', '9:16'] as const;
export type CropAspect = (typeof cropAspects)[number];

export function aspectRatio(aspect: string): number {
  const [w, h] = aspect.split(':').map(Number);
  return w / h;
}

export type FrameMode = 'crop' | 'fit';

/**
 * Where an image of `source` size goes in an output `box`: scaled to cover it
 * (`crop`) or to fit inside it (`fit`), never enlarged, centred. What the
 * image doesn't cover is background.
 */
export function placeIn(source: Size, box: Size, mode: FrameMode): Rect {
  const scale = Math.min(1, mode === 'crop'
    ? Math.max(box.width / source.width, box.height / source.height)
    : Math.min(box.width / source.width, box.height / source.height));
  const width = Math.max(1, Math.round(source.width * scale));
  const height = Math.max(1, Math.round(source.height * scale));
  return { x: Math.round((box.width - width) / 2), y: Math.round((box.height - height) / 2), width, height };
}

/** The smallest box of `ratio` that holds the whole image at its own size. */
export function boxAround(size: Size, ratio: number): Size {
  return size.width / size.height > ratio
    ? { width: size.width, height: Math.round(size.width / ratio) }
    : { width: Math.round(size.height * ratio), height: size.height };
}
