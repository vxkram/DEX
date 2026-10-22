// Whether WebCodecs can make H.264 + AAC here, asked without loading the
// whole media library (the popup only needs this answer).

export async function canReencode(): Promise<boolean> {
  try {
    if (typeof VideoEncoder === 'undefined' || typeof AudioEncoder === 'undefined') return false;
    const video = await VideoEncoder.isConfigSupported({ codec: 'avc1.640028', width: 1920, height: 1080, bitrate: 8_000_000 });
    const audio = await AudioEncoder.isConfigSupported({ codec: 'mp4a.40.2', sampleRate: 48_000, numberOfChannels: 2, bitrate: 192_000 });
    return !!video.supported && !!audio.supported;
  } catch {
    return false;
  }
}
