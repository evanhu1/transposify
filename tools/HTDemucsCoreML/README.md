# Vendored HTDemucs Core ML converter

This directory pins the conversion source used for Transposify's `model-v1`.
It was vendored without functional changes from
[`dexxdean/htdemucs-coreml`](https://github.com/dexxdean/htdemucs-coreml) at
commit `d6fe735f2c485f88cce9db123f4bacc3a9d3f02a`.

The converter is MIT-licensed; see `LICENSE`. `ATTRIBUTION.md` contains the
upstream HTDemucs attribution and license notice.

`requirements.lock` pins the complete Python dependency graph and hashes every
accepted distribution. `install-model.sh` also pins Python 3.11.15, installs
from that lock with hash verification, and supplies the exact `model-v1`
HTDemucs checkpoint from the GitHub release, also by SHA-256. A rebuild
therefore does not depend on the converter repository or Meta's model CDN
remaining unchanged or available.

To intentionally update the toolchain, edit `requirements.in`, regenerate the
lock on Apple Silicon using the command documented there, run a clean
conversion, and validate the resulting model before publishing a new model
version. Do not replace `model-v1` in place.
