// Decides what an export will cost in quality, with the Mac app's wording
// (MediaModel/Planner.swift, ConversionPlan.swift). Pure, so the UI shows the
// verdict live and tests cover the combinations.
//
// The browser can't do what DEX on the Mac does with ImageIO and
// libjpeg-turbo: every pixel change is a decode and re-encode through a
// canvas, which is 8-bit sRGB and drops metadata. The notes say so.

import type { Rect, Size } from './crop-math';
import type { SourceFacts, SourceFormat } from './sniff';

export type TargetFormat = 'png' | 'jpeg' | 'webp' | 'gif';
export const targetFormats: TargetFormat[] = ['png', 'jpeg', 'webp'];
/** For animations: GIF keeps them moving, the rest save the frame on the timeline. */
export const animatedTargetFormats: TargetFormat[] = ['gif', 'png', 'jpeg', 'webp'];

export type Verdict = 'noReencode' | 'lossless' | 'lossy';

export const verdictLabel: Record<Verdict, string> = {
  noReencode: 'No re-encode',
  lossless: 'Lossless',
  lossy: 'Re-encode (lossy)',
};

export const displayName: Record<SourceFormat | TargetFormat, string> = {
  png: 'PNG', jpeg: 'JPEG', webp: 'WebP', gif: 'GIF', avif: 'AVIF', bmp: 'BMP', other: 'Image',
};

export const fileExtension: Record<TargetFormat, string> = { png: 'png', jpeg: 'jpg', webp: 'webp', gif: 'gif' };
export const mimeType: Record<TargetFormat, string> = { png: 'image/png', jpeg: 'image/jpeg', webp: 'image/webp', gif: 'image/gif' };

/** JPEG and lossy WebP never go above this, as on the Mac. */
export const maximumLossyQuality = 0.95;

export type Background = { kind: 'color'; color: string } | { kind: 'blur' } | { kind: 'transparent' };

/** An output canvas the (cropped) image is placed in, with background around it. */
export interface Frame {
  width: number;
  height: number;
  /** Where the image is drawn, in frame pixels. */
  image: Rect;
  background: Background;
}

export interface Geometry {
  /** Clockwise quarter turns, applied after the flips. */
  turns: number;
  flipH: boolean;
  flipV: boolean;
  /** In display space: after the file's own orientation and the turns/flips. */
  crop: Rect | null;
  /** Applied after the crop. */
  frame: Frame | null;
  /** Final size of the whole result. */
  resize: Size | null;
}

export const noGeometry: Geometry = { turns: 0, flipH: false, flipV: false, crop: null, frame: null, resize: null };

/** The frame leaves part of the canvas to the background. */
export function frameHasGap(frame: Frame): boolean {
  const { image } = frame;
  return image.x > 0 || image.y > 0 || image.x + image.width < frame.width || image.y + image.height < frame.height;
}

export interface Source extends SourceFacts {
  /** Displayed size (browsers apply EXIF orientation when decoding). */
  width: number;
  height: number;
  /** Any pixel with alpha < 255, found by scanning; null when not scanned. */
  usesAlpha: boolean | null;
  /** Any pixel with 0 < alpha < 255; null when not scanned. */
  semiTransparent: boolean | null;
}

export interface Request {
  target: TargetFormat;
  /** 'max': lossless for WebP when the browser can, 0.95 for JPEG. */
  quality: 'max' | number;
  geometry: Geometry;
  /** For animations, from the timeline (0-based, inclusive). */
  frames?: FrameRange;
}

export interface FrameRange {
  /** The frame a still image is made from. */
  current: number;
  /** The part a GIF keeps. */
  start: number;
  end: number;
}

export const isTrimmed = (range: FrameRange | undefined, count: number) =>
  range != null && (range.start > 0 || range.end < count - 1);

export interface Capabilities {
  /** The browser's WebP encoder is lossless at quality 1 (checked at runtime). */
  webpMaxIsLossless: boolean;
  canWriteWebP: boolean;
}

export interface Note { text: string; isLoss: boolean }

export interface Plan {
  request: Request;
  /** Copy the original bytes, or decode and encode. */
  strategy: 'copyFile' | 'reencode';
  verdict: Verdict;
  notes: Note[];
  /** Encoder quality handed to the canvas, when encoding. */
  encodeQuality: number | null;
  losslessAlternative: TargetFormat | null;
  outputSize: Size;
}

export const maxMegapixels = 250;

const loss = (text: string): Note => ({ text, isLoss: true });
const info = (text: string): Note => ({ text, isLoss: false });

const sizeText = (s: Size) => `${s.width} × ${s.height}`;

export function lossyValue(quality: Request['quality']): number {
  return quality === 'max' ? maximumLossyQuality : Math.min(Math.max(quality, 0), 1);
}

export function orientedSize(source: Size, geometry: Geometry): Size {
  return geometry.turns % 2 ? { width: source.height, height: source.width } : { width: source.width, height: source.height };
}

