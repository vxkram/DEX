import { useEffect, useMemo, useRef, useState } from 'preact/hooks';
import { browser } from 'wxt/browser';
import { Backdrop } from '@/components/Backdrop';
import { Notes, Segmented, SectionHeader, VerdictBadge } from '@/components/Controls';
import { Icon, type IconName } from '@/components/Icon';
import { aspectRatio, boxAround, centred, cropAspects, placeIn, type CropAspect, type FrameMode, type Rect, type Size } from '@/lib/image/crop-math';
import { takeFile } from '@/lib/shared/file-store';
import { compose, detectCapabilities, exportImage, load, orient, type Exported, type Loaded } from '@/lib/image/image-codec';
import { baseName, formatBytes } from '@/lib/shared/names';
import {
  animatedTargetFormats, displayName, fileExtension, frameHasGap, maximumLossyQuality, noGeometry, orientedSize, plan as makePlan, targetFormats,
  type Background, type Capabilities, type Frame, type FrameRange, type Geometry, type Plan, type TargetFormat,
} from '@/lib/image/planner';
import { CropOverlay } from './CropOverlay';
import { Timeline } from './Timeline';

type Tool = 'crop' | 'convert' | 'resize';
const tools: { id: Tool; title: string; icon: IconName }[] = [
  { id: 'crop', title: 'Crop', icon: 'crop' },
  { id: 'resize', title: 'Resize', icon: 'resize' },
  // Last: the format is chosen, and the file saved, only here.
  { id: 'convert', title: 'Convert', icon: 'convert' },
];

/** Proportional resizing, as in the Mac app's Compress panel: never enlarges. */
type ResizeSpec = { scale: number } | { longEdge: number } | null;

function resizedSize(size: Size, spec: ResizeSpec): Size | null {
  if (!spec) return null;
  const long = Math.max(size.width, size.height);
  const factor = 'scale' in spec ? spec.scale : spec.longEdge / long;
  if (factor >= 1) return null;
  return { width: Math.max(1, Math.round(size.width * factor)), height: Math.max(1, Math.round(size.height * factor)) };
}

/** A shape for the result: a preset ratio, or a custom ratio or pixel size. */
type Shape = CropAspect | 'custom' | null;
interface Custom { unit: 'ratio' | 'pixels'; width: number; height: number }

/** The preview is drawn from a copy no larger than this. */
const previewLongEdge = 2048;

type Status =
  | { state: 'empty' }
  | { state: 'loading' }
  | { state: 'needsAccess'; origin: string; retry: () => void }
  | { state: 'error'; message: string }
  | { state: 'ready' };

