"""Builds the Core ML models DEX's Enhance tool downloads (release `models-1`).

Dev-only; nothing here ships in the app. Run it in a throwaway venv:

    uv venv -p 3.12 venv && VIRTUAL_ENV=venv uv pip install torch==2.7.0 coremltools==9.0 numpy pillow
    venv/bin/python build.py <work dir>

It downloads the official weights and the upstream architecture files (pinned
commits), converts each model, checks it against PyTorch, and writes the
zips and their SHA-256 to <work dir>/release.
"""
import hashlib
import shutil
import subprocess
import sys
import urllib.request
from pathlib import Path

import coremltools as ct
import coremltools.optimize.coreml as cto
import numpy as np
import torch
from PIL import Image
from torch import nn

WORK = Path(sys.argv[1]).resolve()
TILE = 256

WEIGHTS = {
    "realesr-general-x4v3.pth": "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesr-general-x4v3.pth",
    "realesr-general-wdn-x4v3.pth": "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesr-general-wdn-x4v3.pth",
    "RealESRGAN_x4plus.pth": "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth",
    "RealESRGAN_x4plus_anime_6B.pth": "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.2.4/RealESRGAN_x4plus_anime_6B.pth",
    "GFPGANv1.4.pth": "https://github.com/TencentARC/GFPGAN/releases/download/v1.3.0/GFPGANv1.4.pth",
}
ARCHS = {
    "srvgg_arch.py": "https://raw.githubusercontent.com/xinntao/Real-ESRGAN/a4abfb2979a7bbff3f69f58f58ae324608821e27/realesrgan/archs/srvgg_arch.py",
    "rrdbnet_arch.py": "https://raw.githubusercontent.com/XPixelGroup/BasicSR/8d56e3a045f9fb3e1d8872f92ee4a4f07f886b0a/basicsr/archs/rrdbnet_arch.py",
    "gfpganv1_clean_arch.py": "https://raw.githubusercontent.com/TencentARC/GFPGAN/7552a7791caad982045a7bbe5634bbf1cd5c8679/gfpgan/archs/gfpganv1_clean_arch.py",
    "stylegan2_clean_arch.py": "https://raw.githubusercontent.com/TencentARC/GFPGAN/7552a7791caad982045a7bbe5634bbf1cd5c8679/gfpgan/archs/stylegan2_clean_arch.py",
}

# StyleGAN2's modulated convolution, rewritten for batch size 1 so every shape
# is static for Core ML. Same maths as upstream (checked below: max diff 0).
BATCH_ONE = """        style = self.modulation(style).view(1, -1, 1, 1)
        weight = self.weight[0] * style  # (c_out, c_in, k, k)
        if self.demodulate:
            demod = torch.rsqrt(weight.pow(2).sum([1, 2, 3]) + self.eps)
            weight = weight * demod.view(-1, 1, 1, 1)
        if self.sample_mode == 'upsample':
            x = F.interpolate(x, scale_factor=2, mode='bilinear', align_corners=False)
        elif self.sample_mode == 'downsample':
            x = F.interpolate(x, scale_factor=0.5, mode='bilinear', align_corners=False)
        out = F.conv2d(x, weight, padding=self.padding)
"""


def fetch(url, path):
    if not path.exists():
        print("downloading", path.name, flush=True)
        urllib.request.urlretrieve(url, path)


def prepare():
    weights, archs, upstream = WORK / "weights", WORK / "archs/dexarchs", WORK / "upstream/upstreamarchs"
    for folder in (weights, archs, upstream):
        folder.mkdir(parents=True, exist_ok=True)
    for name, url in WEIGHTS.items():
        fetch(url, weights / name)
    for name, url in ARCHS.items():
        fetch(url, upstream / name)
        source = (upstream / name).read_text()
        if name == "stylegan2_clean_arch.py":
            start = source.index("        b, c, h, w = x.shape  # c = c_in")
            end = source.index("        return out\n\n    def __repr__(self):", start)
            source = source[:start] + BATCH_ONE + source[end:]
        (archs / name).write_text(source)
    shutil.copy(Path(__file__).parent / "shim/basicsr/archs/arch_util.py", archs / "arch_util.py")
    for folder in (archs, upstream):
        (folder / "__init__.py").touch()
    sys.path[:0] = [str(Path(__file__).parent / "shim"), str(WORK / "archs"), str(WORK / "upstream")]
    return weights


def load(path, key):
    state = torch.load(path, map_location="cpu", weights_only=True)
    return state[key] if key in state else state


class Upscaler(nn.Module):
    """RGB in (Core ML scales 0…255 to 0…1), RGB 0…255 out, 4× larger."""

    def __init__(self, net):
        super().__init__()
        self.net = net.eval()

    def forward(self, x):
        return torch.clamp(self.net(x), 0, 1) * 255


class FaceRestorer(nn.Module):
    """A 512² aligned face, 0…1 in, 0…255 out. GFPGAN works in -1…1."""

    def __init__(self, net):
        super().__init__()
        self.net = net.eval()

    def forward(self, x):
        out = self.net(x * 2 - 1, return_rgb=False, randomize_noise=False)[0]
        return torch.clamp((out + 1) / 2, 0, 1) * 255


