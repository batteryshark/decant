# Checked WhiskyKit overlay

`whiskykit-beta3-v1.patch` is a GPL-3.0 source patch against the exact kit commit in
`Sources/decant/Resources/RuntimePins.json`. It retains Whisky's notices and adds
beta3 selection/ownership policy and temporary-fixture coverage. Public payload
authenticity verification is unchanged and remains required.

Use `python3 scripts/prepare.py [-c release]` for builds. The same preparation
context is used by `install-app.sh`, `isolated-cli.py`, and `check-pair.py`.
It checks a pristine vendor, exact patch and all five immutable fork sources,
checks/builds the DLL, applies the patch, and reverses only that patch in `finally`.
A dirty vendor or identity mismatch is an error; no reset/clean is performed.
Build-only paths do not run tests; the full pair gate runs both test layers.

The standalone shim comes from the owned source fork referenced in the single
pair manifest. GCC 16.2 / mingw-w64 14 produces the reviewed builtin AMD64 DLL;
source cache and generated resource are ignored. A checked cache avoids repeated
downloads/compilation. No Apple payload is distributed. D3DMetal is user-supplied.
The original runtime beta2 shim is preserved; beta3 uses its separate resource.
