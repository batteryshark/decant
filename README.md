<p align="center"><img src="assets/decant.svg" width="128" alt="decant logo"></p>

# decant

Run Windows programs on Apple Silicon Macs with Wine and Metal graphics.
`decant app.exe` runs the program in a default bottle and returns right away.

## Why this exists

On Linux you install Wine from your distro, right-click an `.exe`, and it runs.
Macs don't have that, for these reasons:

- **No distro packaging.** Homebrew disabled its `wine-stable` cask on 2026-09-01 because it
  fails Gatekeeper.
- **Gatekeeper and notarization.** Unsigned Wine builds get blocked or need workarounds.
- **No 32-bit processes on macOS.** Wine needs WoW64 to run 32-bit Windows programs inside
  64-bit processes. On Apple Silicon, all of it runs under Rosetta 2.
- **No native Vulkan.** Direct3D has to be translated to Metal by DXMT, D3DMetal, or DXVK
  over MoltenVK.
- **D3DMetal can't be redistributed.** Apple's license forbids it, so it has to be
  user-supplied.
- **The pieces are scattered.** Wine builds, the translation layers and the glue between
  them all come from different projects.

decant uses frankea/Whisky's runtime (Wine plus DXMT and DXVK-macOS) and its WhiskyKit
library. It adds only the convenience layer: runtime install, bottles, and a launch command
that returns immediately.

## Build

```sh
git submodule update --init      # vendor/Whisky at the pinned commit
python3 scripts/prepare.py -c release  # → .build/release/decant
```

Needs Swift 6, macOS 15+ and Rosetta 2.

## Usage

```sh
decant runtime update [--prerelease] [--force]   # install the reviewed pin, not latest
decant runtime status                         # local only; no download or Wine
decant runtime status --check [--prerelease]   # verify exact pin's public metadata
decant runtime import-gptk <dmg-or-dir>        # original local Apple download

decant app.exe [args...]              # run in bottle "Default", created on first use
decant setup.msi [args...]            # msiexec /i setup.msi [args...]
decant --bottle Games game.exe        # use, or create, bottle "Games"
decant --env WINEDEBUG=+loaddll app.exe

decant bottles list
decant bottles create NAME [--windows win11] [--backend dxvk]
decant bottles set NAME [--windows win7] [--backend wined3d]
```

### Finder

```sh
scripts/install-app.sh
```

This builds `Decant.app`, a small wrapper around the CLI with no windows, and installs it to
`~/Applications`. It then makes Decant your default app for `.exe` and `.msi`:

- Double-clicking a Windows program runs it in the Default bottle. "Open With" also works
  for `.bat` files.
- Right-click → Services → **Run in Bottle…** asks you to pick a bottle or type a new name.
- If decant fails, the error is shown in an alert.

The app is ad-hoc signed. Files you downloaded open without a Gatekeeper prompt.

To undo, delete the app and refresh the Services menu:

```sh
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u ~/Applications/Decant.app
rm -rf ~/Applications/Decant.app
/System/Library/CoreServices/pbs -update
```

macOS then falls back to other apps for `.exe` and `.msi`. To pick one, use Get Info →
Open with → Change All.

The stable runtime is installed on first launch if it's missing. Pre-release runtimes
(D3DMetal-capable) are only installed with `--prerelease`. Releases are exact reviewed
pins, not floating updates. Local status (including `--prerelease`) works offline;
only `--check` requests public metadata. Successful installs record the exact tag,
digest and kit commit in `Libraries/DecantRuntime.json`. An ordinary update retains
a checked prerelease; `--force` explicitly replaces it. Legacy stable installs remain
launchable, but need `--force` to establish a checked identity by reinstalling.
An untracked beta cannot be identified from its core plist version alone.

New bottles are a 64-bit prefix with WoW64, so 32-bit programs run too. They report
Windows 10 and use DXMT for D3D10/11. D3D9 and older stay on Wine's wined3d. DXMT's
32-bit DLLs go into `syswow64`, so 32-bit D3D11 programs get Metal as well.

### Optional D3DMetal

Supply your own original Apple Game Porting Toolkit DMG, mounted evaluation
environment, or `redist/lib` folder with `runtime import-gptk`. Images are mounted
readonly without browsing, including the outer toolkit's single top-level
evaluation-environment image. Payloads must pass WhiskyKit's Apple-signature
validation. No Apple binaries are distributed by decant.

The imported payload is stored outside the runtime, survives runtime reinstalls,
and is redeployed after installing a GPTK-capable runtime. An incapable runtime
keeps the import stored but undeployed. A redeploy failure is an error, not an
installation success. `runtime status` distinguishes stored, capable and deployed.

Use `bottles set NAME --backend d3dMetal` (or `dxmt`, `dxvk`, `wined3d`). An explicit
unavailable backend fails instead of silently falling back. Backend changes take
effect on the next launch, not in an already running program. Bottle listings show
requested and effective availability; per-program overrides can differ. Switching
restores only recognized runtime DLL copies; custom DLLs are preserved and a
conflicting replacement fails with advice to use a separate bottle.

