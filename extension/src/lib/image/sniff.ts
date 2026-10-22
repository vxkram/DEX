// Reads what a file is from its bytes, without decoding pixels. Browsers
// decode everything to 8-bit sRGB RGBA, so these facts are what the planner
// needs to say honestly what a conversion will cost.

export type SourceFormat = 'png' | 'jpeg' | 'webp' | 'gif' | 'avif' | 'bmp' | 'other';

export interface SourceFacts {
  format: SourceFormat;
  /** The file can hold transparency (it may still be fully opaque). */
  hasAlpha: boolean;
  frames: number;
  /** Highest bits per component, when the header says. */
  bitDepth: number | null;
  /** The coded data is lossless (PNG, lossless WebP, BMP). */
  losslessCoded: boolean;
  /** An embedded ICC profile that isn't sRGB. */
  wideColourProfile: boolean;
}

const ascii = (b: Uint8Array, at: number, n: number) => String.fromCharCode(...b.subarray(at, at + n));
const u32be = (b: Uint8Array, at: number) => ((b[at] << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3]) >>> 0;
const u32le = (b: Uint8Array, at: number) => (b[at] | (b[at + 1] << 8) | (b[at + 2] << 16) | (b[at + 3] << 24)) >>> 0;

export function sniffFormat(b: Uint8Array): SourceFormat {
  if (b.length >= 8 && b[0] === 0x89 && ascii(b, 1, 3) === 'PNG') return 'png';
  if (b.length >= 3 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return 'jpeg';
  if (b.length >= 12 && ascii(b, 0, 4) === 'RIFF' && ascii(b, 8, 4) === 'WEBP') return 'webp';
  if (b.length >= 6 && ascii(b, 0, 4) === 'GIF8') return 'gif';
  if (b.length >= 12 && ascii(b, 4, 4) === 'ftyp' && /avi[fs]/.test(ascii(b, 8, 4))) return 'avif';
  if (b.length >= 2 && ascii(b, 0, 2) === 'BM') return 'bmp';
  return 'other';
}

/** An ICC profile counts as sRGB when its description says so. */
function isSRGBProfile(profile: Uint8Array): boolean {
  const text = String.fromCharCode(...profile.subarray(0, Math.min(profile.length, 4096)));
  return /sRGB|IEC61966-2[.-]1/.test(text) || /s\0R\0G\0B/.test(text);
}

function sniffPNG(b: Uint8Array, facts: SourceFacts) {
  facts.losslessCoded = true;
  let at = 8;
  while (at + 8 <= b.length) {
    const length = u32be(b, at);
    const type = ascii(b, at + 4, 4);
    const data = at + 8;
    if (type === 'IHDR') {
      facts.bitDepth = b[data + 8];
      const colourType = b[data + 9];
      facts.hasAlpha = colourType === 4 || colourType === 6;
    } else if (type === 'tRNS') {
      facts.hasAlpha = true;
    } else if (type === 'acTL') {
      facts.frames = Math.max(1, u32be(b, data));
    } else if (type === 'iCCP') {
      // Name, NUL, method, then the compressed profile: judge by the name.
      const name = ascii(b, data, Math.min(79, length)).split('\0')[0];
      facts.wideColourProfile = !/sRGB/i.test(name);
    } else if (type === 'IDAT' || type === 'IEND') {
      break;
    }
    at = data + length + 4;
  }
}

function sniffJPEG(b: Uint8Array, facts: SourceFacts) {
  facts.bitDepth = 8;
  let at = 2;
  const icc: Uint8Array[] = [];
  while (at + 4 <= b.length && b[at] === 0xff) {
    const marker = b[at + 1];
    if (marker === 0xda || marker === 0xd9) break;
    const length = (b[at + 2] << 8) | b[at + 3];
    if (marker === 0xe2 && ascii(b, at + 4, 11) === 'ICC_PROFILE') icc.push(b.subarray(at + 18, at + 2 + length));
    if (marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc) facts.bitDepth = b[at + 4];
    at += 2 + length;
  }
  if (icc.length) facts.wideColourProfile = !isSRGBProfile(icc[0]);
}

function sniffWebP(b: Uint8Array, facts: SourceFacts) {
  facts.bitDepth = 8;
  let at = 12;
  let frames = 0;
  while (at + 8 <= b.length) {
    const type = ascii(b, at, 4);
    const length = u32le(b, at + 4);
    const data = at + 8;
    if (type === 'VP8X') {
      const flags = b[data];
      facts.hasAlpha = (flags & 0x10) !== 0;
    } else if (type === 'VP8L') {
      facts.losslessCoded = true;
      // Lossless bitstream header: the alpha hint is bit 28 after the signature.
      if (!facts.hasAlpha) facts.hasAlpha = ((u32le(b, data + 1) >>> 28) & 1) === 1;
    } else if (type === 'ANMF') {
      frames += 1;
      // A frame holds its own VP8/VP8L chunk; lossless only if all are.
      const inner = ascii(b, data + 16, 4);
      if (frames === 1) facts.losslessCoded = inner === 'VP8L';
      else if (inner !== 'VP8L') facts.losslessCoded = false;
    } else if (type === 'ICCP') {
      facts.wideColourProfile = !isSRGBProfile(b.subarray(data, data + length));
    }
    at = data + length + (length & 1);
  }
  facts.frames = Math.max(1, frames);
}

function sniffGIF(b: Uint8Array, facts: SourceFacts) {
  facts.bitDepth = 8;
  // LZW-coded palette indices: lossless for what the palette holds.
  facts.losslessCoded = true;
  let at = 13;
  const flags = b[10];
  if (flags & 0x80) at += 3 * (1 << ((flags & 7) + 1));
  let frames = 0;
  const skipSubBlocks = () => {
    while (at < b.length && b[at] !== 0) at += b[at] + 1;
    at += 1;
  };
  while (at < b.length) {
    const block = b[at];
    if (block === 0x2c) {
      frames += 1;
      const local = b[at + 9];
      at += 10;
      if (local & 0x80) at += 3 * (1 << ((local & 7) + 1));
      at += 1; // LZW minimum code size
      skipSubBlocks();
    } else if (block === 0x21) {
      if (b[at + 1] === 0xf9 && (b[at + 3] & 1)) facts.hasAlpha = true;
      at += 2;
      skipSubBlocks();
    } else {
      break;
    }
  }
  facts.frames = Math.max(1, frames);
}

export function sniff(bytes: ArrayBuffer | Uint8Array): SourceFacts {
  const b = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  const format = sniffFormat(b);
  const facts: SourceFacts = { format, hasAlpha: false, frames: 1, bitDepth: null, losslessCoded: false, wideColourProfile: false };
  try {
    switch (format) {
      case 'png': sniffPNG(b, facts); break;
      case 'jpeg': sniffJPEG(b, facts); break;
      case 'webp': sniffWebP(b, facts); break;
      case 'gif': sniffGIF(b, facts); break;
      case 'bmp': facts.losslessCoded = true; facts.hasAlpha = b[28] === 32; break;
      // AVIF: assume it may hold alpha; the pixel scan settles it.
      case 'avif': facts.hasAlpha = true; break;
    }
  } catch {
    // A truncated header leaves the defaults, which err towards caution.
  }
  return facts;
}
