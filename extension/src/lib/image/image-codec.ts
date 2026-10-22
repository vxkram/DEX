// Decoding, editing and encoding through OffscreenCanvas. Works in extension
// pages, Firefox's background page and Chrome's offscreen document.

import type { Rect } from './crop-math';
import { decodeFrames, encodeGif, type Animation } from './animation';
import { frameHasGap, orientedSize, mimeType, type Capabilities, type Frame, type Geometry, type Note, type Plan, type Source, type TargetFormat } from './planner';
import { sniff } from './sniff';

export interface Loaded {
  bitmap: ImageBitmap;
  source: Source;
  bytes: Blob;
  /** Every frame, for animated GIF and WebP. */
  animation: Animation | null;
}

/** Pixels above this aren't scanned for alpha; the planner then assumes it's used. */
const alphaScanLimit = 40_000_000;

export async function load(blob: Blob): Promise<Loaded> {
  const facts = sniff(new Uint8Array(await blob.slice(0, 256 * 1024).arrayBuffer()));
  if (facts.format === 'other') throw new Error('This isn’t an image DEX can open.');
  let animation: Animation | null = null;
  if (facts.frames > 1 && (facts.format === 'gif' || facts.format === 'webp')) {
    animation = await decodeFrames(blob, `image/${facts.format}`);
    if (animation) facts.frames = animation.frames.length;
  }
  const bitmap = animation?.frames[0] ?? await createImageBitmap(blob, { imageOrientation: 'from-image', premultiplyAlpha: 'none' });
  let usesAlpha: boolean | null = facts.hasAlpha ? null : false;
  let semiTransparent: boolean | null = facts.hasAlpha ? null : false;
  if (facts.hasAlpha && bitmap.width * bitmap.height <= alphaScanLimit) {
    ({ usesAlpha, semiTransparent } = scanAlpha(bitmap));
  }
  return { bitmap, bytes: blob, animation, source: { ...facts, width: bitmap.width, height: bitmap.height, usesAlpha, semiTransparent } };
}

function scanAlpha(bitmap: ImageBitmap) {
  const canvas = new OffscreenCanvas(bitmap.width, bitmap.height);
  const ctx = canvas.getContext('2d', { willReadFrequently: true })!;
  ctx.drawImage(bitmap, 0, 0);
  const data = ctx.getImageData(0, 0, bitmap.width, bitmap.height).data;
  let usesAlpha = false;
  for (let i = 3; i < data.length; i += 4) {
    const a = data[i];
    if (a !== 255) {
      usesAlpha = true;
      if (a !== 0) return { usesAlpha, semiTransparent: true };
    }
  }
  return { usesAlpha, semiTransparent: false };
}

/** The image turned and flipped as the user sees it, before cropping. */
export function orient(bitmap: ImageBitmap | OffscreenCanvas, geometry: Geometry): OffscreenCanvas {
  const size = orientedSize(bitmap, geometry);
  const canvas = new OffscreenCanvas(size.width, size.height);
  const ctx = canvas.getContext('2d')!;
  ctx.translate(size.width / 2, size.height / 2);
  ctx.rotate((geometry.turns % 4) * Math.PI / 2);
  ctx.scale(geometry.flipH ? -1 : 1, geometry.flipV ? -1 : 1);
  ctx.drawImage(bitmap, -bitmap.width / 2, -bitmap.height / 2);
  return canvas;
}

/**
 * Crops an oriented image and places it in its frame, painting the
 * background around it. Works at any scale: the editor's preview passes a
 * smaller copy with the geometry scaled to match.
 */
export function compose(oriented: OffscreenCanvas, crop: Rect | null, frame: Frame | null): OffscreenCanvas {
  const src = crop ?? { x: 0, y: 0, width: oriented.width, height: oriented.height };
  const size = frame ?? src;
  const out = new OffscreenCanvas(Math.max(1, size.width), Math.max(1, size.height));
  const ctx = out.getContext('2d')!;
  ctx.imageSmoothingEnabled = true;
  ctx.imageSmoothingQuality = 'high';
  const image = frame?.image ?? { x: 0, y: 0, width: src.width, height: src.height };
  if (frame && frameHasGap(frame)) paintBackground(ctx, oriented, src, frame);
  ctx.drawImage(oriented, src.x, src.y, src.width, src.height, image.x, image.y, image.width, image.height);
  return out;
}

function paintBackground(ctx: OffscreenCanvasRenderingContext2D, oriented: OffscreenCanvas, src: Rect, frame: Frame) {
  const { background } = frame;
  if (background.kind === 'color') {
    ctx.fillStyle = background.color;
    ctx.fillRect(0, 0, frame.width, frame.height);
  } else if (background.kind === 'blur') {
    // Shrink to a few dozen pixels, then grow back in doubling steps, each
    // softened: smooth at any size, and the same in every browser (one big
    // stretch shows blocks; canvas filters aren't everywhere).
    const cover = Math.max(frame.width / src.width, frame.height / src.height);
    const w = src.width * cover, h = src.height * cover;
    const shrink = 32 / Math.max(w, h);
    let step = new OffscreenCanvas(Math.max(1, Math.round(w * shrink)), Math.max(1, Math.round(h * shrink)));
    const first = step.getContext('2d')!;
    first.imageSmoothingQuality = 'high';
    first.drawImage(oriented, src.x, src.y, src.width, src.height, 0, 0, step.width, step.height);
    while (Math.max(step.width, step.height) < Math.min(512, Math.max(w, h))) {
      const next = new OffscreenCanvas(step.width * 2, step.height * 2);
      const c = next.getContext('2d')!;
      c.imageSmoothingQuality = 'high';
      if ('filter' in c) c.filter = 'blur(1.5px)';
      // Drawn a little oversized, so the softening has picture to pull in at
      // the edges instead of transparency.
      const m = 6;
      c.drawImage(step, -m, -m, next.width + 2 * m, next.height + 2 * m);
      step = next;
    }
    ctx.drawImage(step, (frame.width - w) / 2, (frame.height - h) / 2, w, h);
    // Darkened a little so the image stands out from it.
    ctx.fillStyle = 'rgba(0, 0, 0, 0.18)';
    ctx.fillRect(0, 0, frame.width, frame.height);
  }
}

