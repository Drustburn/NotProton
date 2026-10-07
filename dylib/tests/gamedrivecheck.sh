#!/bin/sh
# shellcheck disable=SC2016 # the sh -ec program expands its own variables
set -e
SRC="${1:-$(dirname "$0")/../feats/compat_run.sh}"
[ -f "$SRC" ] || { echo "gamedrivecheck: $SRC not present, skipped"; exit 0; }

body=$(sed -n '/^map_game_drive() {/,/^}/p' "$SRC")
[ -n "$body" ] || { echo "FAIL: map_game_drive not found in $SRC"; exit 1; }

work=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$work"' EXIT

fails=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n         want [%s]\n         got  [%s]\n' "$1" "$2" "$3"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }

lib="$work/Steam Library/One"
other="$work/Other Library"
mkdir -p "$lib/steamapps/common/Some Game" "$lib/steamapps/compatdata/1/pfx/dosdevices" \
	"$other/steamapps/common/Some Game"
compat="$lib/steamapps/compatdata/1"
prefix="$compat/pfx"
drive="$prefix/dosdevices/s:"
libs="$work/elsewhere/steamapps:$lib/steamapps/"

run() {
	: > "$work/log"
	env WINEPREFIX="$prefix" STEAM_COMPAT_DATA_PATH="$compat" log="$work/log" body="$body" \
		STEAM_COMPAT_INSTALL_PATH="$1" STEAM_COMPAT_LIBRARY_PATHS="$2" \
		sh -ec 'eval "$body"; map_game_drive; echo reached' > "$work/out" 2>&1 || true
}
target() { readlink "$drive" 2>/dev/null || echo none; }

echo "== the library holding the game becomes S:"
run "$lib/steamapps/common/Some Game" "$libs"
is "S: points at the library root" "$lib" "$(target)"
is "the launch continues" reached "$(tail -1 "$work/out")"
is "the mapping is recorded" "$lib" "$(cat "$compat/notproton-game-drive")"

echo "== a second launch leaves it alone"
run "$lib/steamapps/common/Some Game" "$libs"
is "S: is unchanged" "$lib" "$(target)"
is "nothing is logged" "" "$(cat "$work/log")"

echo "== a moved game follows its library"
run "$other/steamapps/common/Some Game" "$libs:$other/steamapps"
is "S: points at the new library" "$other" "$(target)"

echo "== a user's own S: is kept"
rm -f "$drive"
ln -s /tmp "$drive"
run "$lib/steamapps/common/Some Game" "$libs"
is "S: still points at /tmp" /tmp "$(target)"
is "the launch continues" reached "$(tail -1 "$work/out")"

echo "== an S: folder is kept"
rm -f "$drive"
mkdir "$drive"
run "$lib/steamapps/common/Some Game" "$libs"
is "S: is still a folder" yes "$([ -d "$drive" ] && [ ! -L "$drive" ] && echo yes)"
rmdir "$drive"

echo "== a game outside every library gets no S:"
rm -f "$compat/notproton-game-drive"
run "$work/loose/Some Game" "$libs"
is "no S:" none "$(target)"
is "the launch continues" reached "$(tail -1 "$work/out")"

echo "== a library whose name only starts the same does not match"
run "$lib/steamapps2/common/Some Game" "$lib/steamapps"
is "no S:" none "$(target)"

echo "== a library path that is not a steamapps folder maps as is"
mkdir -p "$work/flat/common/Some Game"
run "$work/flat/common/Some Game" "$work/flat"
is "S: points at the library itself" "$work/flat" "$(target)"
rm -f "$drive"

echo "== a prefix without dosdevices is left for wine to build"
mv "$prefix/dosdevices" "$prefix/dosdevices.off"
run "$lib/steamapps/common/Some Game" "$libs"
is "no dosdevices created" no "$([ -e "$prefix/dosdevices" ] && echo yes || echo no)"
mv "$prefix/dosdevices.off" "$prefix/dosdevices"

[ "$fails" -eq 0 ] || { echo "gamedrivecheck: $fails failed"; exit 1; }
echo "gamedrivecheck: all passed"
