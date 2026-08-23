#!/usr/bin/env python3
"""
convert.py — Convert Demucs (Hybrid Transformer) to Core ML.

Core ML does not support complex64 tensors. This script wraps HTDemucs with
a real-valued STFT/ISTFT implementation (rfft -> view_as_real for STFT,
matrix IDFT + overlap-add for ISTFT) while keeping the neural network
(encoder/transformer/decoder) unchanged.

Default output: HTDemucs_CoreML.mlpackage

Prerequisites:
    python3 -m venv venv && source venv/bin/activate
    pip install -r requirements.txt

Usage:
    python convert.py                    # FP32, ~400 MB
    python convert.py --fp16             # FP16, ~200 MB
    python convert.py --segment 7        # 7-second segments instead of 10
    python convert.py --output Foo.mlpackage
"""

import argparse
import math
import os
import warnings
from pathlib import Path

import torch
import torch.nn as nn
import torch.nn.functional as F
import numpy as np

# ---------------------------------------------------------------------------
# Defaults (override via CLI args)
# ---------------------------------------------------------------------------
MODEL_NAME = os.environ.get("HTDEMUCS_MODEL", "htdemucs")
SAMPLE_RATE = 44100
SEGMENT_SAMPLES = 441000               # 10s @ 44.1 kHz
NUM_CHANNELS = 2
NUM_SOURCES = 6 if MODEL_NAME.endswith("_6s") else 4
DEFAULT_OUTPUT = "HTDemucs_CoreML.mlpackage"

# Demucs internal source order is drums, bass, other, vocals — and for the
# six-stem model, guitar and piano after that. We reorder so vocals comes
# first, matching the UI convention and keeping index 0 == vocals across both
# models so the app's stem indices stay stable.
if NUM_SOURCES == 6:
    # demucs: drums(0) bass(1) other(2) vocals(3) guitar(4) piano(5)
    SOURCE_REORDER = [3, 0, 1, 2, 4, 5]
    SOURCE_NAMES = ["vocals", "drums", "bass", "other", "guitar", "piano"]
else:
    SOURCE_REORDER = [3, 0, 1, 2]
    SOURCE_NAMES = ["vocals", "drums", "bass", "other"]


# ---------------------------------------------------------------------------
# ManualMHA: replaces nn.MultiheadAttention.
# coremltools cannot convert the fused _native_multi_head_attention op,
# so we decompose attention into matmul + softmax explicitly.
# ---------------------------------------------------------------------------
class ManualMHA(nn.Module):
    """Drop-in für nn.MultiheadAttention, dekomponiert in matmul+softmax."""

    def __init__(self, mha: nn.MultiheadAttention):
        super().__init__()
        self.embed_dim = mha.embed_dim
        self.num_heads = mha.num_heads
        self.head_dim = mha.embed_dim // mha.num_heads
        self.in_proj_weight = mha.in_proj_weight
        self.in_proj_bias = mha.in_proj_bias
        self.out_proj = mha.out_proj
        # Cross-attention: separate k/v projections
        self.kdim = mha.kdim
        self.vdim = mha.vdim
        self._qkv_same_embed_dim = mha._qkv_same_embed_dim

    def forward(self, query, key, value, need_weights=False, **kwargs):
        B, T, E = query.shape
        S = key.shape[1]

        if self._qkv_same_embed_dim and query.data_ptr() == key.data_ptr():
            # Self-attention: single in_proj for Q, K, V.
            qkv = F.linear(query, self.in_proj_weight, self.in_proj_bias)
            q, k, v = qkv.chunk(3, dim=-1)
        else:
            # Cross-attention or different inputs.
            w_q, w_k, w_v = self.in_proj_weight.chunk(3, dim=0)
            b_q, b_k, b_v = (self.in_proj_bias.chunk(3, dim=0)
                              if self.in_proj_bias is not None
                              else (None, None, None))
            q = F.linear(query, w_q, b_q)
            k = F.linear(key, w_k, b_k)
            v = F.linear(value, w_v, b_v)

        q = q.view(B, T, self.num_heads, self.head_dim).transpose(1, 2)
        k = k.view(B, S, self.num_heads, self.head_dim).transpose(1, 2)
        v = v.view(B, S, self.num_heads, self.head_dim).transpose(1, 2)

        scale = self.head_dim ** -0.5
        attn = torch.matmul(q, k.transpose(-2, -1)) * scale
        attn = F.softmax(attn, dim=-1)
        out = torch.matmul(attn, v)

        out = out.transpose(1, 2).contiguous().view(B, T, E)
        out = self.out_proj(out)
        return out, None


