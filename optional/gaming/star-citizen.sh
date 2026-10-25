#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# ASUS ProArt P16 H7607BA - optional: Star Citizen (RSI Launcher) through Wine under FEX-Emu
#
# The steps of the Star Citizen Linux Users Group helper (lug-helper 4.17, install_game), with the x86 parts
# running under FEX. Differences, all found on the N1X (docs/gaming.md):
#  - Wine runner: Kron4ek 11.20 staging-tkg "amd64" with the classic 32-bit part (i386-unix). The LUG runner
#    is a pure WoW64 build; FEX crashed on its 32-bit code inside 64-bit processes (empty syswow64, font
#    install aborts). Launcher and game are 64-bit only.
#  - Wine at 192 dpi: the HiDPI screens otherwise make every Wine window tiny (launcher fixed at 900x620 px).
#  - Starter start-sc.sh runs the LUG launch script in an x86 shell (FEXBash) with a utilization clamp of 768
#    (energy-aware scheduling otherwise parks the bursty Wine threads on the efficiency cores at a few hundred
#    MHz) and without IBus' XIM; app menu entry "Star Citizen", and a Lutris entry if Lutris is installed.
#  - dxvk.conf: dxgi.syncInterval = 0. With vsync every present waited for a signal that came late on the path
#    DXVK -> Vulkan (FEX thunk) -> XWayland -> NVIDIA: the launcher showed 0.9 frames/s with an idle GPU.
# Needs optional/gaming/emulators.sh first. Checks: Kron4ek sha256sums.txt, RSI latest.yml sha512.
# The game itself (~100 GB) is downloaded by the launcher after you log in with your RSI account.
# Remove: rm -rf <install dir> ~/.local/share/applications/star-citizen.desktop
# Run with: bash optional/gaming/star-citizen.sh [install dir, default ~/Games/star-citizen]
set -euo pipefail
[ "$(id -u)" -ne 0 ] || { echo "Run this as your normal user, not as root"; exit 1; }
command -v FEXBash >/dev/null || { echo "FEX-Emu missing: sudo bash optional/gaming/emulators.sh"; exit 1; }
INSTALL=$(realpath -m "${1:-$HOME/Games/star-citizen}")
RUNNER=wine-11.20-staging-tkg-amd64
RUNNER_URL=https://github.com/Kron4ek/Wine-Builds/releases/download/11.20
LUG_VER=v4.17
RSI=https://install.robertsspaceindustries.com/rel/2
DL="$INSTALL/downloads"
mkdir -p "$INSTALL/runners" "$DL"
[ -z "$(ls -A "$INSTALL/drive_c" 2>/dev/null)" ] || { echo "$INSTALL already has a Wine prefix"; exit 1; }

echo "== 1/5 downloads"
curl -fsSL -o "$DL/sha256sums.txt" "$RUNNER_URL/sha256sums.txt"
[ -f "$DL/$RUNNER.tar.xz" ] || curl -fL -o "$DL/$RUNNER.tar.xz" "$RUNNER_URL/$RUNNER.tar.xz"
(cd "$DL" && grep " $RUNNER.tar.xz\$" sha256sums.txt | sha256sum -c -)
curl -fsSL -o "$DL/winetricks" https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks
chmod 755 "$DL/winetricks"
curl -fsSL "https://api.github.com/repos/starcitizen-lug/lug-helper/tarball/$LUG_VER" \
	| tar xz -C "$DL" --strip-components=2 --wildcards '*/lib/sc-launch.sh'
yml=$(curl -fsSL "$RSI/latest.yml")
setup=$(sed -n 's/^path: *//p' <<<"$yml")
sha=$(sed -n 's/^sha512: *//p' <<<"$yml" | head -1)
[ -f "$DL/$setup" ] || curl -fL -o "$DL/$setup" "$RSI/${setup// /%20}"
[ "$(openssl dgst -sha512 -binary "$DL/$setup" | base64 -w0)" = "$sha" ] || { echo "RSI installer checksum wrong"; exit 1; }

echo "== 2/5 Wine runner"
[ -d "$INSTALL/runners/$RUNNER" ] || tar xJf "$DL/$RUNNER.tar.xz" -C "$INSTALL/runners"
WINE_PATH="$INSTALL/runners/$RUNNER/bin"
FEX "$WINE_PATH/wine" --version

