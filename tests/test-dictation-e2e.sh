#!/usr/bin/env bash
# Scripted push-to-talk run against an AppDir, on its own.
#
# test-artifact-appimage.sh already runs this after the launch smoke test
# when it extracted a built AppImage. This entry point runs just the e2e
# check, for iterating on it or on a patch that touches the hotkey path:
#
#   ./AppImage --appimage-extract && tests/test-dictation-e2e.sh squashfs-root
#
# The AppDir must be writable: the helper binary is moved aside for the run
# and restored afterwards (also on Ctrl-C). Needs xvfb-run, dbus-run-session,
# setsid and python3; skips without them.

appdir="${1:?Usage: $0 <writable-appdir>}"
appdir="$(cd "$appdir" && pwd)"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/test-artifact-common.sh
source "$script_dir/test-artifact-common.sh"

trap _launch_smoke_cleanup EXIT INT TERM

run_dictation_e2e_test 'AppDir' "$appdir"
print_summary