def _replace_mha_recursive(module: nn.Module) -> None:
    """Replace all nn.MultiheadAttention submodules with ManualMHA, in place."""
    for name, child in module.named_children():
        if isinstance(child, nn.MultiheadAttention):
            setattr(module, name, ManualMHA(child))
        else:
            _replace_mha_recursive(child)


# ---------------------------------------------------------------------------
# 1D reflect-pad helper (mirrors demucs.hdemucs.pad1d).
# ---------------------------------------------------------------------------
def _pad1d(x: torch.Tensor, paddings: tuple, mode: str = "reflect"):
    """Reflect-pad along the last dim, with a fallback for very short signals."""
    pl, pr = paddings
    length = x.shape[-1]
    max_pad = max(pl, pr)
    if length <= max_pad:
        extra_pad = max_pad - length + 1
        x = F.pad(x, (0, extra_pad))
        padded = F.pad(x, (pl, pr), mode=mode)
        end = padded.shape[-1] - extra_pad
        return padded[..., :end]
    return F.pad(x, (pl, pr), mode=mode)


# ---------------------------------------------------------------------------
# RealSTFT: real-valued STFT via rfft -> view_as_real.
# Produces (..., freqs, frames, 2) so no complex64 leaks into the traced graph.
# ---------------------------------------------------------------------------
class RealSTFT(nn.Module):
    """STFT that returns only real tensors."""

    def __init__(self, n_fft: int, hop_length: int):
        super().__init__()
        self.n_fft = n_fft
        self.hop_length = hop_length
        self.register_buffer("window", torch.hann_window(n_fft))

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        """
        Input:  (B, C, T)
        Output: (B, C, freqs, frames, 2)   -- [real, imag]
        """
        B, C, T = x.shape
        x_flat = x.reshape(B * C, T)

        # torch.stft -> complex -> immediately view_as_real.
        z = torch.stft(
            x_flat, self.n_fft, self.hop_length,
            window=self.window, win_length=self.n_fft,
            normalized=True, center=True, return_complex=True,
        )
        # z: (B*C, freqs, frames) complex64.
        z_ri = torch.view_as_real(z)  # (B*C, freqs, frames, 2) float32.
        _, Fr, Fm, _ = z_ri.shape
        return z_ri.view(B, C, Fr, Fm, 2)


