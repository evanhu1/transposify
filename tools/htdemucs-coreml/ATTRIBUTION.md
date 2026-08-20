# Attribution

The Core ML model produced by this repository is a converted form of
**Hybrid Transformer Demucs (HTDemucs)** by Meta AI / Meta Platforms, Inc.

When you ship the resulting `.mlpackage` in an application, you must keep the
following attribution available to users (e.g., in an "About" / "Legal"
screen, in your privacy policy, or in a `THIRD_PARTY_LICENSES` file):

---

> This product uses Hybrid Transformer Demucs by Meta Platforms, Inc.,
> licensed under the MIT License.
>
> Source: https://github.com/facebookresearch/demucs
>
> Reference papers:
>   - Défossez, A. (2021). *Hybrid Spectrogram and Waveform Source Separation.*
>     Proceedings of the ISMIR 2021 Workshop on Music Source Separation.
>   - Rouard, S., Massa, F., & Défossez, A. (2023).
>     *Hybrid Transformers for Music Source Separation.* ICASSP 2023.

---

## Demucs upstream license

```
MIT License

Copyright (c) Meta Platforms, Inc. and affiliates.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THE SOFTWARE.
```

The pre-trained HTDemucs weights are released under the same MIT license by
Meta and are downloaded automatically by the `demucs` Python package the
first time `convert.py` runs.

## Not affiliated

This repository is an independent open-source project. It is **not
affiliated with, endorsed by, or sponsored by Apple, Meta, or the Demucs
authors**. Apple, Core ML, the Neural Engine, and any other Apple
trademarks are property of Apple Inc. and used here for descriptive
purposes only.
