#!/bin/sh
# Builds Decant.app (wrapper + decant CLI), installs it to ~/Applications, registers
# it and its "Run in Bottle…" service, and makes it this user's default for .exe and .msi.
set -eu
cd "$(dirname "$0")/.."
if [ "${1:-}" = --package-only ]; then
    # Regression checks package an existing build without touching installation,
    # LaunchServices, Services or defaults. Both paths must be supplied.
    [ "$#" -eq 3 ]
    build="$2"
    app="$3"
else
    [ "$#" -eq 0 ]
    python3 scripts/prepare.py -c release
    build=.build/release
    app=.build/Decant.app
fi
if [ "${1:-}" = --package-only ]; then
    [ ! -e "$app" ]
else
    rm -rf "$app"
fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources"
cp Resources/App-Info.plist "$app/Contents/Info.plist"
cp assets/AppIcon.icns "$app/Contents/Resources/"
cp "$build/DecantApp" "$app/Contents/MacOS/Decant"
cp "$build/decant" "$app/Contents/Helpers/decant"
cp -R "$build/decant_decant.bundle" "$app/Contents/Resources/"
codesign --force -s - "$app/Contents/Helpers/decant"
codesign --force -s - "$app"
codesign --verify --strict "$app"
[ "${1:-}" != --package-only ] || exit 0

dest="$HOME/Applications/Decant.app"
mkdir -p "$HOME/Applications"
rm -rf "$dest"
cp -R "$app" "$dest"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$dest"
/System/Library/CoreServices/pbs -update

swift - "$dest" <<'EOF'
import AppKit
import UniformTypeIdentifiers
let app = URL(filePath: CommandLine.arguments[1])
for ext in ["exe", "msi"] {
    let type = UTType(filenameExtension: ext)!
    let done = DispatchSemaphore(value: 0)
    NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type) { error in
        print(".\(ext) (\(type.identifier)) -> Decant: \(error.map { "\($0)" } ?? "ok")")
        done.signal()
    }
    done.wait()
}
EOF