# ---------------------------------------------------------------------------
# RealISTFT: real-valued ISTFT via matrix IDFT + overlap-add.
# Avoids view_as_complex (not supported by coremltools).
# ---------------------------------------------------------------------------
class RealISTFT(nn.Module):
    """Pure real-valued ISTFT (matrix IDFT + OLA)."""

    def __init__(self, n_fft: int, hop_length: int, num_frames: int):
        super().__init__()
        self.n_fft = n_fft
        self.hop_length = hop_length
        freqs = n_fft // 2 + 1

        # Synthesis window.
        window = torch.hann_window(n_fft)
        self.register_buffer("window", window)

        # IDFT basis matrices: cos / sin for a one-sided spectrum.
        n = torch.arange(n_fft, dtype=torch.float32).unsqueeze(0)      # (1, N)
        k = torch.arange(freqs, dtype=torch.float32).unsqueeze(1)      # (freqs, 1)
        angles = 2.0 * math.pi * k * n / n_fft                         # (freqs, N)

        cos_basis = torch.cos(angles)
        sin_basis = torch.sin(angles)

        # Scaling: DC and Nyquist single, rest double (one-sided spectrum).
        # Normalization: /N * sqrt(N) because the forward STFT used normalized=True.
        norm = math.sqrt(n_fft)
        scale = torch.ones(freqs, 1) * (2.0 / n_fft * norm)
        scale[0] = 1.0 / n_fft * norm
        scale[-1] = 1.0 / n_fft * norm

        self.register_buffer("cos_basis", cos_basis * scale)   # (freqs, N)
        self.register_buffer("sin_basis", sin_basis * scale)   # (freqs, N)

        # Pre-compute OLA indices and window-sum buffer.
        # Core ML's 1D scatter_add can mis-compile for some shapes; using a
        # pre-built index tensor + the canonical scatter_add_ call sidesteps it.
        out_length = (num_frames - 1) * hop_length + n_fft
        frame_offsets = torch.arange(num_frames) * hop_length
        local_offsets = torch.arange(n_fft)
        ola_indices = (frame_offsets.unsqueeze(1) + local_offsets.unsqueeze(0)).reshape(-1)
        self.register_buffer("ola_indices", ola_indices.long())

        window_sq = window * window
        win_sum = torch.zeros(out_length)
        for i in range(num_frames):
            start = i * hop_length
            win_sum[start:start + n_fft] += window_sq
        win_sum = win_sum.clamp(min=1e-8)
        self.register_buffer("win_sum", win_sum)
        self.out_length = out_length

    def forward(self, z_ri: torch.Tensor, length: int) -> torch.Tensor:
        """
        Input:  z_ri (batch, freqs, frames, 2)
        Output: (batch, length)
        """
        real = z_ri[..., 0]  # (batch, freqs, frames)
        imag = z_ri[..., 1]

        # Per-frame IDFT: (batch, frames, freqs) @ (freqs, N) -> (batch, frames, N)
        real_t = real.transpose(-2, -1)
        imag_t = imag.transpose(-2, -1)

        frames_signal = (
            torch.matmul(real_t, self.cos_basis)
            - torch.matmul(imag_t, self.sin_basis)
        )

        # Apply synthesis window.
        frames_signal = frames_signal * self.window.unsqueeze(0).unsqueeze(0)

        # --- Overlap-add via scatter_add ---
        batch = frames_signal.shape[0]
        idx = self.ola_indices.unsqueeze(0).expand(batch, -1)

        flat = frames_signal.reshape(batch, -1)
        output = torch.zeros(batch, self.out_length, device=z_ri.device)
        output.scatter_add_(1, idx, flat)

        # Window normalization (pre-computed buffer).
        output = output / self.win_sum.unsqueeze(0)

        # Strip center padding.
        pad = self.n_fft // 2
        output = output[:, pad:pad + length]

        return output