export function Editor() {
  const [status, setStatus] = useState<Status>({ state: 'loading' });
  const [loaded, setLoaded] = useState<Loaded | null>(null);
  const [name, setName] = useState('image');
  /** The name to save under, without extension; the user can edit it. */
  const [stem, setStem] = useState('image');
  const [caps, setCaps] = useState<Capabilities>({ webpMaxIsLossless: false, canWriteWebP: true });
  const [tool, setTool] = useState<Tool>('crop');
  const [geometry, setGeometry] = useState<Geometry>(noGeometry);
  const [shape, setShape] = useState<Shape>(null);
  const [mode, setMode] = useState<FrameMode>('crop');
  const [custom, setCustom] = useState<Custom>({ unit: 'ratio', width: 3, height: 2 });
  const [background, setBackground] = useState<Background>({ kind: 'blur' });
  const [colour, setColour] = useState('#ffffff');
  const [resize, setResize] = useState<ResizeSpec>(null);
  const [target, setTarget] = useState<TargetFormat>('png');
  const [quality, setQuality] = useState<'max' | number>('max');
  const [estimate, setEstimate] = useState<{ plan: Plan; result: Exported } | null>(null);
  // The timeline, for animations: the frame shown, and the part a GIF keeps.
  const [current, setCurrent] = useState(0);
  const [range, setRange] = useState({ start: 0, end: 0 });
  const [playing, setPlaying] = useState(false);
  const [saved, setSaved] = useState<string | null>(null);
  const [over, setOver] = useState(false);
  const picker = useRef<HTMLInputElement>(null);

  async function open(blob: Blob, fileName: string) {
    setStatus({ state: 'loading' });
    try {
      const next = await load(blob);
      setLoaded((previous) => {
        previous?.bitmap.close();
        return next;
      });
      setName(fileName);
      setStem(fileName.replace(/\.[^.]+$/, '') || 'image');
      setGeometry(noGeometry);
      setShape(null);
      setMode('crop');
      setResize(null);
      setQuality('max');
      setSaved(null);
      // PNG unless the user picks otherwise: lossless, and opens anywhere.
      // An animation stays a GIF, so it keeps moving.
      setTarget(next.animation ? 'gif' : 'png');
      setCurrent(0);
      setRange({ start: 0, end: (next.animation?.frames.length ?? 1) - 1 });
      setPlaying(!!next.animation);
      setStatus({ state: 'ready' });
      document.title = `${fileName} · DEX`;
    } catch (error) {
      setStatus({ state: 'error', message: error instanceof Error ? error.message : String(error) });
    }
  }

  async function openURL(src: string, tab: number | null) {
    setStatus({ state: 'loading' });
    const fileName = (src.startsWith('http') && baseName(src)) || 'image';
    try {
      let url = src;
      if (src.startsWith('blob:')) {
        const reply = await browser.runtime.sendMessage({ target: 'background', type: 'read-blob', tab, url: src });
        if (!reply?.dataUrl) throw new Error('The page’s image couldn’t be read.');
        url = reply.dataUrl;
      }
      const response = await fetch(url, { credentials: 'include' });
      if (!response.ok) throw new Error(`The site refused to send the image (HTTP ${response.status}).`);
      // The site's own name for the file, when it gives one, beats the URL's.
      const given = /filename\*?=(?:UTF-8'')?"?([^";]+)"?/i.exec(response.headers.get('content-disposition') ?? '')?.[1];
      await open(await response.blob(), given ? decodeURIComponent(given) : fileName);
    } catch (error) {
      const origin = /^https?:/.test(src) ? new URL(src).origin : null;
      if (origin && !(await browser.permissions.contains({ origins: [`${origin}/*`] }))) {
        setStatus({ state: 'needsAccess', origin, retry: () => openURL(src, tab) });
      } else {
        setStatus({ state: 'error', message: error instanceof Error ? error.message : String(error) });
      }
    }
  }

  useEffect(() => {
    detectCapabilities().then(setCaps);
    const params = new URLSearchParams(location.search);
    const file = params.get('file'), src = params.get('src'), tab = params.get('tab');
    if (file) {
      takeFile(file).then((stored) => stored ? open(stored.blob, stored.name) : setStatus({ state: 'empty' }));
    } else if (src) {
      openURL(src, tab ? Number(tab) : null);
    } else {
      setStatus({ state: 'empty' });
    }
    const paste = (event: ClipboardEvent) => {
      const pasted = [...(event.clipboardData?.files ?? [])].find((f) => f.type.startsWith('image/'));
      if (pasted) open(pasted, pasted.name || 'Pasted image.png');
    };
    addEventListener('paste', paste);
    return () => removeEventListener('paste', paste);
  }, []);

  // MARK: Plan

  const display = loaded ? orientedSize(loaded.source, geometry) : { width: 0, height: 0 };
  const ratio = shape == null ? null : shape === 'custom' ? custom.width / custom.height : aspectRatio(shape);
  const pixels = shape === 'custom' && custom.unit === 'pixels' ? { width: custom.width, height: custom.height } : null;
  // Fit keeps the whole image; Crop keeps the box the user drew.
  const fits = ratio != null && mode === 'fit';
  const crop = fits ? null : geometry.crop;
  const frame = useMemo((): Frame | null => {
    if (!loaded) return null;
    const src = crop ? { width: crop.width, height: crop.height } : display;
    if (fits) {
      const box = pixels ?? boxAround(display, ratio!);
      return { ...box, image: placeIn(display, box, 'fit'), background };
    }
    if (pixels) return { ...pixels, image: placeIn(src, pixels, 'crop'), background };
    return null;
  }, [loaded, JSON.stringify([crop, display, ratio, pixels, fits, background])]);
  const framedSize = frame ?? (crop ? { width: crop.width, height: crop.height } : display);
  const fullGeometry: Geometry = { ...geometry, crop, frame, resize: resizedSize(framedSize, resize) };
  const animation = loaded?.animation ?? null;
  // A GIF depends on the trim only; a still on the frame shown. Keeping the
  // other out stops playback from re-planning (and re-encoding) every frame.
  const frames: FrameRange | undefined = !animation ? undefined
    : target === 'gif' ? { current: 0, ...range } : { current, start: 0, end: animation.frames.length - 1 };

  const planResult = useMemo((): { plan: Plan } | { error: string } | null => {
    if (!loaded) return null;
    try {
      return { plan: makePlan(loaded.source, { target, quality, geometry: fullGeometry, frames }, caps) };
    } catch (error) {
      return { error: error instanceof Error ? error.message : String(error) };
    }
  }, [loaded, target, quality, JSON.stringify(fullGeometry), JSON.stringify(frames), caps]);
  const plan = planResult && 'plan' in planResult ? planResult.plan : null;

  // Encode in the background so the size estimate is real, and Save is instant.
  useEffect(() => {
    if (!loaded || !plan) return;
    setSaved(null);
    // Only Convert shows the size and saves; don't encode while cropping.
    if (tool !== 'convert') return;
    let cancelled = false;
    const timer = setTimeout(() => {
      exportImage(loaded, plan).then((result) => !cancelled && setEstimate({ plan, result }), () => {});
    }, playing ? 600 : 250);
    return () => { cancelled = true; clearTimeout(timer); };
  }, [plan, tool]);
  const fresh = estimate && estimate.plan === plan ? estimate.result : null;
  // The encoder may find more to say (a GIF needing fewer colours).
  const shownNotes = plan ? [...(fresh?.notes ?? []), ...plan.notes] : [];
  const shownVerdict = plan && (fresh?.notes.some((n) => n.isLoss) ? 'lossy' : plan.verdict);

  async function save() {
    if (!loaded || !plan) return;
    const { blob } = fresh ?? await exportImage(loaded, plan);
    const filename = `${safeStem(stem)}.${fileExtension[plan.request.target]}`;
    const url = URL.createObjectURL(blob);
    try {
      await browser.downloads.download({ url, filename, saveAs: true });
      setSaved(filename);
    } catch {
      // The user closed the save panel.
    }
    setTimeout(() => URL.revokeObjectURL(url), 60_000);
  }

  // MARK: Preview

  const shownFrame = animation?.frames[current] ?? loaded?.bitmap;
  const previewBase = useMemo(() => {
    if (!loaded || !shownFrame) return null;
    const bitmap = shownFrame;
    const scale = Math.min(1, previewLongEdge / Math.max(bitmap.width, bitmap.height));
    const canvas = new OffscreenCanvas(Math.round(bitmap.width * scale), Math.round(bitmap.height * scale));
    const ctx = canvas.getContext('2d')!;
    ctx.imageSmoothingQuality = 'high';
    ctx.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
    return { canvas, scale };
  }, [loaded, shownFrame]);

  // Playback within the trimmed range, at each frame's own delay.
  useEffect(() => {
    if (!animation || !playing) return;
    const timer = setTimeout(() => setCurrent((c) => (c >= range.end || c < range.start ? range.start : c + 1)), animation.delays[current]);
    return () => clearTimeout(timer);
  }, [animation, playing, current, range.start, range.end]);

  const stageCanvas = useRef<HTMLCanvasElement>(null);
  // The crop box is drawn over the whole image; everything else shows the result.
  const showsWholeImage = tool === 'crop' && !fits;
  useEffect(() => {
    const el = stageCanvas.current;
    if (!previewBase || !el) return;
    const oriented = orient(previewBase.canvas, geometry);
    const s = previewBase.scale;
    const picture = showsWholeImage
      ? oriented
      : compose(oriented, crop && scaleRect(crop, s), frame && { ...frame, width: Math.round(frame.width * s), height: Math.round(frame.height * s), image: scaleRect(frame.image, s) });
    el.width = picture.width;
    el.height = picture.height;
    el.getContext('2d')!.drawImage(picture, 0, 0);
  }, [previewBase, geometry.turns, geometry.flipH, geometry.flipV, showsWholeImage, !showsWholeImage && JSON.stringify([crop, frame])]);

  // MARK: Editing

  const setCrop = (crop: Rect | null) => setGeometry((g) => ({ ...g, crop }));
  const turn = (by: number) => {
    setGeometry((g) => ({ ...g, turns: (g.turns + by + 4) % 4, crop: null }));
    setShape(null);
  };
  // Flips are in what the user sees, so after a quarter turn they swap axes.
  const flip = (horizontal: boolean) => setGeometry((g) => {
    const flipsStoredH = horizontal !== (g.turns % 2 === 1);
    return { ...g, flipH: flipsStoredH ? !g.flipH : g.flipH, flipV: flipsStoredH ? g.flipV : !g.flipV, crop: null };
  });
  // A new shape starts as the largest centred crop of it.
  const chooseShape = (next: Shape, nextCustom = custom) => {
    const same = next === shape && next !== 'custom';
    setShape(same ? null : next);
    setCustom(nextCustom);
    const r = same || next == null ? null : next === 'custom' ? nextCustom.width / nextCustom.height : aspectRatio(next);
    setCrop(r == null ? null : centred(r, display));
  };
  const reset = () => {
    setGeometry(noGeometry);
    setShape(null);
    setMode('crop');
  };
  const chooseBackground = (kind: Background['kind']) =>
    setBackground(kind === 'color' ? { kind, color: colour } : { kind });

  const drop = (event: DragEvent) => {
    event.preventDefault();
    setOver(false);
    const file = [...(event.dataTransfer?.files ?? [])].find((f) => f.type.startsWith('image/'));
    if (file) open(file, file.name);
  };

  const chooser = (
    <input ref={picker} type="file" accept="image/*" hidden
      onChange={(e) => { const f = e.currentTarget.files?.[0]; if (f) open(f, f.name); e.currentTarget.value = ''; }} />
  );

  if (status.state !== 'ready' || !loaded) {
    return (
      <div class="editor empty" onDragOver={(e) => { e.preventDefault(); setOver(true); }} onDragLeave={() => setOver(false)} onDrop={drop}>
        <Backdrop parallax />
        {chooser}
        <div class={`welcome glass float ${over ? 'over' : ''}`}>
          <span class="wordmark">DEX</span>
          <Icon name="photo" />
          {status.state === 'loading' && <h1>Opening…</h1>}
          {status.state === 'empty' && <h1>Choose an image</h1>}
          {status.state === 'error' && <><h1>Couldn’t open it</h1><p class="caption">{status.message}</p></>}
          {status.state === 'needsAccess' && (
            <>
              <h1>Let DEX read this image</h1>
              <p class="caption">The image is on {new URL(status.origin).host}. DEX needs your permission to fetch it.</p>
              <button type="button" class="button primary" onClick={() =>
                browser.permissions.request({ origins: [`${status.origin}/*`] }).then((ok) => ok && status.retry())}>
                Allow {new URL(status.origin).host}
              </button>
            </>
          )}
          {status.state !== 'loading' && (
            <>
              <button type="button" class={`button ${status.state === 'needsAccess' ? '' : 'primary'}`} onClick={() => picker.current?.click()}>Choose Image…</button>
              <span class="caption">PNG · JPEG · WebP · GIF · AVIF · BMP</span>
            </>
          )}
        </div>
      </div>
    );
  }

  const output = plan?.outputSize;
  const outputDims = output ?? resizedSize(framedSize, resize) ?? framedSize;
  const lossy = shownVerdict === 'lossy';
  const lossyTarget = target === 'jpeg' || target === 'webp';
  const longEdge = Math.max(framedSize.width, framedSize.height);
  const gap = frame != null && frameHasGap(frame);

  return (
    <div class={`editor ${animation ? 'animated' : ''}`} onDragOver={(e) => { e.preventDefault(); setOver(true); }} onDragLeave={() => setOver(false)} onDrop={drop}>
      <Backdrop parallax />
      {chooser}

      <header class="topbar">
        <span class="wordmark">DEX</span>
        <label class="file-name" title="Rename the file you’ll save">
          <Icon name="pencil" />
          {/* The hidden copy of the text sizes the field to fit it. */}
          <span class="name-wrap" data-value={stem}>
            <input class="name-field" value={stem} spellcheck={false} aria-label="File name" size={1}
              onInput={(e) => setStem(e.currentTarget.value)}
              onBlur={(e) => { if (!e.currentTarget.value.trim()) setStem(name.replace(/\.[^.]+$/, '') || 'image'); }}
              onKeyDown={(e) => e.key === 'Enter' && e.currentTarget.blur()} />
          </span>
          <span class="name-extension">.{fileExtension[target]}</span>
        </label>
        <span class="output-size technical" title="Size of the file you’ll save">{outputDims.width} × {outputDims.height}</span>
        <span class="caption technical source-facts">from {loaded.source.width} × {loaded.source.height} · {displayName[loaded.source.format]} · {formatBytes(loaded.bytes.size)}</span>
        <button type="button" class="button" onClick={() => picker.current?.click()}>Open…</button>
      </header>

      <main class={`stage ${over ? 'over' : ''}`}>
        <div class="frame">
          <canvas ref={stageCanvas} />
          {showsWholeImage && (
            <CropOverlay crop={geometry.crop ?? { x: 0, y: 0, ...display }} size={display} ratio={ratio}
              onChange={(c) => setCrop(c)} />
          )}
        </div>
      </main>

      {animation && (
        <Timeline animation={animation} current={current} range={range} playing={playing}
          onSeek={(i) => { setPlaying(false); setCurrent(i); }}
          onRange={(r) => { setRange(r); setCurrent((c) => Math.min(Math.max(c, r.start), r.end)); }}
          onPlay={setPlaying}
          trimming={target === 'gif'} />
      )}

      <nav class="dock glass" aria-label="Tools">
        {tools.map((t) => (
          <button type="button" key={t.id} class="tile" aria-pressed={tool === t.id} onClick={() => setTool(t.id)}>
            <Icon name={t.icon} />
            <span>{t.title}</span>
          </button>
        ))}
      </nav>

      <aside class="panel glass">
        <h2>{tools.find((t) => t.id === tool)!.title}</h2>
        <div class="panel-body">
          {tool === 'crop' && (
            <>
              <section>
                <SectionHeader>Rotate &amp; flip</SectionHeader>
                <div class="grid cols-4">
                  <button type="button" class="button" title="Rotate left" onClick={() => turn(-1)}><Icon name="rotateLeft" label="Rotate left" /></button>
                  <button type="button" class="button" title="Rotate right" onClick={() => turn(1)}><Icon name="rotateRight" label="Rotate right" /></button>
                  <button type="button" class="button" title="Flip horizontally" onClick={() => flip(true)}><Icon name="flipH" label="Flip horizontally" /></button>
                  <button type="button" class="button" title="Flip vertically" onClick={() => flip(false)}><Icon name="flipV" label="Flip vertically" /></button>
                </div>
              </section>
              <section>
                <SectionHeader>Aspect ratio</SectionHeader>
                <div class="grid cols-3">
                  {cropAspects.map((a) => (
                    <button type="button" key={a} class="chip" aria-pressed={shape === a} onClick={() => chooseShape(a)}>{a}</button>
                  ))}
                  <button type="button" class="chip" aria-pressed={shape === 'custom'} onClick={() => chooseShape('custom')}>Custom</button>
                </div>
                {shape == null && <p class="caption">Drag the corners for a free crop, or pick a shape.</p>}
              </section>
              {shape === 'custom' && (
                <section>
                  <SectionHeader>Custom</SectionHeader>
                  <Segmented label="Custom size" value={custom.unit}
                    onChange={(unit) => chooseShape('custom', unit === 'pixels'
                      ? { unit, width: framedSize.width, height: framedSize.height }
                      : { unit, width: 3, height: 2 })}
                    options={[{ value: 'ratio', title: 'Ratio' }, { value: 'pixels', title: 'Pixels' }]} />
                  <div class="custom-size">
                    <input class="field" type="number" min={1} aria-label="Width" value={custom.width}
                      onChange={(e) => { const width = Math.round(Number(e.currentTarget.value)); if (width > 0) chooseShape('custom', { ...custom, width }); }} />
                    <span>{custom.unit === 'ratio' ? ':' : '×'}</span>
                    <input class="field" type="number" min={1} aria-label="Height" value={custom.height}
                      onChange={(e) => { const height = Math.round(Number(e.currentTarget.value)); if (height > 0) chooseShape('custom', { ...custom, height }); }} />
                    {custom.unit === 'pixels' && <span class="caption">px</span>}
                  </div>
                </section>
              )}
              {ratio != null && (
                <section>
                  <SectionHeader>Image</SectionHeader>
                  <Segmented label="Image" value={mode} onChange={setMode}
                    options={[{ value: 'crop', title: 'Crop to fill' }, { value: 'fit', title: 'Fit whole image' }]} />
                </section>
              )}
              {gap && (
                <section>
                  <SectionHeader>Background</SectionHeader>
                  <Segmented label="Background" value={background.kind} onChange={chooseBackground}
                    options={[{ value: 'blur', title: 'Blur' }, { value: 'color', title: 'Colour' }, { value: 'transparent', title: 'None' }]} />
                  {background.kind === 'color' && (
                    <div class="colours">
                      {['#ffffff', '#000000', '#f55c26'].map((c) => (
                        <button type="button" key={c} class="swatch" style={{ background: c }} aria-label={c} aria-pressed={colour === c}
                          onClick={() => { setColour(c); setBackground({ kind: 'color', color: c }); }} />
                      ))}
                      <label class="swatch picker" title="Any colour">
                        <input type="color" value={colour}
                          onInput={(e) => { const c = e.currentTarget.value; setColour(c); setBackground({ kind: 'color', color: c }); }} />
                      </label>
                      <span class="technical">{colour.toUpperCase()}</span>
                    </div>
                  )}
                  {background.kind === 'transparent' && target === 'jpeg' && <p class="caption">JPEG can’t be transparent: it’ll be white.</p>}
                </section>
              )}
              <button type="button" class="link" onClick={reset}>Reset crop &amp; rotation</button>
            </>
          )}

          {tool === 'convert' && (
            <>
              <section>
                <SectionHeader>Format</SectionHeader>
                <div class={`grid ${animation ? 'cols-4' : 'cols-3'}`}>
                  {(animation ? animatedTargetFormats : targetFormats).map((f) => (
                    <button type="button" key={f} class="button format" aria-pressed={target === f} onClick={() => setTarget(f)}
                      disabled={f === 'webp' && !caps.canWriteWebP} title={f === 'webp' && !caps.canWriteWebP ? 'This browser can’t write WebP.' : undefined}>
                      {displayName[f]}
                    </button>
                  ))}
                </div>
              </section>
              {lossyTarget && (
                <section>
                  <SectionHeader>Quality</SectionHeader>
                  <div class="quality">
                    <input type="range" min={40} max={96} step={1} aria-label="Quality"
                      value={quality === 'max' ? 96 : Math.round(quality * 100)}
                      onInput={(e) => { const v = Number(e.currentTarget.value); setQuality(v >= 96 ? 'max' : v / 100); }} />
                    <span class="technical">
                      {quality === 'max'
                        ? target === 'webp' && caps.webpMaxIsLossless ? 'Max · Lossless' : `Max · ${Math.round(maximumLossyQuality * 100)}`
                        : Math.round(quality * 100)}
                    </span>
                  </div>
                  <p class="caption">Lower quality means smaller files but less detail.</p>
                </section>
              )}
              <p class="caption">Re-encoded images lose their metadata: browsers can’t carry it over. An unchanged image is saved byte for byte.</p>
            </>
          )}

          {tool === 'resize' && (
            <section>
              <SectionHeader>Dimensions</SectionHeader>
              <div class="grid cols-4">
                {([[null, 'Original'], [0.75, '75%'], [0.5, '50%'], [0.25, '25%']] as const).map(([scale, title]) => (
                  <button type="button" key={title} class="chip"
                    aria-pressed={scale == null ? resize == null : resize != null && 'scale' in resize && resize.scale === scale}
                    onClick={() => setResize(scale == null ? null : { scale })}>{title}</button>
                ))}
              </div>
              <div class="grid cols-3 presets">
                {([[3840, '4K'], [2048, 'Web'], [1080, 'Social']] as const).filter(([edge]) => edge < longEdge).map(([edge, title]) => (
                  <button type="button" key={edge} class="chip" aria-pressed={resize != null && 'longEdge' in resize && resize.longEdge === edge}
                    onClick={() => setResize({ longEdge: edge })}>{title} · {edge}</button>
                ))}
              </div>
              <p class="caption">Resizing keeps the proportions and never enlarges.</p>
            </section>
          )}

          {tool === 'convert' && <section class="result">
            <SectionHeader>Result</SectionHeader>
            {planResult && 'error' in planResult && <p class="error">{planResult.error}</p>}
            {plan && output && (
              <>
                <p class="technical">Saves as {displayName[plan.request.target]} · {output.width} × {output.height}{fresh ? ` · ${formatBytes(fresh.blob.size)}` : ''}</p>
                <VerdictBadge verdict={shownVerdict!} />
                {shownNotes.length ? <Notes notes={shownNotes} /> : <p class="caption">The image data is copied exactly as it is.</p>}
                {plan.losslessAlternative && (
                  <button type="button" class="link" onClick={() => setTarget(plan.losslessAlternative!)}>
                    Use {displayName[plan.losslessAlternative]} instead: lossless, larger
                  </button>
                )}
              </>
            )}
          </section>}
        </div>
        <footer class="panel-footer">
          {tool === 'convert' ? (
            <>
              {saved && <p class="caption saved"><Icon name="checkCircle" /> {saved}</p>}
              <button type="button" class="button primary save" disabled={!plan} onClick={save}>
                {/* A lossy result keeps its warning on the button itself, as on the Mac. */}
                <Icon name={lossy ? 'warning' : 'download'} /> Save as {displayName[target]}…
              </button>
            </>
          ) : (
            <>
              {output && <p class="caption technical">{output.width} × {output.height}</p>}
              <button type="button" class="button primary save" onClick={() => setTool('convert')}>
                Choose Format <Icon name="arrowRight" />
              </button>
            </>
          )}
        </footer>
      </aside>
    </div>
  );
}

/** Characters no file system accepts in a name. */
function safeStem(stem: string): string {
  return stem.trim().replace(/[\\/:*?"<>|]+/g, '-') || 'image';
}

function scaleRect(r: Rect, s: number): Rect {
  return { x: Math.round(r.x * s), y: Math.round(r.y * s), width: Math.max(1, Math.round(r.width * s)), height: Math.max(1, Math.round(r.height * s)) };
}
