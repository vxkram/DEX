// Chrome only: the background service worker can't make blob URLs or run
// WebCodecs, so conversions happen in this hidden page.

import { browser } from 'wxt/browser';
import { runJob, type Job } from '@/lib/downloads/convert-download';

browser.runtime.onMessage.addListener((message: { target?: string; type: string; job?: Job; url?: string }, _sender, sendResponse) => {
  if (message.target !== 'offscreen') return;
  if (message.type === 'convert' && message.job) {
    runJob(message.job).then(sendResponse);
    return true;
  }
  if (message.type === 'revoke' && message.url) URL.revokeObjectURL(message.url);
});