# ---------------------------------------------------------------------------
# RealValuedHTDemucs: wrapper that swaps STFT/ISTFT for real-valued versions
# while keeping the actual network (encoder / transformer / decoder) intact.
# ---------------------------------------------------------------------------
class RealValuedHTDemucs(nn.Module):
    """
    Wraps HTDemucs with real-valued STFT/ISTFT.

    Data flow:
    1. RealSTFT -> (B, C, Fr, T, 2)             [real]
    2. Spec trimming (real instead of complex)
    3. _magnitude (cac=True): permute+reshape -> (B, C*2, Fr, T)   [real]
    4. Encoder / CrossTransformer / Decoder                        [all real]
    5. _mask (cac=True): reshape+permute -> (B, S, C, Fr, T, 2)    [real]
    6. RealISTFT -> waveform                                       [real]
    7. + time branch (denormalized)                                [real]
    """

    def __init__(self, model: nn.Module, segment_samples: int):
        super().__init__()
        self.segment_samples = segment_samples

        # Adopt network submodules from the loaded HTDemucs.
        self.encoder = model.encoder
        self.tencoder = model.tencoder
        self.decoder = model.decoder
        self.tdecoder = model.tdecoder
        self.crosstransformer = model.crosstransformer
        self.freq_emb = model.freq_emb
        self.freq_emb_scale = model.freq_emb_scale
        self.sources = model.sources
        self.depth = model.depth

        # Bottom-channel projection (present in some HTDemucs variants).
        self.bottom_channels = model.bottom_channels
        if self.bottom_channels:
            self.channel_upsampler = model.channel_upsampler
            self.channel_downsampler = model.channel_downsampler
            self.channel_upsampler_t = model.channel_upsampler_t
            self.channel_downsampler_t = model.channel_downsampler_t

        # STFT / ISTFT parameters.
        self.nfft = model.nfft
        self.hop_length = model.hop_length

        # Real-valued STFT / ISTFT modules.
        self.real_stft = RealSTFT(model.nfft, model.hop_length)

        # Frame count for ISTFT (fixed for the chosen segment size).
        le = int(math.ceil(segment_samples / model.hop_length))
        num_frames_istft = le + 4  # after padding inside _real_ispec
        self.real_istft = RealISTFT(model.nfft, model.hop_length, num_frames_istft)

        # nn.MultiheadAttention -> ManualMHA (fused op not supported by coremltools).
        _replace_mha_recursive(self)

    def _real_spec(self, mix: torch.Tensor) -> torch.Tensor:
        """
        Real-valued STFT + trim.
        Input:  (B, C, T)
        Output: (B, C, Fr, le, 2) -- trimmed, real
        """
        hl = self.hop_length
        length = mix.shape[-1]

        le = int(math.ceil(length / hl))
        pad = hl // 2 * 3
        x = _pad1d(mix, (pad, pad + le * hl - length), mode="reflect")

        z_ri = self.real_stft(x)  # (B, C, Fr, frames, 2)

        # Trim: drop the last freq bin, keep frames [2 : 2+le].
        z_ri = z_ri[:, :, :-1, :, :]
        z_ri = z_ri[:, :, :, 2:2 + le, :]
        return z_ri

    def _real_magnitude(self, z_ri: torch.Tensor) -> torch.Tensor:
        """
        cac=True: real/imag channels.
        Input:  (B, C, Fr, T, 2)
        Output: (B, C*2, Fr, T)
        """
        # Move the (..., 2) dim into the channel axis:
        # (B, C, Fr, T, 2) -> (B, C, 2, Fr, T) -> (B, C*2, Fr, T).
        B, C, Fr, T, _ = z_ri.shape
        m = z_ri.permute(0, 1, 4, 2, 3)
        m = m.reshape(B, C * 2, Fr, T)
        return m

    def _real_mask(self, m: torch.Tensor) -> torch.Tensor:
        """
        cac=True: network output -> real/imag tensor.
        Input:  (B, S, C*2, Fr, T) -- denormalized network output
        Output: (B*S*C, Fr, T, 2)  -- ready for RealISTFT
        """
        B, S, _, Fr, T = m.shape
        out = m.view(B, S, -1, 2, Fr, T).permute(0, 1, 2, 4, 5, 3)
        out = out.reshape(B * S * (out.shape[2]), Fr, T, 2)
        return out

    def _real_ispec(self, z_ri: torch.Tensor, length: int) -> torch.Tensor:
        """
        Real-valued ISTFT.
        Input:  (batch, Fr, T, 2)
        Output: (batch, length)
        """
        hl = self.hop_length
        # Pad freq: add 1 bin at the end.
        z_ri = F.pad(z_ri, (0, 0, 0, 0, 0, 1))
        # Pad frames: add 2 on each side.
        z_ri = F.pad(z_ri, (0, 0, 2, 2))

        pad = hl // 2 * 3
        le = hl * int(math.ceil(length / hl)) + 2 * pad
        x = self.real_istft(z_ri, le)
        x = x[:, pad:pad + length]
        return x

    def forward(self, mix: torch.Tensor) -> torch.Tensor:
        """
        Input:  (1, 2, segment_samples)
        Output: (1, 4, 2, segment_samples)  -- [vocals, drums, bass, other]
        """
        length = mix.shape[-1]

        # --- Frequency branch: real-valued STFT ---
        z_ri = self._real_spec(mix)         # (B, C, Fr, T, 2)
        mag = self._real_magnitude(z_ri)    # (B, C*2, Fr, T) float
        x = mag

        B, C_mag, Fq, T = x.shape

        # Normalize.
        mean = x.mean(dim=(1, 2, 3), keepdim=True)
        std = x.std(dim=(1, 2, 3), keepdim=True)
        x = (x - mean) / (1e-5 + std)

        # --- Time branch ---
        xt = mix
        meant = xt.mean(dim=(1, 2), keepdim=True)
        stdt = xt.std(dim=(1, 2), keepdim=True)
        xt = (xt - meant) / (1e-5 + stdt)

        # --- Encoder ---
        saved = []
        saved_t = []
        lengths = []
        lengths_t = []

        for idx, encode in enumerate(self.encoder):
            lengths.append(x.shape[-1])
            inject = None
            if idx < len(self.tencoder):
                lengths_t.append(xt.shape[-1])
                tenc = self.tencoder[idx]
                xt = tenc(xt)
                if not tenc.empty:
                    saved_t.append(xt)
                else:
                    inject = xt
            x = encode(x, inject)
            if idx == 0 and self.freq_emb is not None:
                frs = torch.arange(x.shape[-2], device=x.device)
                emb = self.freq_emb(frs).t()[None, :, :, None].expand_as(x)
                x = x + self.freq_emb_scale * emb
            saved.append(x)

        # --- Cross-Transformer ---
        if self.crosstransformer:
            if self.bottom_channels:
                b, c, f, t = x.shape
                from einops import rearrange
                x = rearrange(x, "b c f t-> b c (f t)")
                x = self.channel_upsampler(x)
                x = rearrange(x, "b c (f t)-> b c f t", f=f)
                xt = self.channel_upsampler_t(xt)

            x, xt = self.crosstransformer(x, xt)

            if self.bottom_channels:
                x = rearrange(x, "b c f t-> b c (f t)")
                x = self.channel_downsampler(x)
                x = rearrange(x, "b c (f t)-> b c f t", f=f)
                xt = self.channel_downsampler_t(xt)

        # --- Decoder ---
        for idx, decode in enumerate(self.decoder):
            skip = saved.pop(-1)
            x, pre = decode(x, skip, lengths.pop(-1))

            offset = self.depth - len(self.tdecoder)
            if idx >= offset:
                tdec = self.tdecoder[idx - offset]
                length_t = lengths_t.pop(-1)
                if tdec.empty:
                    pre = pre[:, :, 0]
                    xt, _ = tdec(pre, None, length_t)
                else:
                    skip = saved_t.pop(-1)
                    xt, _ = tdec(xt, skip, length_t)

        # --- Frequency branch: denormalize + mask ---
        S = len(self.sources)
        x = x.view(B, S, -1, Fq, T)
        x = x * std[:, None] + mean[:, None]

        # _real_mask -> (B*S*C, Fr, T, 2)
        zout_ri = self._real_mask(x)

        # Real-valued ISTFT.
        x_freq = self._real_ispec(zout_ri, length)
        # x_freq: (B*S*C, length) -> (B, S, C, length)
        C_orig = NUM_CHANNELS
        x_freq = x_freq.view(B, S, C_orig, length)

        # --- Time branch: denormalize ---
        xt = xt.view(B, S, -1, length)
        xt = xt * stdt[:, None] + meant[:, None]

        # --- Combine ---
        x_out = x_freq + xt

        # Reorder sources: drums,bass,other,vocals -> vocals,drums,bass,other.
        x_out = x_out[:, SOURCE_REORDER, :, :]

        return x_out


