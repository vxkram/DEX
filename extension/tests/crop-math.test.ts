// Ported from Packages/DexCore/Tests/MediaModelTests/CropMathTests.swift.
import { describe, expect, it } from 'vitest';
import { adjust, aspectRatio, boxAround, centred, clamped, minimumSide, placeIn, type CropHandle } from '@/lib/image/crop-math';

const image = { width: 1000, height: 800 };
const box = { x: 100, y: 100, width: 400, height: 300 };

describe('crop maths', () => {
  it('keeps a moved box inside', () => {
    expect(adjust(box, 'move', 5000, -5000, image, null)).toEqual({ x: 600, y: 0, width: 400, height: 300 });
  });

  it('resizes one side on edge drags', () => {
    expect(adjust(box, 'right', 50, 0, image, null)).toEqual({ x: 100, y: 100, width: 450, height: 300 });
    expect(adjust(box, 'top', 0, -40, image, null)).toEqual({ x: 100, y: 60, width: 400, height: 340 });
  });

  it('clamps drags to the image', () => {
    expect(adjust(box, 'topLeft', -500, -500, image, null)).toEqual({ x: 0, y: 0, width: 500, height: 400 });
  });

  it('never collapses the box', () => {
    const squashed = adjust(box, 'left', 10_000, 0, image, null);
    expect(squashed.width).toBe(minimumSide);
    expect(squashed.x + squashed.width).toBe(box.x + box.width);
  });

  it.each<CropHandle>(['topLeft', 'topRight', 'bottomLeft', 'bottomRight'])('keeps the ratio on %s drags', (handle) => {
    const result = adjust({ x: 200, y: 200, width: 200, height: 200 }, handle, 60, 13, image, 1);
    expect(result.width).toBe(result.height);
    expect(clamped(result, image)).toEqual(result);
  });

  it('shrinks a fixed ratio to fit', () => {
    const result = adjust(box, 'bottomRight', 2000, 0, image, 16 / 9);
    expect(clamped(result, image)).toEqual(result);
    expect(Math.abs(result.width / result.height - 16 / 9)).toBeLessThan(0.01);
  });

  it('centres the largest fit for a preset', () => {
    expect(centred(1, image)).toEqual({ x: 100, y: 0, width: 800, height: 800 });
    expect(centred(16 / 9, image)).toEqual({ x: 0, y: 118, width: 1000, height: 563 });
  });

  it('reads preset ratios', () => {
    expect(aspectRatio('9:16')).toBe(9 / 16);
    expect(aspectRatio('4:3')).toBe(4 / 3);
  });

  it('fits a whole image into a box without enlarging it', () => {
    // A 1000 × 800 image in a 500 × 500 box: scaled to 500 × 400, centred.
    expect(placeIn(image, { width: 500, height: 500 }, 'fit')).toEqual({ x: 0, y: 50, width: 500, height: 400 });
    // A bigger box leaves the image at its own size.
    expect(placeIn(image, { width: 2000, height: 2000 }, 'fit')).toEqual({ x: 500, y: 600, width: 1000, height: 800 });
  });

  it('covers a box when cropping to fill', () => {
    expect(placeIn(image, { width: 500, height: 500 }, 'crop')).toEqual({ x: -62, y: 0, width: 625, height: 500 });
  });

  it('extends to the smallest box of a ratio', () => {
    expect(boxAround(image, 1)).toEqual({ width: 1000, height: 1000 });
    expect(boxAround(image, 16 / 9)).toEqual({ width: 1422, height: 800 });
  });
});
