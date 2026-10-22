import { useRef } from 'preact/hooks';
import { adjust, edgeHandles, isCorner, type CropHandle, type Rect, type Size } from '@/lib/image/crop-math';

/** The crop box over the stage, in image pixels, drawn as percentages. */
export function CropOverlay({ crop, size, ratio, onChange }: {
  crop: Rect;
  size: Size;
  ratio: number | null;
  onChange: (rect: Rect) => void;
}) {
  const box = useRef<HTMLDivElement>(null);

  const startDrag = (handle: CropHandle) => (event: PointerEvent) => {
    event.preventDefault();
    event.stopPropagation();
    const frame = box.current!.parentElement!.getBoundingClientRect();
    const scale = size.width / frame.width;
    const start = crop, x0 = event.clientX, y0 = event.clientY;
    const target = event.currentTarget as HTMLElement;
    target.setPointerCapture(event.pointerId);
    const move = (e: PointerEvent) =>
      onChange(adjust(start, handle, (e.clientX - x0) * scale, (e.clientY - y0) * scale, size, ratio));
    const end = () => {
      target.removeEventListener('pointermove', move);
      target.removeEventListener('pointerup', end);
      target.removeEventListener('pointercancel', end);
    };
    target.addEventListener('pointermove', move);
    target.addEventListener('pointerup', end);
    target.addEventListener('pointercancel', end);
  };

  const pct = (v: number, of: number) => `${(v / of) * 100}%`;
  // With a fixed ratio only the corners resize, as on the Mac.
  const handles = ratio == null ? edgeHandles : edgeHandles.filter(isCorner);

  const place = { left: pct(crop.x, size.width), top: pct(crop.y, size.height), width: pct(crop.width, size.width), height: pct(crop.height, size.height) };

  return (
    <>
      {/* Dims the image outside the box, clipped to the image. */}
      <div class="crop-shade" aria-hidden="true"><div style={place} /></div>
      <div ref={box} class="crop-box" onPointerDown={startDrag('move')} style={place}>
        <div class="thirds" />
        {handles.map((h) => <div key={h} class={`handle ${h}`} onPointerDown={startDrag(h)} />)}
      </div>
    </>
  );
}
