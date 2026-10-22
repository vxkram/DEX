// Fetches a finished download again and converts it. Runs where there's a
// DOM: Chrome's offscreen document, Firefox's background page.

import { detectCapabilities, exportImage, load } from '../image/image-codec';
import { convertWebm, type WebmMode } from '../media/media-convert';
import { fileExtension, noGeometry, plan, verdictLabel } from '../image/planner';

export interface Job {
  url: string;
  kind: 'webp' | 'webm';
  /** WebP target, or WebM mode. */
  mode: 'png' | 'jpeg' | WebmMode;
}

export type JobResult =
  | { ok: true; blobUrl: string; extension: string; summary: string }
  | { ok: false; reason: string };

export const sizeLimit = { webp: 100 * 1024 * 1024, webm: 1024 * 1024 * 1024 };

export async function runJob(job: Job): Promise<JobResult> {
  try {
    const response = await fetch(job.url, { credentials: 'include' });
    if (!response.ok) return { ok: false, reason: `the site refused to send it again (HTTP ${response.status})` };
    const blob = await response.blob();
    if (blob.size > sizeLimit[job.kind]) return { ok: false, reason: 'it’s too large to convert in the browser' };

    if (job.kind === 'webm') {
      const result = await convertWebm(blob, job.mode as WebmMode);
      return { ok: true, blobUrl: URL.createObjectURL(result.blob), extension: result.extension, summary: result.summary };
    }

    const loaded = await load(blob);
    if (loaded.source.format !== 'webp') return { ok: false, reason: 'it isn’t really a WebP' };
    if (loaded.source.frames > 1) {
      return { ok: false, reason: `it’s animated (${loaded.source.frames} frames), and converting would keep only the first` };
    }
    const target = job.mode as 'png' | 'jpeg';
    const result = plan(loaded.source, { target, quality: 'max', geometry: noGeometry }, await detectCapabilities());
    const { blob: output } = await exportImage(loaded, result);
    loaded.bitmap.close();
    const firstLoss = result.notes.find((n) => n.isLoss);
    const summary = verdictLabel[result.verdict] + (firstLoss ? ` · ${firstLoss.text}` : '');
    return { ok: true, blobUrl: URL.createObjectURL(output), extension: fileExtension[target], summary };
  } catch (error) {
    return { ok: false, reason: error instanceof Error ? error.message.replace(/\.$/, '') : String(error) };
  }
}