/** Applies the plan's geometry and draws the final pixels. */
export function render(bitmap: ImageBitmap | OffscreenCanvas, plan: Plan): OffscreenCanvas {
  const { geometry, target } = plan.request;
  const composed = compose(orient(bitmap, geometry), geometry.crop, geometry.frame);
  const { width, height } = plan.outputSize;
  if (target !== 'jpeg' && composed.width === width && composed.height === height) return composed;
  const out = new OffscreenCanvas(width, height);
  const ctx = out.getContext('2d')!;
  if (target === 'jpeg') {
    ctx.fillStyle = '#fff';
    ctx.fillRect(0, 0, width, height);
  }
  ctx.imageSmoothingEnabled = true;
  ctx.imageSmoothingQuality = 'high';
  ctx.drawImage(composed, 0, 0, width, height);
  return out;
}

export async function encode(canvas: OffscreenCanvas, target: TargetFormat, quality: number | null): Promise<Blob> {
  const blob = await canvas.convertToBlob({ type: mimeType[target], ...(quality != null && { quality }) });
  // Browsers that can't write a type quietly fall back to PNG.
  if (blob.type !== mimeType[target]) throw new Error(`This browser can’t write ${target.toUpperCase()} files.`);
  return blob;
}

export interface Exported {
  blob: Blob;
  /** Losses only the encoder could find out about (GIF colours, for one). */
  notes: Note[];
}

/** Runs a plan: the original bytes when nothing changes, otherwise a re-encode. */
export async function exportImage(loaded: Loaded, plan: Plan): Promise<Exported> {
  if (plan.strategy === 'copyFile') return { blob: loaded.bytes, notes: [] };
  const { target, frames: range } = plan.request;
  const frames = loaded.animation?.frames;
  if (target === 'gif') {
    const all = frames ?? [loaded.bitmap];
    const start = range?.start ?? 0, end = range?.end ?? all.length - 1;
    const pixels: ImageData[] = [];
    for (let i = start; i <= end; i++) {
      const canvas = render(all[i], plan);
      pixels.push(canvas.getContext('2d', { willReadFrequently: true })!.getImageData(0, 0, canvas.width, canvas.height));
    }
    const delays = loaded.animation?.delays.slice(start, end + 1) ?? [0];
    const gif = encodeGif(pixels, delays);
    const notes: Note[] = [];
    if (gif.reduced) notes.push({ text: 'GIF holds 256 colours per frame: frames with more were reduced', isLoss: true });
    if (gif.alphaRounded && !loaded.source.semiTransparent) {
      notes.push({ text: 'Semi-transparent pixels become fully clear or solid: GIF has no partial transparency', isLoss: true });
    }
    return { blob: gif.blob, notes };
  }
  // A still from an animation is the frame on the timeline.
  const still = frames?.[range?.current ?? 0] ?? loaded.bitmap;
  return { blob: await encode(render(still, plan), target, plan.encodeQuality), notes: [] };
}

let capabilities: Promise<Capabilities> | undefined;

/**
 * What this browser's encoders really do. WebP at quality 1 is lossless in
 * some browsers and not others, so it's measured, not assumed.
 */
export function detectCapabilities(): Promise<Capabilities> {
  capabilities ??= (async () => {
    try {
      const size = 32;
      const canvas = new OffscreenCanvas(size, size);
      const ctx = canvas.getContext('2d', { willReadFrequently: true })!;
      const pixels = ctx.createImageData(size, size);
      for (let i = 0; i < pixels.data.length; i += 4) {
        // Noise that a lossy encoder can't keep exactly.
        pixels.data[i] = (i * 37) & 255;
        pixels.data[i + 1] = (i * 91 + 13) & 255;
        pixels.data[i + 2] = (i * 53 + 101) & 255;
        pixels.data[i + 3] = 255;
      }
      ctx.putImageData(pixels, 0, 0);
      const webp = await canvas.convertToBlob({ type: 'image/webp', quality: 1 });
      if (webp.type !== 'image/webp') return { webpMaxIsLossless: false, canWriteWebP: false };
      const decoded = await createImageBitmap(webp, { colorSpaceConversion: 'none', premultiplyAlpha: 'none' });
      const check = new OffscreenCanvas(size, size).getContext('2d', { willReadFrequently: true })!;
      check.drawImage(decoded, 0, 0);
      const back = check.getImageData(0, 0, size, size).data;
      const exact = back.every((value, i) => value === pixels.data[i]);
      return { webpMaxIsLossless: exact, canWriteWebP: true };
    } catch {
      return { webpMaxIsLossless: false, canWriteWebP: false };
    }
  })();
  return capabilities;
}
