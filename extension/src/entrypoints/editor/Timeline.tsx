import { useEffect, useRef } from 'preact/hooks';
import { Icon } from '@/components/Icon';
import type { Animation } from '@/lib/image/animation';

interface Props {
  animation: Animation;
  current: number;
  range: { start: number; end: number };
  playing: boolean;
  /** Trim handles only matter when saving a GIF. */
  trimming: boolean;
  onSeek: (frame: number) => void;
  onRange: (range: { start: number; end: number }) => void;
  onPlay: (playing: boolean) => void;
}

const thumbHeight = 40;

/** Frames of an animation: a filmstrip with a playhead and trim handles. */
export function Timeline({ animation, current, range, playing, trimming, onSeek, onRange, onPlay }: Props) {
  const { frames, delays } = animation;
  const count = frames.length;
  const strip = useRef<HTMLCanvasElement>(null);
  const track = useRef<HTMLDivElement>(null);

  // A filmstrip of evenly spaced frames, drawn once.
  useEffect(() => {
    const el = strip.current;
    if (!el) return;
    const first = frames[0];
    const thumbWidth = Math.max(8, Math.round((first.width / first.height) * thumbHeight));
    // As many thumbnails as fit the strip at their own shape.
    const room = track.current?.clientWidth ?? 600;
    const shown = Math.max(1, Math.min(count, Math.round(room / ((first.width / first.height) * 44))));
    el.width = thumbWidth * shown;
    el.height = thumbHeight;
    const ctx = el.getContext('2d')!;
    for (let i = 0; i < shown; i++) {
      const frame = frames[Math.round((i / Math.max(1, shown - 1)) * (count - 1))];
      ctx.drawImage(frame, i * thumbWidth, 0, thumbWidth, thumbHeight);
    }
  }, [animation]);

  const at = (frame: number) => `${(count > 1 ? frame / (count - 1) : 0) * 100}%`;

  const frameAt = (clientX: number) => {
    const rect = track.current!.getBoundingClientRect();
    return Math.round(Math.min(Math.max((clientX - rect.left) / rect.width, 0), 1) * (count - 1));
  };

  const drag = (what: 'seek' | 'start' | 'end') => (event: PointerEvent) => {
    event.preventDefault();
    event.stopPropagation();
    const target = event.currentTarget as HTMLElement;
    target.setPointerCapture(event.pointerId);
    const apply = (e: PointerEvent) => {
      const f = frameAt(e.clientX);
      if (what === 'seek') onSeek(Math.min(Math.max(f, range.start), range.end));
      else if (what === 'start') onRange({ start: Math.min(f, range.end), end: range.end });
      else onRange({ start: range.start, end: Math.max(f, range.start) });
    };
    apply(event);
    const end = () => {
      target.removeEventListener('pointermove', apply);
      target.removeEventListener('pointerup', end);
    };
    target.addEventListener('pointermove', apply);
    target.addEventListener('pointerup', end);
  };

  const seconds = (from: number, to: number) => delays.slice(from, to + 1).reduce((a, b) => a + b, 0) / 1000;

  return (
    <div class="timeline glass" aria-label="Timeline">
      <button type="button" class="button play" aria-label={playing ? 'Pause' : 'Play'} onClick={() => onPlay(!playing)}>
        <Icon name={playing ? 'pause' : 'play'} />
      </button>
      <div class="track" ref={track} onPointerDown={drag('seek')}>
        <canvas ref={strip} class="strip" />
        {trimming && <div class="trimmed" style={{ left: 0, width: at(range.start) }} />}
        {trimming && <div class="trimmed" style={{ left: at(range.end), right: 0 }} />}
        <div class="playhead" style={{ left: at(current) }} />
        {trimming && (
          <>
            <div class="trim start" style={{ left: at(range.start) }} onPointerDown={drag('start')} title="Drag to set where the GIF starts" />
            <div class="trim end" style={{ left: at(range.end) }} onPointerDown={drag('end')} title="Drag to set where the GIF ends" />
          </>
        )}
      </div>
      <div class="counter technical">
        <span>{current + 1} / {count}</span>
        <span class="caption">
          {trimming && (range.start > 0 || range.end < count - 1)
            ? `${range.start + 1}–${range.end + 1} · ${seconds(range.start, range.end).toFixed(1)} s`
            : `${seconds(0, count - 1).toFixed(1)} s`}
        </span>
      </div>
    </div>
  );
}
