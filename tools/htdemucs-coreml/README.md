# Vendored HTDemucs Core ML converter

This directory pins the conversion source behind Transposify's separation
model. It was vendored without functional changes from
[`dexxdean/htdemucs-coreml`](https://github.com/dexxdean/htdemucs-coreml) at
commit `d6fe735f2c485f88cce9db123f4bacc3a9d3f02a`, then parameterised by
`HTDEMUCS_MODEL` so it can convert the six-stem `htdemucs_6s` as well as the
original four-stem `htdemucs`.

The converter is MIT-licensed; see `LICENSE`. `ATTRIBUTION.md` carries the
upstream HTDemucs attribution and license notice. `CONVERSION_NOTES.md`
explains the three Core ML workarounds the converter needs.

## Why a rebuild is reproducible

`../model-requirements.txt` pins the complete Python dependency graph and
hashes every accepted distribution. `install-model.sh` pins Python 3.11,
installs from that lock with hash verification, and supplies the exact
HTDemucs checkpoint from this project's own `model-v1` release, verified by
SHA-256 before conversion. So a rebuild does not depend on the converter
repository or on Meta's model CDN staying available.

## Updating the toolchain on purpose

1. Edit `../model-requirements.in`.
2. Regenerate the lock on Apple Silicon:

   ```sh
   uv pip compile tools/model-requirements.in --generate-hashes \
       --python-version 3.11 --output-file tools/model-requirements.txt
   ```

3. Run a clean conversion (`./install-model.sh --force`) and validate the
   resulting model before publishing.
4. Publish under a new `model-vN` tag and update `SeparationModel.swift` with
   the new size and SHA-256. Never replace a published model version in place:
   the app pins the archive hash, and the window length and stem order are
   compiled into the model.
