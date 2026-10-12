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
swift build -c release           # → .build/release/decant
```

Needs Swift 6, macOS 15+ and Rosetta 2.

## Usage

```sh
decant runtime update [--prerelease] [--force]   # download, sha256-verify, install
decant runtime status [--prerelease]

decant app.exe [args...]              # run in bottle "Default", created on first use
decant setup.msi [args...]            # msiexec /i setup.msi [args...]
decant --bottle Games game.exe        # use, or create, bottle "Games"
decant --env WINEDEBUG=+loaddll app.exe

decant bottles list
decant bottles create NAME [--windows win11] [--backend dxvk]
decant bottles set NAME [--windows win7] [--backend wined3d]
```

The stable runtime is installed on first launch if it's missing. Pre-release runtimes
(D3DMetal-capable 4.x) are only installed with `--prerelease`.

New bottles are a 64-bit prefix with WoW64, so 32-bit programs run too. They report
Windows 10 and use DXMT for D3D10/11. D3D9 and older stay on Wine's wined3d. DXMT's
32-bit DLLs go into `syswow64`, so 32-bit D3D11 programs get Metal as well.

## Files

The bundle ID `io.github.batteryshark.decant` is embedded in the binary from
`Resources/Info.plist`. It keys every path, so decant never touches a real Whisky install.

- Runtime: `~/Library/Application Support/io.github.batteryshark.decant/Libraries/`
- Bottles: `~/Library/Application Support/io.github.batteryshark.decant/Bottles/<name>/`
- Logs, one per launch: `~/Library/Logs/io.github.batteryshark.decant/`

`Sources/decant/WhiskyAdapter.swift` is the only file that imports WhiskyKit.
`tests/` holds two small Windows programs, `sysinfo.c` and `d3d11test.c`, for checking a
runtime. Build them with `tests/build.sh`, which needs `zig`.

## Bumping WhiskyKit (always together with the runtime)

1. `git -C vendor/Whisky fetch && git -C vendor/Whisky checkout <commit>`
2. `swift build`. Fix any breakage in `WhiskyAdapter.swift` only. If the new WhiskyKit expects
   a new runtime major version, update `Kit.pinnedRuntimeMajor`.
3. Run `decant runtime update --force`, then run the tests (`OUT` is a Windows path such as
   `Z:\tmp\x.txt`):
   - `decant tests/bin/sysinfo{64,32}.exe OUT` should report Windows 10 and WoW64.
   - `decant tests/bin/d3d11test{64,32}.exe OUT` should show `winemetal.dll` loaded, no
     `wined3d.dll`, and the expected readback pixel.
4. Commit `vendor/Whisky` together with any adapter changes.

Current pin: frankea/Whisky `3abfbae9` (2026-10-01), runtime 3.1.1.

## Credits and license

Built on [Wine](https://www.winehq.org), [Gcenx](https://github.com/Gcenx)'s macOS Wine
builds, [DXMT](https://github.com/3Shain/dxmt), [DXVK-macOS](https://github.com/Gcenx/DXVK-macOS),
[MoltenVK](https://github.com/KhronosGroup/MoltenVK) and
[frankea/Whisky](https://github.com/frankea/Whisky).

GPL-3.0-or-later, since decant links WhiskyKit. See `LICENSE`.
