# Conversion notes — the three workarounds

This document explains the three non-trivial pieces in `convert.py`. Each one
is a Core ML / `coremltools` quirk that won't show up until you're already
several layers deep into a conversion attempt.

The same patterns apply to **any audio model** that uses STFT + Transformer
(MDX-Net, Spleeter, OpenUnmix, BS-RoFormer, …), so they're reusable beyond
HTDemucs.

---

## 1. `complex64` is not supported in Core ML

### Problem

`torch.stft(..., return_complex=True)` produces `complex64`. `coremltools`
cannot represent complex tensors, so any graph that carries them through
will fail to convert (or, worse, "convert" but produce nonsense).

The naive workaround — call `torch.view_as_real` once at the boundary —
breaks again the moment you need `torch.istft`, because `istft` requires a
complex input.

### Solution

Replace the entire STFT/ISTFT pair with **purely real-valued operations**
(`RealSTFT` and `RealISTFT` in `convert.py`).

**`RealSTFT`** is straightforward — keep `torch.stft` (still emits complex
internally) but immediately call `view_as_real` so the *traced graph* never
carries a complex tensor:

```python
z = torch.stft(x_flat, ..., return_complex=True)
z_ri = torch.view_as_real(z)   # (..., freqs, frames, 2)
```

**`RealISTFT`** is the harder half. We rebuild ISTFT from scratch using a
matrix-form IDFT plus an explicit overlap-add:

1. Pre-compute `cos`/`sin` basis matrices for a one-sided spectrum, with
   correct DC/Nyquist scaling and the `normalized=True` factor folded in.
2. Per-frame IDFT becomes a single `matmul`:
   `signal = real @ cos_basis - imag @ sin_basis`.
3. Apply the synthesis (Hann) window.
4. Overlap-add into an output buffer.
5. Divide by the pre-computed sum-of-squared-windows for correct
   reconstruction normalization.
6. Strip the `n_fft // 2` center padding.

This is more code than `torch.istft`, but it converts cleanly to Core ML
and has no `complex` operations anywhere.

### Why not use `coremltools`'s built-in STFT op?

`coremltools` has gained more audio ops over time, but as of writing:
- The op coverage for STFT/ISTFT around HTDemucs's specific window size,
  hop length, `normalized=True`, and `center=True` combination is brittle.
- HTDemucs's own STFT pre/post-processing (the `_pad1d` reflect padding,
  the `_spec` trim of the last freq bin, the `+2 / -2` frame trim) needs
  to be reproduced bit-for-bit. It's easier to keep the whole STFT
  pipeline as plain PyTorch tensor ops.

---

## 2. `nn.MultiheadAttention` cannot be traced

### Problem

`coremltools` can't convert `_native_multi_head_attention`, the fused C++
op that PyTorch dispatches to inside `nn.MultiheadAttention`. You'll get
something like:

```
PyTorch convert function for op '_native_multi_head_attention' not implemented.
```

### Solution

Replace every `nn.MultiheadAttention` instance with a hand-written
`ManualMHA` module that decomposes attention into the primitive ops
`coremltools` *does* support: `linear`, `matmul`, `softmax`.

The substitution is in-place via `_replace_mha_recursive`, which walks the
HTDemucs `crosstransformer` and swaps modules. This preserves all
pre-trained weights — `ManualMHA` uses the same `in_proj_weight`,
`in_proj_bias`, and `out_proj` tensors as the original module.

`ManualMHA` handles two cases:
- **Self-attention** (`query == key == value` by pointer equality):
  single `in_proj` then `chunk(3)`.
- **Cross-attention**: split the `in_proj` weight into Q/K/V slices and
  apply each linear separately.

Trade-off: a few percent slower than the fused op on CPU/GPU. Negligible
for the once-per-10-seconds inference cadence in stem separation.

---

## 3. Core ML's 1D `scatter_add` is fragile

### Problem

A natural way to write overlap-add inside an ISTFT is something like:

```python
output = torch.zeros(batch, out_length)
output.scatter_add_(1, ola_indices, frames_signal_flat)
```

`coremltools` *will* convert this, but for some shape/index combinations
the resulting Core ML graph mis-compiles silently — outputs come out
slightly wrong or full-on garbage on the GPU backend.

### Solution

Pre-compute the OLA index tensor **once at module init time** and store it
as a registered buffer:

```python
frame_offsets = torch.arange(num_frames) * hop_length
local_offsets = torch.arange(n_fft)
ola_indices = (frame_offsets.unsqueeze(1) + local_offsets.unsqueeze(0)).reshape(-1)
self.register_buffer("ola_indices", ola_indices.long())
```

At forward-time, `expand` it to the batch dimension and call the canonical
`scatter_add_` with constant indices. This sidesteps the buggy code path
because the indices are now part of the constant graph rather than a
runtime computation.

A pre-computed `win_sum` buffer (sum of squared windows over all frames)
takes care of normalization the same way — done once, not recomputed
inside the model.

This is why the converter's `RealISTFT.__init__` takes a fixed
`num_frames` parameter: the converter bakes a specific segment length
into the model. If you want a different segment length, re-run
`convert.py --segment N`.

---

## Compute units

`compute_units=ct.ComputeUnit.CPU_AND_GPU` is the default in `convert.py`
and the right choice for HTDemucs.

`ct.ComputeUnit.ALL` (which lets the runtime route ops to the **Apple
Neural Engine**) produces incorrect output on some HTDemucs shapes —
likely a mismatch between ANE's quantization assumptions and the
pre-/post-processing math around the network. The validation step at the
end of `convert.py` will report a large max-diff if this happens. Do not
ignore it.

If you really need ANE inference, you'd have to: split the model so that
only the encoder/transformer/decoder runs on ANE, and keep the STFT/ISTFT
on CPU/GPU. That's a larger restructure — out of scope for this repo.

---

## Validation step

After conversion, `convert.py` runs the same dummy input through both the
PyTorch wrapper and the saved Core ML model and reports max/mean
differences:

| Precision | Expected max diff | Threshold |
|---|---|---|
| FP32 | ~1e-4 to 1e-2 | < 0.1 |
| FP16 | ~1e-2 to 1e-1 | < 0.2 |

If you see drift larger than the threshold, something has gone wrong —
typically a `coremltools` version mismatch or an ANE routing bug.

---

## Reproducing on a fresh machine

```bash
python3 -m venv venv && source venv/bin/activate
pip install -r requirements.txt
python convert.py --fp16    # or default FP32
```

First run downloads ~300 MB of HTDemucs weights to `~/.cache/torch/hub/`.
Conversion takes 2–5 minutes on an Apple Silicon Mac with 16 GB RAM.

If `coremltools` complains about Python or `torch` versions, see the
pinned bounds in `requirements.txt`.
