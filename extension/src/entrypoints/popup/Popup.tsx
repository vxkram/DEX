import { useEffect, useRef, useState } from 'preact/hooks';
import { browser } from 'wxt/browser';
import { Backdrop } from '@/components/Backdrop';
import { Segmented, Toggle } from '@/components/Controls';
import { Icon } from '@/components/Icon';
import { canReencode } from '@/lib/media/encoders';
import { putFile } from '@/lib/shared/file-store';
import { allSites, defaultSettings, loadSettings, saveSettings, type Settings } from '@/lib/downloads/settings';

async function openEditor(file?: File) {
  const page = new URL(browser.runtime.getURL('/editor.html'));
  if (file) page.searchParams.set('file', await putFile({ blob: file, name: file.name }));
  await browser.tabs.create({ url: page.href });
  window.close();
}

/** The background takes the shot: the popup closes before the page can be captured. */
function screenshot(mode: 'area' | 'page' | 'frame') {
  browser.runtime.sendMessage({ target: 'background', type: 'screenshot', mode }).catch(() => {});
  setTimeout(() => window.close(), 50);
}

/** Looks for a playing or paused video in the current tab, iframes included. */
async function findVideo(): Promise<{ width: number; height: number } | null> {
  try {
    const [tab] = await browser.tabs.query({ active: true, currentWindow: true });
    if (tab?.id == null) return null;
    const results = await browser.scripting.executeScript({
      target: { tabId: tab.id, allFrames: true },
      func: () => [...document.querySelectorAll('video')]
        .filter((v) => v.videoWidth > 0)
        .map((v) => ({ width: v.videoWidth, height: v.videoHeight, area: v.clientWidth * v.clientHeight })),
    });
    const all = results.flatMap((r) => (r.result as { width: number; height: number; area: number }[] | undefined) ?? []);
    const best = all.sort((a, b) => b.area - a.area)[0];
    return best ? { width: best.width, height: best.height } : null;
  } catch {
    // Pages the browser protects can't be looked into.
    return null;
  }
}

const webpHelp = { png: 'PNG: lossless', jpeg: 'JPEG: lossy, quality 95', off: '' };
const webmHelp = { remux: 'MP4: streams copied, no re-encode', h264: 'H.264: re-encoded, plays everywhere', off: '' };

export function Popup() {
  const [settings, setSettings] = useState<Settings>(defaultSettings);
  const [canH264, setCanH264] = useState(true);
  /** The biggest video on the page, if it has a frame to save. */
  const [video, setVideo] = useState<{ width: number; height: number } | null>(null);
  const picker = useRef<HTMLInputElement>(null);

  useEffect(() => {
    // Auto-convert is only on while DEX may read the files again.
    Promise.all([loadSettings(), browser.permissions.contains(allSites)])
      .then(([s, granted]) => setSettings({ ...s, auto: s.auto && granted }));
    canReencode().then(setCanH264);
    findVideo().then(setVideo);
  }, []);

  const update = (change: Partial<Settings>) => {
    const next = { ...settings, ...change };
    setSettings(next);
    saveSettings(next);
  };

  const setAuto = (on: boolean) => {
    if (!on) return update({ auto: false });
    // Saved first: Firefox closes the popup when its permission prompt opens,
    // so code after the prompt may never run. The background checks the
    // permission again before every conversion.
    update({ auto: true });
    // Requested inside the click: browsers only ask while the user acts.
    browser.permissions.request(allSites).then((granted) => !granted && update({ auto: false }));
  };

  // Firefox closes the popup when a file picker opens, so there the editor
  // tab asks for the file instead.
  const chooseImage = () => (import.meta.env.FIREFOX ? openEditor() : picker.current?.click());

  const help = [settings.webp !== 'off' && webpHelp[settings.webp], settings.webm !== 'off' && webmHelp[settings.webm]].filter(Boolean);

  return (
    <div class="popup">
      <Backdrop />
      <header>
        <span class="wordmark">DEX</span>
        <button type="button" class="button small" onClick={() => openEditor()}>Open DEX</button>
      </header>

      <input ref={picker} type="file" accept="image/*" hidden
        onChange={(e) => { const f = e.currentTarget.files?.[0]; if (f) openEditor(f); }} />
      <button type="button" class="button primary choose" onClick={chooseImage}>
        <Icon name="photo" /> Choose Image…
      </button>

      {video && (
        <button type="button" class="button frame" onClick={() => screenshot('frame')}>
          <Icon name="download" /> Save Video Frame <span class="technical">{video.width} × {video.height}</span>
        </button>
      )}
      <div class="shots">
        <button type="button" class="button" onClick={() => screenshot('area')} title="Alt+Shift+S on any page">
          <Icon name="crop" /> Select Area
        </button>
        <button type="button" class="button" onClick={() => screenshot('page')}>
          <Icon name="photo" /> Visible Page
        </button>
      </div>

      <section class="settings glass" data-off={!settings.auto}>
        <Toggle checked={settings.auto} onChange={setAuto}>Convert downloads</Toggle>
        <div class="row">
          <span>WebP</span>
          <Segmented label="WebP images" value={settings.webp} onChange={(webp) => update({ webp })}
            options={[{ value: 'png', title: 'PNG' }, { value: 'jpeg', title: 'JPEG' }, { value: 'off', title: 'Off' }]} />
        </div>
        <div class="row">
          <span>WebM</span>
          <Segmented label="WebM video and audio" value={settings.webm} onChange={(webm) => update({ webm })}
            options={[
              { value: 'remux', title: 'MP4' },
              { value: 'h264', title: 'H.264', disabled: !canH264, help: canH264 ? undefined : 'This browser can’t encode H.264 and AAC.' },
              { value: 'off', title: 'Off' },
            ]} />
        </div>
        {help.length > 0 && <p class="caption">{help.join(' · ')}</p>}
        <Toggle checked={settings.keepOriginal} onChange={(keepOriginal) => update({ keepOriginal })}>Keep originals</Toggle>
      </section>
    </div>
  );
}
