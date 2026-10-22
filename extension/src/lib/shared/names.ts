/** The last path component, from a URL or a full download path. */
export function baseName(pathOrUrl: string): string {
  let path = pathOrUrl;
  try {
    if (/^[a-z]+:\/\//i.test(path)) path = decodeURIComponent(new URL(path).pathname);
  } catch {
    // Not a URL after all.
  }
  return path.split(/[\\/]/).filter(Boolean).pop() ?? '';
}

/** `photo.webp` → `photo.png`; adds the extension when there is none. */
export function withExtension(name: string, extension: string): string {
  const stem = name.replace(/\.[^.]+$/, '') || 'image';
  return `${stem}.${extension}`;
}

export function kindOf(item: { mime?: string; url?: string; finalUrl?: string; filename?: string }): 'webp' | 'webm' | null {
  const mime = (item.mime ?? '').toLowerCase();
  if (mime === 'image/webp') return 'webp';
  if (mime === 'video/webm' || mime === 'audio/webm') return 'webm';
  for (const where of [item.filename, item.finalUrl, item.url]) {
    if (!where || where.startsWith('data:')) continue;
    const name = baseName(where).toLowerCase();
    if (name.endsWith('.webp')) return 'webp';
    if (name.endsWith('.webm')) return 'webm';
  }
  return null;
}

export function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(0)} KB`;
  return `${(bytes / 1024 / 1024).toFixed(bytes < 10 * 1024 * 1024 ? 1 : 0)} MB`;
}
