# Enhance models

DEX's Enhance tool downloads these Core ML models from the GitHub release
[`models-1`](https://github.com/vxkram/DEX/releases/tag/models-1). The app
pins each file's size and SHA-256, so a changed file is refused.

| File | Model | Licence | Notes |
|---|---|---|---|
| `dex-fast-{low,medium,high}` | Real-ESRGAN `realesr-general-x4v3`, denoise 0 / 0.5 / 1 | BSD-3-Clause | float16 |
| `dex-best` | Real-ESRGAN `RealESRGAN_x4plus` | BSD-3-Clause | 8-bit weights |
| `dex-anime` | Real-ESRGAN `RealESRGAN_x4plus_anime_6B` | BSD-3-Clause | 8-bit weights |
| `dex-faces` | GFPGAN v1.4 | Apache-2.0 | 8-bit weights, float32 maths; trained on FFHQ (CC BY-NC-SA images) |

All take an RGB image (256² tiles; 512² aligned faces for `dex-faces`) and
return RGB, 4× larger for the upscalers.

## Rebuilding

```sh
uv venv -p 3.12 venv && VIRTUAL_ENV=venv uv pip install torch==2.7.0 coremltools==9.0 numpy pillow
venv/bin/python build.py /tmp/dex-models
```

`build.py` downloads the official weights and the upstream architecture files
(pinned commits), rewrites StyleGAN2's modulated convolution for batch size 1
(checked to match upstream exactly), converts, checks each model against
PyTorch, and zips them into `/tmp/dex-models/release`. `shim/` stands in for
the three BasicSR helpers the architectures import.
