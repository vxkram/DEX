// The user's choices for auto-converting downloads, kept in storage.sync.

import { browser } from 'wxt/browser';
import type { WebmMode } from '../media/media-convert';

export interface Settings {
  /** Master switch; needs host access, asked for when it's turned on. */
  auto: boolean;
  webp: 'png' | 'jpeg' | 'off';
  webm: WebmMode | 'off';
  keepOriginal: boolean;
}

export const defaultSettings: Settings = { auto: false, webp: 'png', webm: 'remux', keepOriginal: false };

export const allSites = { origins: ['<all_urls>'] };

export async function loadSettings(): Promise<Settings> {
  const stored = await browser.storage.sync.get('settings');
  return { ...defaultSettings, ...(stored.settings as Partial<Settings> | undefined) };
}

export async function saveSettings(settings: Settings) {
  await browser.storage.sync.set({ settings });
}
