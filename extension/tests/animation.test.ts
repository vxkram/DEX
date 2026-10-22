import { describe, expect, it } from 'vitest';
import { encodeGif } from '@/lib/image/animation';

const frame = (width: number, height: number, pixel: (i: number) => [number, number, number, number]) => {
  const data = new Uint8ClampedArray(width * height * 4);
  for (let i = 0; i < width * height; i++) data.set(pixel(i), i * 4);
  return { data, width, height, colorSpace: 'srgb' } as ImageData;
};

describe('GIF encoding', () => {
  it('keeps every colour when a frame has 256 or fewer', async () => {
    const a = frame(16, 16, (i) => [i, 255 - i, 7, 255]);
    const b = frame(16, 16, (i) => (i % 2 ? [0, 0, 0, 0] : [10, 20, 30, 255]));
    const gif = encodeGif([a, b], [100, 100]);
    expect(gif.reduced).toBe(false);
    expect(gif.alphaRounded).toBe(false);
    const bytes = new Uint8Array(await gif.blob.arrayBuffer());
    expect(String.fromCharCode(...bytes.subarray(0, 6))).toBe('GIF89a');
  });

  it('says so when a frame needs fewer colours', () => {
    const noisy = frame(32, 32, (i) => [i & 255, (i >> 2) & 255, (i * 7) & 255, 255]);
    expect(encodeGif([noisy], [0]).reduced).toBe(true);
  });

  it('notices partial transparency', () => {
    expect(encodeGif([frame(4, 4, () => [1, 2, 3, 100])], [0]).alphaRounded).toBe(true);
  });
});
