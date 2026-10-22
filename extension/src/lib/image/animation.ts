// Animated GIF and WebP: every frame decoded (ImageDecoder composites them,
// disposal and all), and GIFs written back with gifenc.

import { applyPalette, GIFEncoder, quantize, type Palette } from 'gifenc';

export interface Animation {
  frames: ImageBitmap[];
  /** Per-frame display time, in milliseconds. */
  delays: number[];
}

/** Decoded frames are kept in memory: refuse animations above this many pixels in all. */
const maxTotalPixels = 150_000_000;
export const maxFrames = 1000;

/** All frames, or null when the browser can't decode them one by one. */
export async function decodeFrames(blob: Blob, type: 'image/gif' | 'image/webp'): Promise<Animation | null> {
  if (typeof ImageDecoder === 'undefined' || !(await ImageDecoder.isTypeSupported(type))) return null;
  const decoder = new ImageDecoder({ data: await blob.arrayBuffer(), type });
  try {
    await decoder.tracks.ready;
    await decoder.completed;
    const track = decoder.tracks.selectedTrack;
    const count = track?.frameCount ?? 0;
    if (count < 2) return null;
    if (count > maxFrames) throw new Error(`This animation has ${count} frames, above DEX’s limit of ${maxFrames}.`);
    const frames: ImageBitmap[] = [];
    const delays: number[] = [];
    for (let i = 0; i < count; i++) {
      const { image } = await decoder.decode({ frameIndex: i });
      if (i === 0 && image.displayWidth * image.displayHeight * count > maxTotalPixels) {
        image.close();
        throw new Error('This animation is too large to edit in the browser.');
      }
      frames.push(await createImageBitmap(image));
      // Browsers play delays under 20 ms as 100 ms; keep what the file says.
      delays.push(Math.max(10, Math.round((image.duration ?? 100_000) / 1000)));
      image.close();
    }
    return { frames, delays };
  } finally {
    decoder.close();
  }
}

export interface GifResult {
  blob: Blob;
  /** Some frame had more than 256 colours and was quantized. */
  reduced: boolean;
  /** Some pixel was partly transparent and had to become fully one or the other. */
  alphaRounded: boolean;
}

/**
 * Writes frames as an animated GIF. Each frame gets its own exact palette
 * when it has 256 colours or fewer (no loss); only frames with more are
 * quantized, and the result says so.
 */
export function encodeGif(frames: ImageData[], delays: number[]): GifResult {
  const gif = GIFEncoder();
  let reduced = false, alphaRounded = false;
  frames.forEach((frame, i) => {
    const { data, width, height } = frame;
    const exact = exactPalette(data);
    alphaRounded ||= exact.alphaRounded;
    let palette: Palette, index: Uint8Array, transparentIndex = -1;
    if (exact.palette) {
      ({ palette, index, transparentIndex } = exact as Required<typeof exact>);
    } else {
      reduced = true;
      palette = quantize(data, 256, { format: 'rgba4444', oneBitAlpha: true, clearAlpha: true });
      index = applyPalette(data, palette, 'rgba4444');
      transparentIndex = palette.findIndex((c) => c[3] === 0);
    }
    gif.writeFrame(index, width, height, {
      palette: palette.map((c) => c.slice(0, 3)),
      delay: delays[i],
      repeat: 0,
      ...(transparentIndex >= 0 && { transparent: true, transparentIndex, dispose: 2 }),
    });
  });
  gif.finish();
  return { blob: new Blob([gif.bytes()], { type: 'image/gif' }), reduced, alphaRounded };
}

/** A palette holding every colour of the frame, if there are 256 or fewer. */
function exactPalette(data: Uint8ClampedArray) {
  const lookup = new Map<number, number>();
  const palette: Palette = [];
  const index = new Uint8Array(data.length / 4);
  let transparentIndex = -1, alphaRounded = false;
  for (let p = 0, i = 0; i < data.length; i += 4, p++) {
    const a = data[i + 3];
    if (a !== 0 && a !== 255) alphaRounded = true;
    if (a < 128) {
      if (transparentIndex < 0) {
        if (palette.length >= 256) return { palette: null, alphaRounded };
        transparentIndex = palette.length;
        palette.push([0, 0, 0]);
      }
      index[p] = transparentIndex;
      continue;
    }
    const key = (data[i] << 16) | (data[i + 1] << 8) | data[i + 2];
    let slot = lookup.get(key);
    if (slot === undefined) {
      if (palette.length >= 256) return { palette: null, alphaRounded };
      slot = palette.length;
      lookup.set(key, slot);
      palette.push([data[i], data[i + 1], data[i + 2]]);
    }
    index[p] = slot;
  }
  return { palette, index, transparentIndex, alphaRounded };
}
