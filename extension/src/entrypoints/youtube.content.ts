// On YouTube: when a video is paused, a small DEX bar on the player saves
// the frame as a PNG at the video's own resolution, or opens it in DEX.

import { browser } from 'wxt/browser';
import { defineContentScript } from 'wxt/utils/define-content-script';

export default defineContentScript({
  matches: ['*://www.youtube.com/*'],
  main() {
    let bar: HTMLElement | null = null;

    const hide = () => {
      bar?.remove();
      bar = null;
    };

    const show = (video: HTMLVideoElement) => {
      hide();
      const player = video.closest<HTMLElement>('.html5-video-player') ?? video.parentElement;
      if (!player || !video.videoWidth) return;
      const host = document.createElement('div');
      host.style.cssText = 'position:absolute;top:12px;left:12px;z-index:2147483646;';
      const root = host.attachShadow({ mode: 'closed' });
      root.innerHTML = `
        <style>
          .bar { display: flex; align-items: center; gap: 4px; padding: 4px; border-radius: 12px;
                 background: rgba(20, 20, 22, 0.72); backdrop-filter: blur(16px) saturate(1.6);
                 box-shadow: 0 8px 30px rgba(0, 0, 0, 0.45), inset 0 1px 0 rgba(255, 255, 255, 0.12);
                 font: 600 13px/1 system-ui, -apple-system, sans-serif; color: rgba(255, 255, 255, 0.92); }
          .mark { padding: 0 8px 0 6px; font: 600 11px ui-monospace, Menlo, monospace; letter-spacing: 4px; }
          button { display: inline-flex; align-items: center; gap: 6px; height: 30px; padding: 0 12px; border: 0;
                   border-radius: 9px; font: inherit; color: inherit; background: rgba(255, 255, 255, 0.1); cursor: pointer; }
          button:hover { background: rgba(255, 255, 255, 0.18); }
          button.primary { background: #f55c26; color: #fff; }
          button.primary:hover { background: #ff6a33; }
          svg { width: 15px; height: 15px; fill: none; stroke: currentColor; stroke-width: 2; stroke-linecap: round; stroke-linejoin: round; }
          .size { padding: 0 6px; font: 500 11px ui-monospace, Menlo, monospace; color: rgba(255, 255, 255, 0.6); }
        </style>
        <div class="bar">
          <span class="mark">DEX</span>
          <button class="primary" data-action="save" title="Save this frame as a PNG">
            <svg viewBox="0 0 24 24"><path d="M12 3v12 M7 10l5 5 5-5 M4 20h16"/></svg>Save frame
          </button>
          <button data-action="edit" title="Open this frame in DEX to crop or convert">Edit</button>
          <span class="size">${video.videoWidth} × ${video.videoHeight}</span>
        </div>`;
      // Clicks on the bar mustn't reach the player (which would play/pause).
      for (const type of ['click', 'mousedown', 'mouseup', 'pointerdown', 'dblclick']) {
        root.addEventListener(type, (e) => e.stopPropagation());
      }
      root.querySelectorAll<HTMLButtonElement>('button').forEach((button) =>
        button.addEventListener('click', () => grab(video, button.dataset.action as 'save' | 'edit')));
      player.append(host);
      bar = host;
    };

    const grab = (video: HTMLVideoElement, action: 'save' | 'edit') => {
      const canvas = document.createElement('canvas');
      canvas.width = video.videoWidth;
      canvas.height = video.videoHeight;
      canvas.getContext('2d')!.drawImage(video, 0, 0);
      let dataUrl: string;
      try {
        dataUrl = canvas.toDataURL('image/png');
      } catch {
        return browser.runtime.sendMessage({ target: 'background', type: 'frame-failed' });
      }
      const t = Math.floor(video.currentTime);
      const stamp = `${Math.floor(t / 60)}.${String(t % 60).padStart(2, '0')}`;
      const title = document.title.replace(/^\(\d+\)\s*/, '').replace(/ - YouTube$/, '').replace(/[\\/:*?"<>|]+/g, '-').slice(0, 80).trim() || 'YouTube';
      browser.runtime.sendMessage({ target: 'background', type: 'frame', action, dataUrl, name: `${title} ${stamp}.png` });
    };

    const isMain = (el: EventTarget | null): el is HTMLVideoElement =>
      el instanceof HTMLVideoElement && el.classList.contains('html5-main-video');

    // Media events don't bubble, but they can be caught on the way down.
    document.addEventListener('pause', (e) => { if (isMain(e.target) && !e.target.ended) show(e.target); }, true);
    for (const type of ['play', 'playing', 'seeking', 'emptied']) {
      document.addEventListener(type, (e) => { if (isMain(e.target)) hide(); }, true);
    }
    // YouTube changes pages without reloading.
    document.addEventListener('yt-navigate-start', hide);
  },
});
