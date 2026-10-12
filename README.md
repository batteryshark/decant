# decant

Run Windows programs on Apple Silicon Macs with Wine and Metal graphics, without
CrossOver. `decant foo.exe` runs it in a default bottle and returns at once.

Built on [frankea/Whisky](https://github.com/frankea/Whisky)'s WhiskyKit and its
Wine runtime (Wine 11, DXMT, DXVK-macOS). GPL-3.0-or-later, because it links WhiskyKit.

## Build

```sh
git submodule update --init      # vendor/Whisky at the pinned commit
swift build -c release           # → .build/release/decant
```

Needs Xcode/CLT with Swift 6, macOS 15+, and Rosetta 2.

## Usage

```sh
decant runtime update                # download, sha256-verify, install the stable runtime
decant runtime status [--prerelease] # installed vs latest version
decant runtime update --prerelease   # D3DMetal-capable 4.x pre-release (untested with this pin)

decant path/to/app.exe [args...]     # run in bottle "Default" (created on first use), detach
decant path/to/setup.msi [args...]   # runs msiexec /i <file> [args...]
decant 'C:\windows\notepad.exe'      # a path inside the bottle's C: drive
decant --bottle Games game.exe       # use, or create, bottle "Games"
decant --env WINEDEBUG=+loaddll app.exe   # per-launch environment

decant bottles list
decant bottles create NAME [--windows win11] [--backend dxvk]
decant bottles set NAME [--windows win7] [--backend wined3d]
decant wine [--bottle NAME] reg query 'HKLM\Software\Microsoft\Windows NT\CurrentVersion'
decant kill [--bottle NAME]          # wineserver -k
```

The runtime is installed on first launch if it's missing. Each launch writes its output to
`~/Library/Logs/io.github.batteryshark.decant/<time>-<program>.log`.

New bottles are a 64-bit prefix with WoW64 (32-bit programs run), report Windows 10,
and use DXMT for D3D10/11. D3D9 and older stay on Wine's wined3d. DXMT's 32-bit DLLs
go into `syswow64`, so 32-bit D3D11 programs get Metal too.

Backends: `dxmt`, `dxvk`, `d3dMetal` (needs a GPTK runtime), `wined3d`, and `recommended`
(WhiskyKit picks). Windows versions: `winxp64`, `win7`, `win8`, `win81`, `win10`, `win11`.

## Where things live

All paths are keyed on the bundle ID in `Resources/Info.plist`, which is embedded into the
binary with `-sectcreate __TEXT __info_plist`. That keeps decant's data apart from any real
Whisky install.

| What | Path |
|---|---|
| Runtime | `~/Library/Application Support/io.github.batteryshark.decant/Libraries/` |
| Bottles | `~/Library/Application Support/io.github.batteryshark.decant/Bottles/<name>/` |
| Logs | `~/Library/Logs/io.github.batteryshark.decant/` |

decant doesn't use WhiskyKit's `BottleData` registry, which lives under `~/Library/Containers`.
Any folder in `Bottles/` that has a `Metadata.plist` is a bottle.

## Code layout

- `Sources/decant/WhiskyAdapter.swift`: the **only** file that imports WhiskyKit.
- `Runtime.swift`: fetches the manifest, downloads the tarball, checks sha256, installs or
  upgrades. Stable releases come from `WhiskyWineVersion.plist`. Pre-releases come from the
  GitHub releases API, with the sha256 taken from the asset digest.
- `Bottles.swift`, `Launch.swift` (detached `posix_spawn` with `setsid`), `main.swift` (CLI).
- `tests/`: small 64/32-bit Windows test programs (`sysinfo.c`, `d3d11test.c`). Build them
  with `tests/build.sh` (needs `zig`).

## Bumping the WhiskyKit pin (always together with the runtime)

WhiskyKit expects a matching runtime layout, so change both at the same time:

1. `cd vendor/Whisky && git fetch && git checkout <new commit> && cd ../..`
2. `swift build`, then fix any API breakage in `WhiskyAdapter.swift` only.
3. If the new WhiskyKit targets a new runtime major version, update `Kit.pinnedRuntimeMajor`
   in the adapter. The stable channel refuses newer majors until you do.
4. `decant runtime update` (add `--force` to reinstall the same version), then re-run the
   checks: `tests/bin/sysinfo{64,32}.exe` and `decant --env WINEDEBUG=+loaddll
   tests/bin/d3d11test{64,32}.exe <outfile>` should show native `d3d11.dll`/`DXGI.DLL`,
   `winemetal.dll`, and no `wined3d.dll`.
5. `git add vendor/Whisky Sources && git commit -m "Bump WhiskyKit to <sha>"`.

Current pin: frankea/Whisky `3abfbae945e3400caaa13cf2e78fe5a187a1405b` (2026-10-01), runtime 3.1.1.