export function plan(source: Source, request: Request, caps: Capabilities): Plan {
  const megapixels = Math.floor((source.width * source.height) / 1_000_000);
  if (megapixels > maxMegapixels) throw new Error(`The image is ${megapixels} megapixels, above the ${maxMegapixels} MP safety limit.`);

  const result = basePlan(source, request, caps);
  if (result.verdict === 'lossy') {
    const png: Request = { ...request, target: 'png' };
    if (request.target !== 'png' && basePlan(source, png, caps).verdict !== 'lossy') result.losslessAlternative = 'png';
  }
  return result;
}

function basePlan(source: Source, request: Request, caps: Capabilities): Plan {
  const { target, geometry } = request;
  const display = orientedSize(source, geometry);
  const crop = geometry.crop && !(geometry.crop.x === 0 && geometry.crop.y === 0 && geometry.crop.width === display.width && geometry.crop.height === display.height)
    ? geometry.crop : null;
  const croppedSize = crop ? { width: crop.width, height: crop.height } : display;
  const frame = geometry.frame;
  const framedSize = frame ? { width: frame.width, height: frame.height } : croppedSize;
  const gap = frame != null && frameHasGap(frame);
  const resize = geometry.resize && !(geometry.resize.width === framedSize.width && geometry.resize.height === framedSize.height)
    && geometry.resize.width >= 1 && geometry.resize.height >= 1 ? geometry.resize : null;
  const reorients = geometry.turns % 4 !== 0 || geometry.flipH || geometry.flipV;
  const outputSize = resize ?? framedSize;

  // WebP at max quality only counts as lossless when this browser's encoder
  // actually is; otherwise every WebP encode is lossy.
  const webpLossless = target === 'webp' && request.quality === 'max' && caps.webpMaxIsLossless;
  const wantsLossy = (target === 'jpeg' || target === 'webp') && request.quality !== 'max';

  // 1. Same format, nothing to change: hand back the original bytes.
  const trimmed = target === 'gif' && isTrimmed(request.frames, source.frames);
  if (source.format === target && !crop && !frame && !resize && !reorients && !wantsLossy && !trimmed) {
    return { request, strategy: 'copyFile', verdict: 'noReencode', notes: [], encodeQuality: null, losslessAlternative: null, outputSize };
  }

  // 2. Everything else goes through a canvas.
  const losses: Note[] = [];
  const notes: Note[] = [];
  let encodeQuality: number | null = null;

  if (target === 'jpeg' || (target === 'webp' && !webpLossless)) {
    encodeQuality = lossyValue(request.quality);
    losses.push(loss(`${displayName[target]} encoding at quality ${Math.round(encodeQuality * 100)}`));
  } else if (target === 'webp') {
    encodeQuality = 1;
  }
  if (frame && (frame.image.width !== croppedSize.width || frame.image.height !== croppedSize.height)) {
    losses.push(loss(`Image scaled from ${sizeText(croppedSize)} to ${sizeText(frame.image)}: resampling creates new pixels`));
  }
  if (resize) losses.push(loss(`Resized from ${sizeText(framedSize)} to ${sizeText(resize)}: resampling creates new pixels`));
  const transparentBackground = gap && frame!.background.kind === 'transparent';
  if (target === 'jpeg' && ((source.hasAlpha && source.usesAlpha !== false) || transparentBackground)) {
    losses.push(loss('Transparency will be flattened onto white'));
  }
  if (source.frames > 1 && target === 'gif' && trimmed) {
    const { start, end } = request.frames!;
    notes.push(info(`Keeps frames ${start + 1}–${end + 1} of ${source.frames}`));
  } else if (source.frames > 1 && target !== 'gif') {
    // Picking a frame on the timeline is a choice, not a loss.
    notes.push(request.frames
      ? info(`Saves frame ${request.frames.current + 1} of ${source.frames} as a still image`)
      : loss(`Animation will be reduced to its first frame (of ${source.frames})`));
  }
  if (target === 'gif' && source.semiTransparent) {
    losses.push(loss('Semi-transparent pixels become fully clear or solid: GIF has no partial transparency'));
  }
  if (source.bitDepth != null && source.bitDepth > 8) losses.push(loss(`Colour depth reduced from ${source.bitDepth}-bit to 8-bit`));
  if (source.wideColourProfile) losses.push(loss('Colours will be converted from the embedded profile to sRGB, which can shift them slightly'));
  if (source.semiTransparent && target !== 'jpeg' && target !== 'gif') {
    losses.push(loss('Semi-transparent pixels can shift by a shade: browsers store them premultiplied'));
  }
  if (losses.length === 0 && !source.losslessCoded) {
    notes.push(info('No additional loss. The file will likely be larger'));
  }
  if (gap) {
    const bg = frame!.background;
    notes.push(info(bg.kind === 'color' ? `Background added around the image: ${bg.color.toUpperCase()}`
      : bg.kind === 'blur' ? 'Background added around the image: a blurred copy of it'
      : 'Transparent background added around the image'));
  }
  notes.push(info('Metadata (camera, location, copyright) is removed: browsers can’t carry it over'));

  return {
    request,
    strategy: 'reencode',
    verdict: losses.length ? 'lossy' : 'lossless',
    notes: [...losses, ...notes],
    encodeQuality,
    losslessAlternative: null,
    outputSize,
  };
}
