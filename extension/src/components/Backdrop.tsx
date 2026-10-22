import { useEffect, useRef } from 'preact/hooks';

/**
 * The textured, ember-lit backdrop behind the glass. The glow follows the
 * pointer and, with `parallax`, the texture drifts against it.
 */
export function Backdrop({ parallax = false }: { parallax?: boolean }) {
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (matchMedia('(prefers-reduced-motion: reduce)').matches) return;
    const move = (event: PointerEvent) => {
      const el = ref.current;
      if (!el) return;
      const x = event.clientX / innerWidth, y = event.clientY / innerHeight;
      el.style.setProperty('--gx', `${x * 100}%`);
      el.style.setProperty('--gy', `${y * 100}%`);
      if (parallax) {
        el.style.setProperty('--px', `${(0.5 - x) * 18}px`);
        el.style.setProperty('--py', `${(y - 0.5) * 12}px`);
      }
    };
    addEventListener('pointermove', move);
    return () => removeEventListener('pointermove', move);
  }, [parallax]);
  return (
    <div class="backdrop" ref={ref} aria-hidden="true">
      <div class="texture" />
      <div class="glow" />
      <div class="shade" />
    </div>
  );
}
