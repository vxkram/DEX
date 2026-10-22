import { browser, type Browser } from 'wxt/browser';
import { defineBackground } from 'wxt/utils/define-background';
import type { Job, JobResult } from '@/lib/downloads/convert-download';
import { baseName, kindOf, withExtension } from '@/lib/shared/names';
import { allSites, loadSettings } from '@/lib/downloads/settings';
import { cropCapture, screenshotName, type Area } from '@/lib/capture/screenshot';
import { putFile } from '@/lib/shared/file-store';

type DownloadItem = Browser.downloads.DownloadItem;

export default defineBackground(() => {
  /** Downloads waiting to finish before they're converted. */
  const pending = new Map<number, 'webp' | 'webm'>();
  /** Downloads DEX started: its blob URL, and the original it replaces. */
  const ours = new Map<number, { blobUrl: string; replaces?: number }>();

  const isOurs = (item: DownloadItem) =>
    ours.has(item.id)
    || item.byExtensionId === browser.runtime.id
    || item.url.startsWith(`blob:${location.origin}`)
    || item.url.startsWith(browser.runtime.getURL('/'));

  const notify = (message: string) =>
    browser.notifications.create({ type: 'basic', iconUrl: browser.runtime.getURL('/icons/128.png'), title: 'DEX', message });

  // MARK: Converting, in the offscreen page (Chrome) or right here (Firefox)

  let offscreenReady: Promise<void> | undefined;
  async function ensureOffscreen() {
    offscreenReady ??= (async () => {
      const existing = await browser.runtime.getContexts({ contextTypes: ['OFFSCREEN_DOCUMENT' as Browser.runtime.ContextType] });
      if (existing.length) return;
      await browser.offscreen.createDocument({
        url: 'offscreen.html',
        reasons: ['BLOBS' as Browser.offscreen.Reason],
        justification: 'Converts downloaded WebP and WebM files and hands them back as blob URLs.',
      });
    })().catch((error) => {
      offscreenReady = undefined;
      throw error;
    });
    return offscreenReady;
  }

  async function convert(job: Job): Promise<JobResult> {
    if (import.meta.env.FIREFOX) {
      const { runJob } = await import('@/lib/downloads/convert-download');
      return runJob(job);
    }
    await ensureOffscreen();
    return browser.runtime.sendMessage({ target: 'offscreen', type: 'convert', job });
  }

  function revoke(blobUrl: string) {
    if (import.meta.env.FIREFOX) URL.revokeObjectURL(blobUrl);
    else browser.runtime.sendMessage({ target: 'offscreen', type: 'revoke', url: blobUrl }).catch(() => {});
  }

  // MARK: Auto-convert downloads

  function consider(item: Pick<DownloadItem, 'id' | 'mime' | 'url' | 'finalUrl' | 'filename'>) {
    const kind = kindOf(item);
    if (kind) pending.set(item.id, kind);
  }

  browser.downloads.onCreated.addListener((item) => {
    if (isOurs(item)) return;
    consider(item);
    // Small files can finish before onChanged gets a chance to say so.
    if (item.state === 'complete' && pending.has(item.id)) process(item.id);
  });

  browser.downloads.onChanged.addListener(async (delta) => {
    const own = ours.get(delta.id);
    if (own && delta.state) {
      if (delta.state.current === 'complete' || delta.state.current === 'interrupted') {
        ours.delete(delta.id);
        setTimeout(() => revoke(own.blobUrl), 10_000);
      }
      // Only now, with the converted file safely saved, does the original go.
      if (delta.state.current === 'complete' && own.replaces != null) {
        await browser.downloads.removeFile(own.replaces).catch(() => {});
        await browser.downloads.erase({ id: own.replaces });
      }
      if (delta.state.current === 'interrupted') notify('The converted file couldn’t be saved. The original is kept.');
      return;
    }
    // Chrome may only learn the name after the download starts.
    if (delta.filename?.current && !pending.has(delta.id) && !ours.has(delta.id)) {
      const [item] = await browser.downloads.search({ id: delta.id });
      if (item && !isOurs(item)) consider(item);
    }
    if (delta.state?.current === 'complete' && pending.has(delta.id)) process(delta.id);
    if (delta.state?.current === 'interrupted') pending.delete(delta.id);
  });

  async function process(id: number) {
    const kind = pending.get(id)!;
    pending.delete(id);
    const settings = await loadSettings();
    const mode = settings[kind];
    if (!settings.auto || mode === 'off') return;
    if (!(await browser.permissions.contains(allSites))) return;
    const [item] = await browser.downloads.search({ id });
    if (!item || item.exists === false) return;

    const url = item.finalUrl || item.url;
    const name = baseName(item.filename) || baseName(url);
    if (url.startsWith('blob:')) {
      notify(`${name} was kept as is: DEX can’t read files the page made itself.`);
      return;
    }
    const result = await convert({ url, kind, mode });
    if (!result.ok) {
      notify(`${name} was kept as is: ${result.reason}.`);
      return;
    }
    const filename = withExtension(name, result.extension);
    const newId = await browser.downloads.download({ url: result.blobUrl, filename, conflictAction: 'uniquify' });
    ours.set(newId, { blobUrl: result.blobUrl, replaces: settings.keepOriginal ? undefined : id });
    notify(`${filename}\n${result.summary}`);
  }

  // MARK: Right-click

  browser.runtime.onInstalled.addListener(() => {
    browser.contextMenus.create({ id: 'dex-image', title: 'Edit with DEX…', contexts: ['image'] });
    browser.contextMenus.create({ id: 'dex-media', title: 'Save as MP4 with DEX…', contexts: ['video', 'audio'] });
    browser.contextMenus.create({ id: 'dex-frame', title: 'Save video frame with DEX', contexts: ['video'] });
    browser.contextMenus.create({ id: 'dex-area', title: 'Screenshot an area with DEX', contexts: ['page', 'selection', 'link', 'frame', 'video'] });
  });

  browser.contextMenus.onClicked.addListener((info, tab) => {
    if (info.menuItemId === 'dex-area' && tab) return startArea(tab);
    if (info.menuItemId === 'dex-frame' && tab) return saveFrame(tab, info.frameId ?? 0, info.srcUrl);
    const src = info.srcUrl;
    if (!src) return;
    if (info.menuItemId === 'dex-image') {
      const page = new URL(browser.runtime.getURL('/editor.html'));
      page.searchParams.set('src', src);
      if (tab?.id != null) page.searchParams.set('tab', String(tab.id));
      browser.tabs.create({ url: page.href, index: tab ? tab.index + 1 : undefined });
    } else if (info.menuItemId === 'dex-media') {
      // Asked straight away, while the click still counts as the user's.
      const origin = /^https?:/.test(src) ? `${new URL(src).origin}/*` : null;
      const granted = origin ? browser.permissions.request({ origins: [origin] }) : Promise.resolve(true);
      saveMedia(src, granted);
    }
  });

  async function saveMedia(src: string, granted: Promise<boolean>) {
    const name = baseName(src) || 'media';
    if (!(await granted)) return;
    if (src.startsWith('blob:')) {
      notify('This video is streamed in pieces by the page, so there’s no single file DEX can save.');
      return;
    }
    const settings = await loadSettings();
    notify(`Converting ${name}…`);
    const result = await convert({ url: src, kind: 'webm', mode: settings.webm === 'off' ? 'remux' : settings.webm });
    if (!result.ok) {
      notify(`${name} wasn’t converted: ${result.reason}.`);
      return;
    }
    const newId = await browser.downloads.download({ url: result.blobUrl, filename: withExtension(name, result.extension), saveAs: true });
    ours.set(newId, { blobUrl: result.blobUrl });
  }

  // The editor asks for a page's blob: image, which only that tab can read.
  browser.runtime.onMessage.addListener((message: { target?: string; type: string; tab?: number; url?: string }, _sender, sendResponse) => {
    if (message.target !== 'background' || message.type !== 'read-blob' || message.tab == null || !message.url) return;
    browser.scripting.executeScript({
      target: { tabId: message.tab },
      args: [message.url],
      func: async (url: string) => {
        const blob = await (await fetch(url)).blob();
        return await new Promise<string>((resolve) => {
          const reader = new FileReader();
          reader.onload = () => resolve(reader.result as string);
          reader.readAsDataURL(blob);
        });
      },
    }).then(([result]) => sendResponse({ dataUrl: result?.result }), (error) => sendResponse({ error: String(error) }));
    return true;
  });

  // MARK: Screenshots

  const protectedPage = 'Browsers don’t let extensions capture this page (their own pages and add-on stores are protected).';

  /** Opens an image in the editor, in a tab next to the one it came from. */
  async function openInEditor(blob: Blob, name: string, from?: Browser.tabs.Tab) {
    const page = new URL(browser.runtime.getURL('/editor.html'));
    page.searchParams.set('file', await putFile({ blob, name }));
    await browser.tabs.create({ url: page.href, index: from ? from.index + 1 : undefined });
  }

  async function startArea(tab: Browser.tabs.Tab) {
    try {
      await browser.scripting.executeScript({ target: { tabId: tab.id! }, files: ['/selector.js'] });
    } catch {
      notify(protectedPage);
    }
  }

  async function captureTab(tab: Browser.tabs.Tab, area: Area | null, viewport: { width: number; height: number }) {
    try {
      const dataUrl = await browser.tabs.captureVisibleTab(tab.windowId, { format: 'png' });
      await openInEditor(await cropCapture(dataUrl, area, viewport), `${screenshotName()}.png`, tab);
    } catch {
      notify(protectedPage);
    }
  }

  /** The video's own frame, at its full resolution, read inside the page. */
  async function saveFrame(tab: Browser.tabs.Tab, frameId: number, src?: string) {
    try {
      const [{ result }] = await browser.scripting.executeScript({
        target: { tabId: tab.id!, frameIds: [frameId] },
        args: [src ?? ''],
        func: (src: string) => {
          const videos = [...document.querySelectorAll('video')];
          const video = videos.find((v) => src && (v.currentSrc === src || v.src === src))
            ?? videos.filter((v) => v.videoWidth > 0).sort((a, b) => b.clientWidth * b.clientHeight - a.clientWidth * a.clientHeight)[0];
          if (!video || !video.videoWidth) return { error: 'There’s no video frame to save yet.' };
          const canvas = document.createElement('canvas');
          canvas.width = video.videoWidth;
          canvas.height = video.videoHeight;
          canvas.getContext('2d')!.drawImage(video, 0, 0);
          try {
            return { dataUrl: canvas.toDataURL('image/png'), title: document.title, time: video.currentTime };
          } catch {
            return { error: 'This site protects its video, so DEX can’t copy the frame. Use “Screenshot an area” instead.' };
          }
        },
      });
      const reply = result as { dataUrl?: string; title?: string; time?: number; error?: string } | undefined;
      if (!reply?.dataUrl) return notify(reply?.error ?? protectedPage);
      const t = Math.floor(reply.time ?? 0);
      const stamp = `${Math.floor(t / 60)}.${String(t % 60).padStart(2, '0')}`;
      const title = (reply.title ?? 'Video').replace(/ - YouTube$/, '').replace(/[\\/:*?"<>|]+/g, '-').slice(0, 80).trim() || 'Video';
      await openInEditor(await (await fetch(reply.dataUrl)).blob(), `${title} ${stamp}.png`, tab);
    } catch {
      notify(protectedPage);
    }
  }

  /** A frame from the YouTube player bar: straight to Downloads, or into the editor. */
  async function saveOrEditFrame(dataUrl: string, name: string, action: 'save' | 'edit', tab?: Browser.tabs.Tab) {
    const blob = await (await fetch(dataUrl)).blob();
    if (action === 'edit') return openInEditor(blob, name, tab);
    // Firefox won't download data: URLs; Chrome's service worker can't make blob: ones.
    const url = import.meta.env.FIREFOX ? URL.createObjectURL(blob) : dataUrl;
    const id = await browser.downloads.download({ url, filename: name, conflictAction: 'uniquify' });
    if (import.meta.env.FIREFOX) ours.set(id, { blobUrl: url });
    notify(`Saved ${name} to Downloads`);
  }

  browser.commands.onCommand.addListener(async (command) => {
    if (command !== 'screenshot-area') return;
    const [tab] = await browser.tabs.query({ active: true, currentWindow: true });
    if (tab) startArea(tab);
  });

  browser.runtime.onMessage.addListener((message: {
    target?: string; type: string; mode?: 'area' | 'page'; rect?: Area | null; viewport?: { width: number; height: number };
    action?: 'save' | 'edit'; dataUrl?: string; name?: string;
  }, sender) => {
    if (message.target !== 'background') return;
    if (message.type === 'frame' && message.dataUrl && message.name) {
      saveOrEditFrame(message.dataUrl, message.name, message.action ?? 'save', sender.tab);
    } else if (message.type === 'frame-failed') {
      notify('This video is protected, so DEX can’t copy the frame. Use “Select Area” instead.');
    } else if (message.type === 'area-selected' && sender.tab) {
      captureTab(sender.tab, message.rect ?? null, message.viewport!);
    } else if (message.type === 'screenshot') {
      // From the popup, which closes as soon as it asks.
      browser.tabs.query({ active: true, currentWindow: true }).then(([tab]) => {
        if (!tab) return;
        if (message.mode === 'area') startArea(tab);
        // A whole-page shot isn't cropped, so the viewport size doesn't matter.
        else captureTab(tab, null, { width: 1, height: 1 });
      });
    }
  });
});
