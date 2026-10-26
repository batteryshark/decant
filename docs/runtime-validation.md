# Runtime validation

`Sources/decant/Resources/RuntimePins.json` defines the exact kit commit,
stable/prerelease tags, archive digests, plist versions and required backend
capabilities. Runtime and kit pins are never updated automatically.

## Validate a kit/runtime pair

Review the upstream kit and release metadata before changing the JSON or the
`vendor/Whisky` submodule commit. Obtain runtime archives from the exact official
release URLs and keep archives and Apple payloads outside the repository.

Run the checker for each channel with its matching archive:

```sh
python3 scripts/check-pair.py --channel stable --archive /path/to/stable/Libraries.tar.gz
python3 scripts/check-pair.py --channel prerelease --archive /path/to/beta/Libraries.tar.gz
```

The checker rejects a mismatched or dirty vendor, mismatched GitHub metadata or
digest, and missing or incompatible runtime plists, Wine binaries or 32/64-bit
backend payloads. It reads archives without installing them, then runs
Python/Swift fixture tests and a release build sequentially, with timeouts and
four Swift jobs. `DEVELOPER_DIR` selects Xcode and defaults to
`/Applications/Xcode.app/Contents/Developer`.

Use `--metadata-only` instead of `--archive` for a preflight; this does not validate
the archive. Static checks do not establish rendering or ABI compatibility.
Integration coverage should include install/reinstall identity, GPTK retention
and redeployment, 32/64-bit sysinfo and D3D11, DXVK and backend round trips.
D3DMetal interposer compatibility requires separate validation.

## Isolated integration CLI

```sh
python3 scripts/isolated-cli.py
```

This copies the package into a temporary directory, embeds a unique test bundle
ID, builds it, and verifies its Foundation support, bottle and log paths through
`runtime paths`. It prints the binary path and writes `isolation.json` beside the
temporary package. It does not install a runtime, create bottles or run Wine.
Changing `HOME` alone does not isolate these paths.

Use the printed binary for integration commands: install with `runtime update`
(or explicit `--prerelease`), inspect status, import an original local GPTK payload
and use diagnostic bottles. Stop diagnostic applications before replacing their
runtime. Retain the unique support/log paths for troubleshooting, then remove
those paths and the temporary package after diagnostic processes have exited.