echo "== 3/5 Wine prefix: fonts, DXVK, PowerShell, Windows 11 (accept Wine Mono if asked; ~5-30 min)"
FEXBash -c "
set -e
export WINE='$WINE_PATH/wine' WINESERVER='$WINE_PATH/wineserver' WINEPREFIX='$INSTALL'
export WINEDLLOVERRIDES='dxwebsetup.exe,dotNetFx45_Full_setup.exe,winemenubuilder.exe=d'
export WINETRICKS_DOWNLOADER=curl PATH='$WINE_PATH':\$PATH
'$DL/winetricks' -q arial tahoma dxvk powershell win11
wine reg add 'HKEY_CURRENT_USER\Software\Wine\FileOpenAssociations' /v Enable /d N /f
wine reg add 'HKCU\Control Panel\Desktop' /v LogPixels /t REG_DWORD /d 192 /f
wine reg add 'HKLM\System\CurrentControlSet\Hardware Profiles\Current\Software\Fonts' /v LogPixels /t REG_DWORD /d 192 /f
echo '== 4/5 RSI Launcher'
wine '$DL/$setup' /S
wineserver -k || true
"

echo "== 5/5 launch script, starter, app menu entry"
mkdir -p "$INSTALL/drive_c/Program Files/Roberts Space Industries/StarCitizen/LIVE"
cp "$DL/sc-launch.sh" "$INSTALL/sc-launch.sh"
sed -i "s|^export WINEPREFIX=.*|export WINEPREFIX=\"$INSTALL\"|; s|^export wine_path=.*|export wine_path=\"$WINE_PATH\"|" \
	"$INSTALL/sc-launch.sh"
cat > "$INSTALL/start-sc.sh" <<'EOF'
#!/bin/bash
# Star Citizen: the LUG launch script (sc-launch.sh) in an x86 shell under FEX-Emu, with a utilization clamp
# of 768 (inherited by every Wine process and the game), without IBus' XIM and with dxvk.conf.
#   start-sc.sh [shell|config|controllers]
DIR=$(dirname "$(readlink -f "$0")")
export XMODIFIERS=@im=none
export DXVK_CONFIG_FILE="$DIR/dxvk.conf"
exec uclampset -m 768 FEXBash "$DIR/sc-launch.sh" "$@"
EOF
cat > "$INSTALL/dxvk.conf" <<'EOF'
# Presenting with vsync stalls on the N1X path DXVK -> Vulkan (FEX thunk) -> XWayland -> NVIDIA (0.9 frames/s
# with an idle GPU); without the wait 60 frames/s. Limit the game's frame rate in the game instead.
dxgi.syncInterval = 0
EOF
chmod 755 "$INSTALL/sc-launch.sh" "$INSTALL/start-sc.sh"
mkdir -p "$HOME/.local/share/applications"
for entry in "star-citizen:Star Citizen" "rsi-launcher:RSI Launcher"; do
	cat > "$HOME/.local/share/applications/${entry%%:*}.desktop" <<EOF
[Desktop Entry]
Name=${entry#*:}
GenericName=RSI Launcher
Comment=Star Citizen - RSI Launcher (Wine under FEX-Emu)
Keywords=RSI;Launcher;Star Citizen;StarCitizen;SC;Roberts Space Industries;
Exec="$INSTALL/start-sc.sh"
Icon=applications-games
Terminal=false
Type=Application
Categories=Game;
StartupWMClass=rsi launcher.exe
EOF
done
if command -v lutris >/dev/null && [ -f "$HOME/.local/share/lutris/pga.db" ] && command -v sqlite3 >/dev/null; then
	# a "Linux" game that runs the starter: Lutris' own Wine handling knows nothing about FEX
	cat > "$HOME/.local/share/lutris/games/star-citizen-fex.yml" <<EOF
game:
  exe: $INSTALL/start-sc.sh
  working_dir: $INSTALL
system:
  disable_runtime: true
EOF
	sqlite3 "$HOME/.local/share/lutris/pga.db" "DELETE FROM games WHERE slug='star-citizen-fex';
		INSERT INTO games (name, sortname, slug, installer_slug, platform, runner, executable, directory, updated,
		installed, installed_at, configpath, playtime) VALUES ('Star Citizen', 'Star Citizen', 'star-citizen-fex',
		'star-citizen-fex', 'Linux', 'linux', '$INSTALL/start-sc.sh', '$INSTALL', datetime('now'), 1, $(date +%s),
		'star-citizen-fex', 0);"
	echo "Lutris: Star Citizen added (close Lutris first if it was open)"
fi
echo "Done. Start: app menu -> Star Citizen (or $INSTALL/start-sc.sh)"