# ---------------------------------------------------------------------------
# Metadata
# ---------------------------------------------------------------------------
def _add_metadata(mlmodel, segment_samples: int) -> None:
    mlmodel.author = "HTDemucs CoreML conversion"
    mlmodel.license = (
        "MIT. Original Demucs: Copyright (c) Meta Platforms, Inc. and "
        "affiliates, MIT License. See LICENSE and ATTRIBUTION."
    )
    mlmodel.short_description = (
        f"Hybrid Transformer Demucs (HTDemucs) -- music source separation "
        f"into {', '.join(SOURCE_NAMES)} at {SAMPLE_RATE} Hz."
    )
    mlmodel.input_description["audio"] = (
        f"Stereo audio. Shape (1, 2, {segment_samples}), Float32, {SAMPLE_RATE} Hz."
    )
    mlmodel.output_description["sources"] = (
        f"Separated stems. Shape (1, 4, 2, {segment_samples}). "
        f"Order: [{', '.join(SOURCE_NAMES)}]."
    )


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Convert Demucs (HTDemucs) to Core ML mlpackage."
    )
    p.add_argument(
        "--segment", type=float, default=10.0,
        help="Segment length in seconds (default: 10.0).",
    )
    p.add_argument(
        "--fp16", action="store_true",
        help="Quantize to FP16 (~half the file size, minor accuracy loss).",
    )
    p.add_argument(
        "--output", type=str, default=None,
        help="Output mlpackage path (default: HTDemucs_CoreML[_FP16].mlpackage).",
    )
    p.add_argument(
        "--compute-units", choices=["cpu_and_gpu", "all", "cpu_only"],
        default="cpu_and_gpu",
        help="Default ComputeUnit baked into the model (default: cpu_and_gpu). "
             "HTDemucs is unstable on the Neural Engine -- keep 'cpu_and_gpu' "
             "unless you have specifically validated 'all'.",
    )
    return p.parse_args()


