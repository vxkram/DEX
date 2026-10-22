import preact from '@preact/preset-vite';
import { defineConfig } from 'wxt';

export default defineConfig({
  srcDir: 'src',
  manifestVersion: 3,
  // Store screenshots and listing text aren't part of the add-on's source.
  zip: { excludeSources: ['store/**'] },
  vite: () => ({ plugins: [preact()] }),
  manifest: ({ browser }) => ({
    name: 'DEX Mini',
    description: 'Crop, convert and resize images, and turn WebP and WebM downloads into files that open anywhere. Lossless whenever possible.',
    permissions: [
      'downloads',
      'contextMenus',
      'storage',
      'notifications',
      'activeTab',
      'scripting',
      // Chrome's service worker can't decode media; an offscreen page does it.
      ...(browser === 'firefox' ? [] : ['offscreen']),
    ],
    // Asked for when the user turns on auto-convert or opens a remote image,
    // so installing asks for little.
    optional_host_permissions: ['<all_urls>'],
    action: { default_title: 'DEX' },
    ...(browser === 'firefox' && {
      browser_specific_settings: {
        gecko: {
          id: 'dex-mini@vxkram.github.io',
          strict_min_version: '140.0',
          data_collection_permissions: { required: ['none'] },
        },
        gecko_android: { strict_min_version: '142.0' },
      },
    }),
  }),
});
