#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# ASUS ProArt P16 H7607BA - optional: Steam (snap) installs every game on another drive
#
# Steam's "Add drive" dialog may not offer a second internal SSD. This moves the default library's
# steamapps folder to the given directory and leaves a symlink, so every new game lands there without any
# setting. The snap's home interface allows paths under $HOME (e.g. an SSD mounted at ~/SSD); the script
# checks from inside the snap that Steam can write there.
# Remove: steam closed; rm <Steam>/steamapps; mv <dir>/steamapps <Steam>/
# Run with (Steam fully closed, Steam -> Exit): bash optional/gaming/steam-library.sh ~/SSD/games/steam
set -euo pipefail
[ "$(id -u)" -ne 0 ] || { echo "Run this as your normal user, not as root"; exit 1; }
[ $# -eq 1 ] || { echo "Usage: $0 <target directory>"; exit 1; }
STEAM="$HOME/snap/steam/common/.local/share/Steam"
TARGET=$(realpath -m "$1")
[ -d "$STEAM/steamapps" ] || { echo "No Steam library at $STEAM"; exit 1; }
[ -L "$STEAM/steamapps" ] && { echo "Already moved: $(readlink "$STEAM/steamapps")"; exit 0; }
if pgrep -f "Steam/ubuntu12_32/steam|steamwebhelper" >/dev/null; then
	echo "Steam is still running - quit it with Steam -> Exit first"; exit 1
fi
[ -e "$TARGET/steamapps" ] && { echo "$TARGET/steamapps exists already"; exit 1; }
mkdir -p "$TARGET"
snap run --shell steam -c "touch '$TARGET/.probe'" || { echo "The Steam snap cannot write to $TARGET"; exit 1; }
rm -f "$TARGET/.probe"
mv "$STEAM/steamapps" "$TARGET/steamapps"
ln -s "$TARGET/steamapps" "$STEAM/steamapps"
snap run --shell steam -c "df -h '$STEAM/steamapps/' | tail -1"
echo "Done: Steam installs into $TARGET/steamapps"