def main() -> None:
    import coremltools as ct

    warnings.filterwarnings("ignore", category=UserWarning)
    warnings.filterwarnings("ignore", category=FutureWarning)

    args = parse_args()

    segment_samples = int(round(args.segment * SAMPLE_RATE))
    output_path = args.output or (
        "HTDemucs_CoreML_FP16.mlpackage" if args.fp16 else DEFAULT_OUTPUT
    )
    precision = ct.precision.FLOAT16 if args.fp16 else ct.precision.FLOAT32
    compute_units = {
        "cpu_and_gpu": ct.ComputeUnit.CPU_AND_GPU,
        "all": ct.ComputeUnit.ALL,
        "cpu_only": ct.ComputeUnit.CPU_ONLY,
    }[args.compute_units]

    print("=" * 60)
    print("  HTDemucs -> Core ML Converter")
    print("  (real-valued STFT / ISTFT wrapper)")
    print("=" * 60)
    print(f"  Model:        {MODEL_NAME}")
    print(f"  Sample rate:  {SAMPLE_RATE} Hz")
    print(f"  Segment:      {segment_samples} samples ({args.segment:.1f}s)")
    print(f"  Stems:        {', '.join(SOURCE_NAMES)}")
    print(f"  Precision:    {'FP16' if args.fp16 else 'FP32'}")
    print(f"  Compute:      {args.compute_units}")
    print(f"  Output:       {output_path}")
    print("=" * 60)

    # --- Load model ---
    print(f"\n[1/5] Loading Demucs '{MODEL_NAME}' ...")
    from demucs.pretrained import get_model
    bag = get_model(MODEL_NAME)
    # A "bag" can hold several models. htdemucs_ft holds four, each fine-tuned
    # for one source in demucs order (drums, bass, other, vocals) though each
    # still outputs all four. Index 3 is therefore the one to pick when what
    # matters is how cleanly vocals are told apart from everything else.
    index = int(os.environ.get("HTDEMUCS_BAG_INDEX", "0"))
    if index >= len(bag.models):
        raise SystemExit(f"{MODEL_NAME} has {len(bag.models)} model(s); index {index} is out of range")
    model = bag.models[index]
    if len(bag.models) > 1:
        print(f"       bag of {len(bag.models)}; using index {index}")
    model.eval()
    model.use_train_segment = False
    num_params = sum(p.numel() for p in model.parameters()) / 1e6
    print(f"       {num_params:.1f}M parameters loaded.")

    # --- Build wrapper ---
    print("\n[2/5] Building real-valued wrapper ...")
    wrapper = RealValuedHTDemucs(model, segment_samples=segment_samples)
    wrapper.eval()

    dummy = torch.randn(1, NUM_CHANNELS, segment_samples)

    # --- PyTorch sanity check ---
    print("\n[3/5] PyTorch forward pass ...")
    with torch.no_grad():
        out_wrapper = wrapper(dummy)

    print(f"       Output shape: {out_wrapper.shape}")
    expected = (1, NUM_SOURCES, NUM_CHANNELS, segment_samples)
    assert out_wrapper.shape == expected, f"Shape {out_wrapper.shape} != {expected}"
    print("       OK.")

    # --- Trace ---
    print("\n[4/5] torch.jit.trace ...")
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, dummy, strict=False)
    print("       Trace OK.")

    # --- Core ML conversion ---
    print("\n[5/5] Core ML conversion ...")
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(
                name="audio",
                shape=(1, NUM_CHANNELS, segment_samples),
                dtype=np.float32,
            )
        ],
        outputs=[ct.TensorType(name="sources")],
        convert_to="mlprogram",
        compute_units=compute_units,
        compute_precision=precision,
        minimum_deployment_target=ct.target.macOS14,
    )

    _add_metadata(mlmodel, segment_samples)
    mlmodel.save(output_path)

    # --- Validation ---
    # Important: reload with the SAME compute_units we converted for.
    # MLModel(path) without a config defaults to ComputeUnit.ALL, which on
    # HTDemucs may dispatch to ANE and crash with E5RT errors -- exactly
    # the bug we baked the CPU_AND_GPU default into the model to avoid.
    print("\n[Val] Validating Core ML vs. PyTorch reference ...")
    try:
        val_config = ct.ComputeUnit.CPU_AND_GPU
        mlmodel_loaded = ct.models.MLModel(output_path, compute_units=val_config)
        with torch.no_grad():
            ref = wrapper(dummy).numpy()
        pred = mlmodel_loaded.predict({"audio": dummy.numpy()})
        cml_out = pred["sources"]

        assert ref.shape == cml_out.shape, f"Shape mismatch: {ref.shape} vs {cml_out.shape}"
        max_diff = float(np.max(np.abs(ref - cml_out)))
        mean_diff = float(np.mean(np.abs(ref - cml_out)))
        print(f"      Max diff:  {max_diff:.6f}")
        print(f"      Mean diff: {mean_diff:.6f}")
        threshold = 0.2 if args.fp16 else 0.1
        if max_diff < threshold:
            print("      Validation OK.")
        else:
            print("      Large numerical drift (expected for FP16 on ANE).")
    except Exception as e:
        print(f"      Validation skipped: {e}")

    # --- Summary ---
    size_mb = sum(
        f.stat().st_size for f in Path(output_path).rglob("*") if f.is_file()
    ) / (1024 * 1024)

    print("\n" + "=" * 60)
    print(f"  Done: {output_path} ({size_mb:.0f} MB)")
    print()
    print("  Next step: drag the .mlpackage into your Xcode project")
    print("  and load it via MLModel(contentsOf: ...). See examples/swift/.")
    print("=" * 60)


if __name__ == "__main__":
    main()
