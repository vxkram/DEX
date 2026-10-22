// Injected into a page for "Select area": dims it, lets the user drag a box,
// then takes itself away and tells the background where the box was, so
// the screenshot doesn't include any of this.

import { browser } from 'wxt/browser';
import { defineUnlistedScript } from 'wxt/utils/define-unlisted-script';

export default defineUnlistedScript(() => {
  const marker = '__dexSelector';
  const w = window as unknown as Record<string, boolean>;
  if (w[marker]) return;
  w[marker] = true;

  const host = document.createElement('div');
  host.style.cssText = 'position:fixed;inset:0;z-index:2147483647;';
  const root = host.attachShadow({ mode: 'closed' });
  root.innerHTML = `
    <style>
      :host { all: initial; }
      .layer { position: fixed; inset: 0; cursor: crosshair; user-select: none; font: 13px/1.3 system-ui, -apple-system, sans-serif; }
      .shade { position: fixed; inset: 0; background: rgba(0, 0, 0, 0.45); }
      .box { position: fixed; display: none; outline: 2px solid #f55c26; box-shadow: 0 0 0 100vmax rgba(0, 0, 0, 0.45); }
      .size { position: absolute; right: 0; bottom: -28px; padding: 3px 8px; border-radius: 6px; background: #f55c26; color: #fff;
              font: 600 12px ui-monospace, Menlo, monospace; white-space: nowrap; }
      .hint { position: fixed; top: 16px; left: 50%; translate: -50% 0; padding: 8px 14px; border-radius: 12px; color: rgba(255,255,255,.92);
              background: rgba(20, 20, 22, 0.78); backdrop-filter: blur(16px); box-shadow: 0 8px 30px rgba(0,0,0,.4); white-space: nowrap; }
      .hint b { font: 600 12px ui-monospace, Menlo, monospace; letter-spacing: 4px; margin-right: 10px; }
      kbd { font: 11px ui-monospace, Menlo, monospace; padding: 1px 5px; border-radius: 4px; background: rgba(255,255,255,.14); }
    </style>
    <div class="layer">
      <div class="shade"></div>
      <div class="box"><span class="size"></span></div>
      <div class="hint"><b>DEX</b>Drag to select · <kbd>Enter</kbd> whole page · <kbd>Esc</kbd> cancel</div>
    </div>`;
  const layer = root.querySelector<HTMLElement>('.layer')!;
  const shade = root.querySelector<HTMLElement>('.shade')!;
  const box = root.querySelector<HTMLElement>('.box')!;
  const size = root.querySelector<HTMLElement>('.size')!;
  const hint = root.querySelector<HTMLElement>('.hint')!;
  document.documentElement.append(host);

  let start: { x: number; y: number } | null = null;
  let rect = { x: 0, y: 0, width: 0, height: 0 };

  const finish = async (area: typeof rect | 'page' | null) => {
    removeEventListener('keydown', key, true);
    host.remove();
    delete w[marker];
    if (!area) return browser.runtime.sendMessage({ target: 'background', type: 'area-cancelled' });
    // Let the page repaint without the overlay before it's captured.
    await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
    await new Promise((r) => setTimeout(r, 60));
    browser.runtime.sendMessage({
      target: 'background',
      type: 'area-selected',
      rect: area === 'page' ? null : area,
      viewport: { width: innerWidth, height: innerHeight },
      title: document.title,
    });
  };

  const key = (event: KeyboardEvent) => {
    if (event.key === 'Escape') { event.preventDefault(); event.stopPropagation(); finish(null); }
    if (event.key === 'Enter') { event.preventDefault(); event.stopPropagation(); finish('page'); }
  };
  addEventListener('keydown', key, true);

  layer.addEventListener('pointerdown', (event) => {
    event.preventDefault();
    layer.setPointerCapture(event.pointerId);
    start = { x: event.clientX, y: event.clientY };
    shade.style.display = 'none';
    hint.style.display = 'none';
  });
  layer.addEventListener('pointermove', (event) => {
    if (!start) return;
    const x = Math.max(0, Math.min(start.x, event.clientX)), y = Math.max(0, Math.min(start.y, event.clientY));
    const width = Math.min(innerWidth, Math.max(start.x, event.clientX)) - x;
    const height = Math.min(innerHeight, Math.max(start.y, event.clientY)) - y;
    rect = { x, y, width, height };
    Object.assign(box.style, { display: 'block', left: `${x}px`, top: `${y}px`, width: `${width}px`, height: `${height}px` });
    const scale = devicePixelRatio;
    size.textContent = `${Math.round(width * scale)} × ${Math.round(height * scale)}`;
  });
  layer.addEventListener('pointerup', () => {
    if (!start) return;
    start = null;
    // A click without a drag means nothing yet: start over.
    if (rect.width < 4 || rect.height < 4) {
      box.style.display = 'none';
      shade.style.display = '';
      hint.style.display = '';
      return;
    }
    finish(rect);
  });
});
