#!/bin/sh
# shellcheck disable=SC2016 # the sh -ec program expands its own variables
set -e
SRC="${1:-$(dirname "$0")/../feats/compat_run.sh}"
[ -f "$SRC" ] || { echo "bridgecheck: $SRC not present, skipped"; exit 0; }

block=$(sed -n '/^bridge_files="steamclient64/,/^  verify_runner$/p' "$SRC" | sed '$d')
case "$block" in
  *'bridge_matches='*) ;;
  *) echo "FAIL: the bridge staging block not found in $SRC"; exit 1 ;;
esac
body="$block
fi"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

files="steamclient64.dll steamclient.dll tier0_s64.dll vstdlib_s64.dll lsteamclient.dll steam.exe"
mkdir -p "$work/bridge"
for f in $files; do printf 'bridge %s\n' "$f" > "$work/bridge/$f"; done

fails=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n         want [%s]\n         got  [%s]\n' "$1" "$2" "$3"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }
logged() { if grep -qxF "$2" "$work/log"; then ok "$1"; else bad "$1" "$2" "$(cat "$work/log")"; fi; }
unlogged() { if grep -qxF "$2" "$work/log"; then bad "$1" "no [$2]" "$(cat "$work/log")"; else ok "$1"; fi; }

prefix="$work/pfx"
steam="$prefix/drive_c/Program Files (x86)/Steam"

stage() {
	: > "$work/log"
	env bridge_src="$work/bridge" WINEPREFIX="$prefix" prefix_steam="$steam" \
		log="$work/log" body="$body" \
		sh -ec 'eval "$body"; echo reached' > "$work/out" 2>&1 || true
}
staged() {
	n=0
	for f in $files; do cmp -s "$work/bridge/$f" "$steam/$f" && n=$((n + 1)); done
	echo "$n"
}

echo "== a fresh prefix gets the whole bridge"
stage
is "the launch goes on past staging" reached "$(cat "$work/out")"
is "every file is copied" 6 "$(staged)"
unlogged "nothing claims to be staged already" "=== bridge already staged ==="

echo "== a second launch copies nothing"
stage
is "the launch goes on" reached "$(cat "$work/out")"
logged "the copy is recognised" "=== bridge already staged ==="

echo "== changed bytes with the same size and timestamp"
cp -p "$work/bridge/steam.exe" "$work/stamp"
printf 'edited steam.exe\n' > "$work/bridge/steam.exe"
touch -r "$work/stamp" "$work/bridge/steam.exe"
is "the metadata still matches" "$(stat -f '%z %m' "$steam/steam.exe")" "$(stat -f '%z %m' "$work/bridge/steam.exe")"
stage
unlogged "matching metadata does not hide changed contents" "=== bridge already staged ==="
is "the prefix receives the changed bytes" 6 "$(staged)"

echo "== a DLL the bridge no longer ships is pruned"
printf 'old\n' > "$steam/old.dll"
stage
is "the launch goes on" reached "$(cat "$work/out")"
logged "the prune is logged" "=== pruned stale old.dll ==="
is "and the file is gone" no "$([ -e "$steam/old.dll" ] && echo yes || echo no)"

echo "== a changed bridge file is copied again"
printf 'bridge steamclient64.dll, newer build\n' > "$work/bridge/steamclient64.dll"
stage
is "the launch goes on" reached "$(cat "$work/out")"
unlogged "the old copy is not taken as current" "=== bridge already staged ==="
is "every file matches the bridge" 6 "$(staged)"

echo "== a bridge missing a file still stages the rest"
rm -rf "$prefix"
rm "$work/bridge/steam.exe"
stage
is "the launch goes on" reached "$(cat "$work/out")"
logged "the missing file is logged" "=== bridge missing steam.exe ==="
is "the other files are copied" 5 "$(staged)"

[ "$fails" -eq 0 ] || { echo "==> bridgecheck: $fails failure(s)"; exit 1; }
echo "==> bridgecheck: the bridge stages on fresh, current, stale and incomplete prefixes"
