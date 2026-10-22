# ADR 0008: Enhance (AI upscaling) and its models

Date: 2026-10-22 · Status: accepted

## Decision
- **Enhance** is its own tool, the third in the dock (⌘3). It enlarges the picture 2× or 4× on this Mac with Core ML. There are three styles:
  - **Fast**, for photos, with Low, Medium or High noise removal;
  - **Best**, for photos, with the most natural detail;
  - **Anime**, for drawings, anime and flat-colour art.

  **Restore faces** can also be switched on. It runs after the crop and before Fit and resize, so every output (formats, Compose, PDF) gets it.
- **Models**, all downloaded on first use (nothing is bundled, so the app stays about 6.6 MB):

  | Model | Source | Licence | Download |
  |---|---|---|---|
  | Fast (×3 noise strengths) | Real-ESRGAN `realesr-general-x4v3`, blended like Real-ESRGAN's `-dn` | BSD-3-Clause | 3 × 2.3 MB |
  | Best | Real-ESRGAN `RealESRGAN_x4plus`, 8-bit weights | BSD-3-Clause | 13 MB |
  | Anime | Real-ESRGAN `RealESRGAN_x4plus_anime_6B`, 8-bit weights | BSD-3-Clause | 3.7 MB |
  | Faces | GFPGAN v1.4, 8-bit weights, float32 maths | Apache-2.0 | 76 MB |

  The models come from the GitHub release `models-1` on vxkram/DEX, built by `scripts/models/build.py`. That script checks each converted model against PyTorch:

  | Model | Match with PyTorch |
  |---|---|
  | Fast | 54–59 dB |
  | Best | 45 dB |
  | Anime | 45 dB |
  | Faces | 40 dB |

- **Speed** on an M4 Pro, at 4×:

  | Model | 1 MP | 4 MP | 12 MP |
  |---|---|---|---|
  | Fast | 0.5 s | 1.7 s | 4.8 s |
  | Best | 4.1 s | 15 s | 43 s |
  | Anime | 1.3 s | 4.8 s | 14 s |
  | Faces | about 0.07 s per face | | |

- **How it runs:**
  - The image goes through in 256 px tiles, each with 16 px of context, keeping only each tile's middle.
  - Transparency is enlarged separately (Lanczos).
  - 2× is 4× followed by a Lanczos downscale.
  - Faces are found with Apple Vision. Five landmarks (eyes, nose tip, mouth corners) line each face up with GFPGAN's 512² template, and the restored face is pasted back through a soft mask. Faces narrower than 48 px are left alone.
- **Never silent:**
  - The plan always lists Enhance as a loss: "AI … adds detail that wasn't in the original; it can invent texture and change small text". In testing, a "NASA" patch came back as "NVGA".
  - When faces are restored, the plan says that too.
  - HDR is dropped, with a note.
  - Results above the megapixel limit are refused.
- **Preview:** the stage shows a before/after split of the preview, enhanced at up to 640 px on its long side. The export uses every pixel. The size isn't measured in the background, because that would run the whole model; it is known after export.

## Download and trust
- The sandboxed app still has no network access. The Downloader XPC service (ADR 0006) gets one more method, `fetchModel`:
  - The app opens the destination file in its own container and passes the service the file handle.
  - The service streams the zip into it.
  - The service accepts only `https://github.com/vxkram/DEX/releases/download/models-…/….mlpackage.zip`.

  This keeps the service out of the app's container, and the app out of the network.
- The app pins each file's size and SHA-256 in `EnhanceModel` (MediaModel), not fetched from anywhere, so a changed file is refused. After checking, it unpacks the zip with `ditto`, compiles it with `MLModel.compileModel`, and keeps the result in `Application Support/DEX/Models/`. **Info ▸ AI models** lists the models with their sizes and can delete them.

## Rejected
- **CodeFormer**, the best face model: its licence (NTU S-Lab 1.0) allows non-commercial use only, so it can't be part of an MIT app.
- **HAT and SwinIR:** 2–3× slower than Real-ESRGAN, transformer layers that convert less cleanly, and a small quality gain.
- **MetalFX's spatial scaler:** a sharpening filter, not a model. It adds no real detail.
- **float16 maths for GFPGAN:** StyleGAN2's demodulation overflows and the result is wrong (13 dB). Float32 maths with 8-bit weights is right, at a quarter of the float32 size.

## Caveat
GFPGAN's code and weights are Apache-2.0, but the model was trained on FFHQ, whose images are licensed CC BY-NC-SA. Whether that limits the weights is unsettled. Faces is therefore off by default and downloaded only when someone switches it on, and this caveat is stated in NOTICES and in About.
