import { describe, expect, it } from 'vitest';
import { noGeometry, plan, type Capabilities, type Request, type Source } from '@/lib/image/planner';

const caps: Capabilities = { webpMaxIsLossless: true, canWriteWebP: true };
const opaque = { hasAlpha: false, usesAlpha: false, semiTransparent: false, frames: 1, bitDepth: 8, wideColourProfile: false };
const png: Source = { ...opaque, format: 'png', losslessCoded: true, width: 1200, height: 800 };
const jpeg: Source = { ...opaque, format: 'jpeg', losslessCoded: false, width: 1200, height: 800 };
const lossyWebP: Source = { ...opaque, format: 'webp', losslessCoded: false, width: 1200, height: 800 };
const crop = { ...noGeometry, crop: { x: 10, y: 10, width: 500, height: 400 } };

const request = (target: Request['target'], extra: Partial<Request> = {}): Request => ({ target, quality: 'max', geometry: noGeometry, ...extra });
const texts = (p: ReturnType<typeof plan>) => p.notes.map((n) => n.text);

describe('planner', () => {
  it('copies the bytes when nothing changes', () => {
    const p = plan(jpeg, request('jpeg'), caps);
    expect(p.strategy).toBe('copyFile');
    expect(p.verdict).toBe('noReencode');
    expect(p.notes).toEqual([]);
  });

  it('calls a PNG crop lossless', () => {
    const p = plan(png, request('png', { geometry: crop }), caps);
    expect(p.verdict).toBe('lossless');
    expect(p.outputSize).toEqual({ width: 500, height: 400 });
  });

  it('calls a JPEG crop lossy in the browser and offers PNG', () => {
    const p = plan(jpeg, request('jpeg', { geometry: crop }), caps);
    expect(p.verdict).toBe('lossy');
    expect(texts(p)[0]).toBe('JPEG encoding at quality 95');
    expect(p.losslessAlternative).toBe('png');
  });

  it('says a lossy source gains no further loss as PNG', () => {
    const p = plan(lossyWebP, request('png'), caps);
    expect(p.verdict).toBe('lossless');
    expect(texts(p)).toContain('No additional loss. The file will likely be larger');
  });

  it('flattens transparency for JPEG only when pixels use it', () => {
    const clear: Source = { ...png, hasAlpha: true, usesAlpha: true, semiTransparent: false };
    expect(texts(plan(clear, request('jpeg'), caps))).toContain('Transparency will be flattened onto white');
    const unused: Source = { ...png, hasAlpha: true, usesAlpha: false, semiTransparent: false };
    expect(texts(plan(unused, request('jpeg'), caps))).not.toContain('Transparency will be flattened onto white');
  });

  it('warns that soft edges shift through a canvas', () => {
    const soft: Source = { ...png, hasAlpha: true, usesAlpha: true, semiTransparent: true };
    expect(plan(soft, request('png', { geometry: crop }), caps).verdict).toBe('lossy');
  });

  it('only trusts WebP max as lossless when the browser proved it', () => {
    expect(plan(png, request('webp'), caps).verdict).toBe('lossless');
    const p = plan(png, request('webp'), { ...caps, webpMaxIsLossless: false });
    expect(p.verdict).toBe('lossy');
    expect(p.encodeQuality).toBe(0.95);
    expect(p.losslessAlternative).toBe('png');
  });

  it('treats a lower quality as a re-encode even in the same format', () => {
    const p = plan(jpeg, request('jpeg', { quality: 0.6 }), caps);
    expect(p.strategy).toBe('reencode');
    expect(texts(p)[0]).toBe('JPEG encoding at quality 60');
  });

  it('lists animation, depth, colour profile and resampling losses', () => {
    const rich: Source = { ...png, frames: 12, bitDepth: 16, wideColourProfile: true };
    const p = plan(rich, request('png', { geometry: { ...noGeometry, resize: { width: 600, height: 400 } } }), caps);
    expect(texts(p)).toEqual(expect.arrayContaining([
      'Resized from 1200 × 800 to 600 × 400: resampling creates new pixels',
      'Animation will be reduced to its first frame (of 12)',
      'Colour depth reduced from 16-bit to 8-bit',
      'Colours will be converted from the embedded profile to sRGB, which can shift them slightly',
    ]));
    // None of those losses can be avoided by switching to PNG.
    expect(p.losslessAlternative).toBeNull();
  });

  it('swaps width and height on a quarter turn', () => {
    expect(plan(png, request('png', { geometry: { ...noGeometry, turns: 1 } }), caps).outputSize).toEqual({ width: 800, height: 1200 });
  });

  it('refuses huge images', () => {
    expect(() => plan({ ...png, width: 30_000, height: 30_000 }, request('png'), caps)).toThrow(/safety limit/);
  });

  it('describes a background added around the image', () => {
    const frame = { width: 1200, height: 1200, image: { x: 0, y: 200, width: 1200, height: 800 } };
    const coloured = plan(png, request('png', { geometry: { ...noGeometry, frame: { ...frame, background: { kind: 'color', color: '#f55c26' } } } }), caps);
    expect(coloured.verdict).toBe('lossless');
    expect(coloured.outputSize).toEqual({ width: 1200, height: 1200 });
    expect(texts(coloured)).toContain('Background added around the image: #F55C26');
    const clear = plan(png, request('jpeg', { geometry: { ...noGeometry, frame: { ...frame, background: { kind: 'transparent' } } } }), caps);
    expect(texts(clear)).toContain('Transparency will be flattened onto white');
  });

  it('counts scaling the image into a frame as resampling', () => {
    const frame = { width: 600, height: 600, image: { x: 0, y: 100, width: 600, height: 400 }, background: { kind: 'blur' } as const };
    const p = plan(png, request('png', { geometry: { ...noGeometry, frame } }), caps);
    expect(p.verdict).toBe('lossy');
    expect(texts(p)[0]).toBe('Image scaled from 1200 × 800 to 600 × 400: resampling creates new pixels');
  });

  describe('animations', () => {
    const gif: Source = { ...png, format: 'gif', losslessCoded: true, frames: 48, width: 400, height: 300 };
    const all = { current: 0, start: 0, end: 47 };

    it('copies an untouched GIF', () => {
      expect(plan(gif, request('gif', { frames: all }), caps).strategy).toBe('copyFile');
    });

    it('keeps a cropped GIF lossless and says what a trim keeps', () => {
      const p = plan(gif, request('gif', { geometry: crop, frames: { current: 0, start: 4, end: 19 } }), caps);
      expect(p.verdict).toBe('lossless');
      expect(texts(p)).toContain('Keeps frames 5–20 of 48');
    });

    it('saves the frame on the timeline as a still, without calling it a loss', () => {
      const p = plan(gif, request('png', { frames: { current: 11, start: 0, end: 47 } }), caps);
      expect(p.verdict).toBe('lossless');
      expect(texts(p)).toContain('Saves frame 12 of 48 as a still image');
    });
  });
});
