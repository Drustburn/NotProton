#!/bin/sh
# shellcheck disable=SC2016 # the sh -ec program expands its own variables
set -e
SRC="${1:-$(dirname "$0")/../feats/compat_run.sh}"
[ -f "$SRC" ] || { echo "settingscheck: $SRC not present, skipped"; exit 0; }

body=$(sed -n '/^import_prefix_settings() {$/,/^}$/p' "$SRC")
[ -n "$body" ] || { echo "FAIL: import_prefix_settings not found in $SRC"; exit 1; }

work=$(mktemp -d)
trap 'chmod -R u+w "$work"; rm -rf "$work"' EXIT

cat > "$work/wine" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_CALLS"
if [ "$1 $2" = "reg import" ]; then
	cp "$WINEPREFIX/drive_c/${3#C:\\}" "$FAKE_IMPORTED" 2>/dev/null || true
fi
exit "${FAKE_STATUS:-0}"
EOF
chmod +x "$work/wine"

settings() {
	printf '%s\r\n' 'Windows Registry Editor Version 5.00' '' \
		'[HKEY_LOCAL_MACHINE\Software\Microsoft\Windows NT\CurrentVersion\AeDebug]' '"Auto"="0"' '' \
		'[HKEY_LOCAL_MACHINE\Software\Wow6432Node\Microsoft\Windows NT\CurrentVersion\AeDebug]' '"Auto"="0"' '' \
		'[HKEY_CURRENT_USER\Software\Wine\WineDbg]' '"ShowCrashDialog"=dword:00000000' '' \
		'[HKEY_CURRENT_USER\Software\Wine\Mac Driver]' "$1" '' \
		'[HKEY_LOCAL_MACHINE\Software\Classes\steam]' '"URL Protocol"=""' '' \
		'[HKEY_LOCAL_MACHINE\Software\Classes\steam\shell\open\command]' \
		'@="\"C:\\Program Files (x86)\\Steam\\steam.exe\" \"%1\""' ''
}
settings '"RetinaMode"=-' > "$work/retina-off"
settings '"RetinaMode"="y"' > "$work/retina-on"

fails=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n         want [%s]\n         got  [%s]\n' "$1" "$2" "$3"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }
same_file() { if cmp -s "$2" "$3"; then ok "$1"; else bad "$1" "contents of ${2##*/}" "$(cat -v "$3" 2>/dev/null)"; fi; }

case_dir=""
launch() {
	case_dir=$(mktemp -d "$work/case.XXXXXX")
	mkdir -p "$case_dir/pfx/drive_c"
	: > "$case_dir/calls"
	: > "$case_dir/log"
	[ "$3" != unwritable ] || chmod 500 "$case_dir/pfx/drive_c"
	env WINEPREFIX="$case_dir/pfx" WINELOADER="$work/wine" NOTPROTON_RETINA="$1" \
		FAKE_STATUS="$2" FAKE_CALLS="$case_dir/calls" FAKE_IMPORTED="$case_dir/imported" \
		log="$case_dir/log" body="$body" \
		sh -ec 'eval "$body"; import_prefix_settings; echo returned' \
		> "$case_dir/out" 2>&1 || true
	chmod 700 "$case_dir/pfx/drive_c"
}
calls() { sed 's/notproton-settings\.[A-Za-z0-9]*$/notproton-settings.X/' "$case_dir/calls"; }
leftovers() { find "$case_dir/pfx/drive_c" -name 'notproton-settings.*' | wc -l | tr -d ' '; }

echo "== one import per launch"
launch "" 0
is "Retina unset runs a single import and nothing else" 'reg import C:\notproton-settings.X' "$(calls)"
same_file "Retina unset deletes RetinaMode" "$work/retina-off" "$case_dir/imported"
is "the file is gone after the import" 0 "$(leftovers)"
is "a clean import logs nothing" "" "$(cat "$case_dir/log")"
is "the launch carries on" returned "$(cat "$case_dir/out")"

launch 1 0
same_file "Retina on sets RetinaMode to y" "$work/retina-on" "$case_dir/imported"

launch 0 0
same_file "Retina off deletes RetinaMode" "$work/retina-off" "$case_dir/imported"

echo "== failures"
launch "" 1
is "a failed import is logged" "=== prefix settings import exited status=1 ===" "$(cat "$case_dir/log")"
is "a failed import still removes the file" 0 "$(leftovers)"
is "a failed import does not end the launch" returned "$(cat "$case_dir/out")"

launch "" 0 unwritable
is "an unwritable C: drive falls back to wineboot, which builds the prefix" "wineboot --init" "$(calls)"
is "an unwritable C: drive is logged" "=== could not write the prefix settings, launching without them ===" "$(cat "$case_dir/log")"
is "an unwritable C: drive does not end the launch" returned "$(cat "$case_dir/out")"

if [ "$fails" -eq 0 ]; then
	echo "==> settingscheck: all assertions hold"
else
	echo "==> settingscheck: $fails failed"
	exit 1
fi