def models(weights):
    from dexarchs.gfpganv1_clean_arch import GFPGANv1Clean
    from dexarchs.rrdbnet_arch import RRDBNet
    from dexarchs.srvgg_arch import SRVGGNetCompact

    def compact(strength):
        # Real-ESRGAN's -dn: strength × the denoising weights + (1 − strength) × the weak-denoise ones.
        base = load(weights / "realesr-general-x4v3.pth", "params")
        weak = load(weights / "realesr-general-wdn-x4v3.pth", "params")
        net = SRVGGNetCompact(num_in_ch=3, num_out_ch=3, num_feat=64, num_conv=32, upscale=4, act_type="prelu")
        net.load_state_dict({k: strength * base[k] + (1 - strength) * weak[k] for k in base})
        return Upscaler(net)

    def rrdb(file, blocks):
        net = RRDBNet(num_in_ch=3, num_out_ch=3, num_feat=64, num_block=blocks, num_grow_ch=32, scale=4)
        net.load_state_dict(load(weights / file, "params_ema"))
        return Upscaler(net)

    def gfpgan():
        net = GFPGANv1Clean(out_size=512, num_style_feat=512, channel_multiplier=2, decoder_load_path=None,
                            fix_decoder=False, num_mlp=8, input_is_latent=True, different_w=True, narrow=1,
                            sft_half=True)
        net.load_state_dict(load(weights / "GFPGANv1.4.pth", "params_ema"))
        return FaceRestorer(net)

    # name, module, tile size, maths precision, 8-bit weights
    return [
        ("dex-fast-low", compact(0.0), TILE, ct.precision.FLOAT16, False),
        ("dex-fast-medium", compact(0.5), TILE, ct.precision.FLOAT16, False),
        ("dex-fast-high", compact(1.0), TILE, ct.precision.FLOAT16, False),
        ("dex-best", rrdb("RealESRGAN_x4plus.pth", 23), TILE, ct.precision.FLOAT16, True),
        ("dex-anime", rrdb("RealESRGAN_x4plus_anime_6B.pth", 6), TILE, ct.precision.FLOAT16, True),
        # StyleGAN2 overflows in float16 (13 dB); float32 maths with 8-bit weights is 40 dB at a quarter the size.
        ("dex-faces", gfpgan(), 512, ct.precision.FLOAT32, True),
    ]


def convert(module, size, precision, quantize):
    with torch.no_grad():
        traced = torch.jit.trace(module, torch.rand(1, 3, size, size))
    model = ct.convert(
        traced,
        inputs=[ct.ImageType(name="image", shape=(1, 3, size, size), scale=1 / 255, color_layout=ct.colorlayout.RGB)],
        outputs=[ct.ImageType(name="output", color_layout=ct.colorlayout.RGB)],
        compute_precision=precision,
        minimum_deployment_target=ct.target.macOS15,
    )
    if quantize:
        config = cto.OptimizationConfig(global_config=cto.OpLinearQuantizerConfig(
            mode="linear_symmetric", dtype="int8", granularity="per_channel"))
        model = cto.linear_quantize_weights(model, config)
    return model


def psnr(module, model, size):
    yy, xx = np.mgrid[0:size, 0:size]
    image = np.stack([xx * 255 / size, yy * 255 / size, (xx + yy) * 127 / size], -1).astype(np.uint8)
    with torch.no_grad():
        expected = module(torch.from_numpy(image).permute(2, 0, 1)[None].float() / 255)[0].permute(1, 2, 0).numpy()
    actual = np.array(model.predict({"image": Image.fromarray(image)})["output"])[..., :3]
    mse = np.mean((np.clip(expected, 0, 255).round() - actual.astype(np.float64)) ** 2)
    return 99.0 if mse == 0 else 10 * np.log10(255 ** 2 / mse)


def check_batch_one(weights):
    """The batch-1 rewrite gives exactly upstream's result."""
    from dexarchs.gfpganv1_clean_arch import GFPGANv1Clean as Ours
    from upstreamarchs.gfpganv1_clean_arch import GFPGANv1Clean as Theirs
    kwargs = dict(out_size=512, num_style_feat=512, channel_multiplier=2, decoder_load_path=None, fix_decoder=False,
                  num_mlp=8, input_is_latent=True, different_w=True, narrow=1, sft_half=True)
    state = load(weights / "GFPGANv1.4.pth", "params_ema")
    ours, theirs = Ours(**kwargs).eval(), Theirs(**kwargs).eval()
    ours.load_state_dict(state)
    theirs.load_state_dict(state)
    face = torch.rand(1, 3, 512, 512) * 2 - 1
    with torch.no_grad():
        diff = (ours(face, return_rgb=False, randomize_noise=False)[0]
                - theirs(face, return_rgb=False, randomize_noise=False)[0]).abs().max()
    assert float(diff) < 1e-4, f"batch-1 rewrite differs from upstream by {float(diff)}"


if __name__ == "__main__":
    weights = prepare()
    check_batch_one(weights)
    release = WORK / "release"
    release.mkdir(exist_ok=True)
    for name, module, size, precision, quantize in models(weights):
        model = convert(module, size, precision, quantize)
        package = release / f"{name}.mlpackage"
        shutil.rmtree(package, ignore_errors=True)
        model.save(str(package))
        quality = psnr(module, ct.models.MLModel(str(package)), size)
        assert quality > 38, f"{name}: Core ML differs from PyTorch ({quality:.1f} dB)"
        archive = release / f"{name}.mlpackage.zip"
        archive.unlink(missing_ok=True)
        subprocess.run(["ditto", "-c", "-k", "--keepParent", str(package), str(archive)], check=True)
        shutil.rmtree(package)
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        print(f"{name}: {archive.stat().st_size} bytes, sha256 {digest}, {quality:.1f} dB", flush=True)
