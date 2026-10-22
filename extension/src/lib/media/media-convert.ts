// WebM to MP4 with Mediabunny: a remux copies the streams untouched; a
// re-encode makes H.264 + AAC through WebCodecs, which plays everywhere.

import {
  BlobSource, MATROSKA, MP4, QTFF, WEBM, BufferTarget, Conversion, Input, Mp4OutputFormat, Output, QUALITY_HIGH,
} from 'mediabunny';
import { canReencode } from './encoders';
import type { Verdict } from '../image/planner';

export type WebmMode = 'remux' | 'h264';

export interface MediaResult {
  blob: Blob;
  extension: 'mp4' | 'm4a';
  verdict: Verdict;
  summary: string;
}

const codecName: Record<string, string> = {
  vp8: 'VP8', vp9: 'VP9', av1: 'AV1', avc: 'H.264', hevc: 'HEVC', opus: 'Opus', vorbis: 'Vorbis', aac: 'AAC',
};

export async function convertWebm(blob: Blob, mode: WebmMode, onProgress?: (fraction: number) => void): Promise<MediaResult> {
  const input = new Input({ source: new BlobSource(blob), formats: [WEBM, MATROSKA, MP4, QTFF] });
  const tracks = [...await input.getVideoTracks(), ...await input.getAudioTracks()];
  if (!tracks.length) throw new Error('This file has no video or audio DEX can read.');
  const hasVideo = tracks.some((t) => t.type === 'video');
  const format = new Mp4OutputFormat({ fastStart: 'in-memory' });
  const codecs = tracks.map((t) => codecName[t.codec ?? ''] ?? t.codec ?? 'unknown');

  if (mode === 'remux') {
    // A remux must never quietly turn into a re-encode.
    const supported = format.getSupportedCodecs() as string[];
    const stuck = tracks.filter((t) => !t.codec || !supported.includes(t.codec));
    if (stuck.length) {
      throw new Error(`MP4 can’t hold ${stuck.map((t) => codecName[t.codec ?? ''] ?? 'this codec').join(' or ')} without re-encoding. Choose “Re-encode” to convert it.`);
    }
  } else if (!(await canReencode())) {
    throw new Error('This browser can’t encode H.264 and AAC.');
  }

  const output = new Output({ format, target: new BufferTarget() });
  const conversion = await Conversion.init({
    input,
    output,
    showWarnings: false,
    ...(mode === 'h264' && {
      video: { codec: 'avc', forceTranscode: true, quality: QUALITY_HIGH },
      audio: { codec: 'aac', forceTranscode: true, quality: QUALITY_HIGH },
    }),
  });
  if (!conversion.isValid || conversion.discardedTracks.length) {
    const reason = conversion.discardedTracks[0]?.reason ?? 'unknown';
    throw new Error(`DEX can’t convert this file (${reason.replaceAll('_', ' ')}).`);
  }
  if (onProgress) conversion.onProgress = (p) => onProgress(p);
  await conversion.execute();

  const buffer = (output.target as BufferTarget).buffer!;
  const extension = hasVideo ? 'mp4' : 'm4a';
  const result = new Blob([buffer], { type: hasVideo ? 'video/mp4' : 'audio/mp4' });
  return mode === 'remux'
    ? {
        blob: result, extension, verdict: 'noReencode',
        summary: `${codecs.join(' + ')} copied into ${extension.toUpperCase()} untouched`,
      }
    : {
        blob: result, extension, verdict: 'lossy',
        summary: `Re-encoded as ${hasVideo ? 'H.264 + AAC' : 'AAC'}`,
      };
}
