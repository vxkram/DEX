import { describe, expect, it } from 'vitest';
import { sniff } from '@/lib/image/sniff';
import { kindOf, withExtension, baseName } from '@/lib/shared/names';

const bytes = (...parts: (string | number[])[]) =>
  new Uint8Array(parts.flatMap((p) => (typeof p === 'string' ? [...p].map((c) => c.charCodeAt(0)) : p)));
const le32 = (n: number) => [n & 255, (n >> 8) & 255, (n >> 16) & 255, (n >> 24) & 255];
const be32 = (n: number) => [(n >> 24) & 255, (n >> 16) & 255, (n >> 8) & 255, n & 255];
const riff = (...chunks: number[][]) => {
  const body = chunks.flat();
  return bytes('RIFF', le32(body.length + 4), 'WEBP', body);
};
const chunk = (type: string, data: number[]) => [...bytes(type), ...le32(data.length), ...data, ...(data.length & 1 ? [0] : [])];

describe('sniff', () => {
  it('reads a PNG header', () => {
    const ihdr = [...be32(13), ...bytes('IHDR'), ...be32(10), ...be32(10), 16, 6, 0, 0, 0, 0, 0, 0, 0];
    const facts = sniff(bytes([0x89], 'PNG', [13, 10, 26, 10], ihdr));
    expect(facts).toMatchObject({ format: 'png', bitDepth: 16, hasAlpha: true, losslessCoded: true, frames: 1 });
  });

  it('tells lossy from lossless WebP', () => {
    expect(sniff(riff(chunk('VP8 ', [0, 0, 0, 0]))).losslessCoded).toBe(false);
    const vp8l = sniff(riff(chunk('VP8L', [0x2f, ...le32(1 << 28)])));
    expect(vp8l).toMatchObject({ losslessCoded: true, hasAlpha: true });
  });

  it('counts animated WebP frames', () => {
    const frame = chunk('ANMF', [...new Array(16).fill(0), ...chunk('VP8 ', [0, 0])]);
    const facts = sniff(riff(chunk('VP8X', [0x12, 0, 0, 0, 0, 0, 0, 0, 0, 0]), chunk('ANIM', [0, 0, 0, 0, 0, 0]), frame, frame, frame));
    expect(facts).toMatchObject({ format: 'webp', frames: 3, hasAlpha: true, losslessCoded: false });
  });

  it('knows JPEG and unknown bytes', () => {
    expect(sniff(bytes([0xff, 0xd8, 0xff, 0xd9])).format).toBe('jpeg');
    expect(sniff(bytes('hello world!')).format).toBe('other');
  });
});

describe('download names', () => {
  it('spots WebP and WebM by type or name', () => {
    expect(kindOf({ mime: 'image/webp' })).toBe('webp');
    expect(kindOf({ mime: 'application/octet-stream', url: 'https://x.test/a/clip.WEBM?x=1' })).toBe('webm');
    expect(kindOf({ filename: '/Users/me/Downloads/photo.webp' })).toBe('webp');
    expect(kindOf({ mime: 'image/png', url: 'https://x.test/a.png' })).toBeNull();
  });

  it('swaps extensions', () => {
    expect(withExtension('photo.webp', 'png')).toBe('photo.png');
    expect(withExtension('clip', 'mp4')).toBe('clip.mp4');
    expect(baseName('https://x.test/a/my%20pic.webp?w=2')).toBe('my pic.webp');
    expect(baseName('C:\\Users\\me\\Downloads\\a.webm')).toBe('a.webm');
  });
});