## Files

The bundle ID `io.github.batteryshark.decant` is embedded in the binary from
`Resources/Info.plist`. It keys every path, so decant never touches a real Whisky install.

- Runtime: `~/Library/Application Support/io.github.batteryshark.decant/Libraries/`
- Bottles: `~/Library/Application Support/io.github.batteryshark.decant/Bottles/<name>/`
- Imported GPTK: `~/Library/Application Support/io.github.batteryshark.decant/D3DMetal/`
- Logs, one per launch: `~/Library/Logs/io.github.batteryshark.decant/`

`Sources/decant/WhiskyAdapter.swift` is the only file that imports WhiskyKit.
`Sources/DecantApp/main.swift` is the Finder wrapper. `assets/AppIcon.svg` is the source
for `assets/AppIcon.icns`.
`tests/` holds two small Windows programs, `sysinfo.c` and `d3d11test.c`, for checking a
runtime. Build them with `tests/build.sh`, which needs `zig`.

Non-Wine checks: `python3 scripts/check-pair.py --channel prerelease --metadata-only`.
This runs launcher tests, the pure temporary-fixture dependency policy suites, and a release build.
`UnitTests/` uses temporary fixtures and
does not install a runtime or touch real bottles. To additionally validate an
original Apple DMG readonly, set `DECANT_TEST_GPTK_PATH` to its local path when
running the tests. This does not import or deploy the payload.

## Paired kit/runtime review

`Sources/decant/Resources/RuntimePins.json` is the sole machine-readable pin source
for both CLI and checker: exact kit commit, stable/prerelease tag, archive digest,
plist version and required backend capabilities. The current stable is 3.1.1 and
the explicit prerelease is v4.6.4-beta.1 (whose plist says 4.6.4); both use the same
reviewed kit. No runtime/kit pin changes are discovered or installed automatically.

1. Review the upstream kit and release metadata. If changing kit, fetch and check
   out the chosen commit in `vendor/Whisky` only after confirming it is clean.
   Edit the JSON for the exact reviewed pairs; fix adapter/API changes as needed.
   Obtain original runtime archives from the exact official release URLs, outside
   the repo. Do not derive a digest from an unreviewed example.
2. Run this gate for **each channel**, using its matching local archive:
   ```sh
   python3 scripts/check-pair.py --channel stable --archive /path/to/stable/Libraries.tar.gz
   python3 scripts/check-pair.py --channel prerelease --archive /path/to/beta/Libraries.tar.gz
   ```
   It rejects a mismatched/dirty vendor, mismatched GitHub metadata or digest,
   missing/incompatible runtime plist, Wine binaries or 32/64-bit backend payloads.
   It reads the archive without installing, runs Python/Swift fixture tests and a
   release build sequentially, with timeouts and four Swift jobs. Xcode is selected
   through `DEVELOPER_DIR` (defaults to `/Applications/Xcode.app/Contents/Developer`).
   `--metadata-only` instead of `--archive` is a preflight, **not** an artifact gate.
3. Before accepting a changed pair, run isolated Wine integration (below), including
   install/reinstall identity, GPTK retention/redeploy, 32/64-bit sysinfo and D3D11,
   DXVK and backend round trips. Static checks do not establish rendering/ABI
   compatibility. D3DMetal interposer policy is a separate evidence-based review.
4. Review `git diff`, then stage the JSON, `vendor/Whisky` gitlink, adapter/tests and
   evidence-related changes together in **one local commit**. Never commit runtime
   archives or Apple payloads. The checker does not commit, install or push.

### Isolated integration CLI

```sh
python3 scripts/isolated-cli.py
```

This copies the package to a temporary directory, embeds a fresh unique test
bundle ID, builds it, and verifies its actual Foundation support/bottle/log paths
using `runtime paths`. It prints the binary and writes `isolation.json` beside the
temporary package. It does **not** install a runtime, create a bottle or run Wine.
Use **only that printed binary** for later authorized integration commands, never
the normal checkout CLI or Finder app. Changing `HOME` alone is not isolation.

After authorization, install with that binary's `runtime update` (or explicit
`--prerelease`), inspect status/identity, import the local original GPTK and use
diagnostic bottles. Stop only your own diagnostic apps before replacing their
runtime; never terminate the principal's Wine processes. Keep the printed unique
support/log paths with test evidence; clean up only those paths and the temporary
package once their diagnostic processes have exited.

## Credits and license

Built on [Wine](https://www.winehq.org), [Gcenx](https://github.com/Gcenx)'s macOS Wine
builds, [DXMT](https://github.com/3Shain/dxmt), [DXVK-macOS](https://github.com/Gcenx/DXVK-macOS),
[MoltenVK](https://github.com/KhronosGroup/MoltenVK) and
[frankea/Whisky](https://github.com/frankea/Whisky).

GPL-3.0-or-later, since decant links WhiskyKit. See `LICENSE`.
