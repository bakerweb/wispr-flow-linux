#!/usr/bin/env bash
# Shared helpers for Wispr Flow artifact validation tests.
#
# Ported from claude-desktop-debian/tests/test-artifact-common.sh, adapted to
# Wispr Flow's FHS layout (/usr/lib/wispr-flow, the renamed 'wispr-flow'
# Electron binary, resources/Release/wispr-flow-linux-helper) and patch-marker
# verifier (scripts/verify-patches.sh greps the shipped app.asar directly).

_pass_count=0
_fail_count=0

pass() {
	printf '[PASS] %s\n' "$*"
	((_pass_count++)) || true
}

fail() {
	printf '[FAIL] %s\n' "$*" >&2
	((_fail_count++)) || true
}

assert_file_exists() {
	if [[ -f $1 ]]; then
		pass "File exists: $1"
	else
		fail "File missing: $1"
	fi
}

assert_dir_exists() {
	if [[ -d $1 ]]; then
		pass "Directory exists: $1"
	else
		fail "Directory missing: $1"
	fi
}

assert_executable() {
	if [[ -x $1 ]]; then
		pass "Executable: $1"
	else
		fail "Not executable: $1"
	fi
}

assert_setuid() {
	if [[ -u $1 ]]; then
		pass "Setuid bit set: $1"
	else
		fail "Setuid bit not set: $1"
	fi
}

# Assert $1 is traversable by "other" (o+rx). The test runs as root, for whom
# -r/-x always pass, so check the mode bits directly. Guards the regression
# where resources/ shipped 0700 and non-root users couldn't reach app.asar.
assert_dir_traversable() {
	local mode other
	mode=$(stat -c '%a' "$1" 2>/dev/null)
	other=$(( 0${mode: -1} ))
	if (( (other & 5) == 5 )); then
		pass "Directory other-traversable ($mode): $1"
	else
		fail "Directory not other-traversable ($mode): $1"
	fi
}

# Assert $1 is a linux ELF (magic 7f 45 4c 46). Catches a Windows PE .node that
# would dlopen-fail at startup ("invalid ELF header") -- the exact regression the
# native-module staging guards against.
assert_linux_elf() {
	local f="$1" magic
	if [[ ! -f $f ]]; then
		fail "Not an ELF (missing): $f"
		return
	fi
	magic=$(LC_ALL=C od -An -j0 -N4 -tx1 "$f" 2>/dev/null | tr -d ' \n')
	if [[ $magic == '7f454c46' ]]; then
		pass "Linux ELF: $f"
	else
		fail "Not a linux ELF (magic=$magic, want 7f454c46): $f"
	fi
}

assert_contains() {
	local file="$1" pattern="$2" desc="${3:-}"
	if grep -q "$pattern" "$file" 2>/dev/null; then
		pass "${desc:-"$file contains '$pattern'"}"
	else
		fail "${desc:-"$file does not contain '$pattern'"}"
	fi
}

assert_command_succeeds() {
	local desc="$1"
	shift
	if "$@" >/dev/null 2>&1; then
		pass "$desc"
	else
		fail "$desc (exit code: $?)"
	fi
}

# Assert the packed asar lists no patch backup (*.orig) entry. Every patch
# keeps a <bundle>.orig beside the file it rewrites and build-linux.sh
# step 7 drops them before repack; before it did, nine of them (102 MB on
# 1.6.897) shipped in every package. Only the header is read: an asar
# starts with a 16-byte pickle prefix whose last uint32 (offset 12,
# little-endian) is the JSON header length, so every entry name sits in
# the first 16+len bytes and a matching string in a bundle body cannot be
# mistaken for an entry. A PASS is only printed once that length parsed.
assert_asar_no_patch_backups() {
	local asar="$1" len names
	len=$(LC_ALL=C od -An -j12 -N4 -tu4 "$asar" 2>/dev/null | tr -d ' ')
	if [[ ! $len =~ ^[0-9]+$ ]] || (( len == 0 )); then
		fail "Cannot read the asar header length: $asar"
		return
	fi
	names=$(head -c $((16 + len)) "$asar" \
		| LC_ALL=C grep -ao '"[^"]*\.orig"' | sort -u | tr '\n' ' ')
	if [[ -z $names ]]; then
		pass "No patch backups (*.orig) packed in $asar"
	else
		fail "Patch backups packed in $asar: $names"
	fi
}

# Locate scripts/verify-patches.sh relative to this file (tests/..).
_verify_patches_sh() {
	local d
	d="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)"
	printf '%s' "$d/verify-patches.sh"
}

# Validate the Electron resources tree of an installed/extracted artifact.
# $1 = path to the resources/ dir containing app.asar.
#
# Checks the packed app.asar + unpacked native tree, the Linux helper binary
# under resources/Release/, and runs scripts/verify-patches.sh against the
# app.asar to confirm the Linux patch markers survived the repack (the same
# build-time safety net, re-run at artifact-inspection time).
validate_app_contents() {
	local resources_dir="$1"

	assert_file_exists "$resources_dir/app.asar"
	assert_dir_exists "$resources_dir/app.asar.unpacked"
	assert_asar_no_patch_backups "$resources_dir/app.asar"

	# resources/ and resources/Release/ must be traversable by non-root users:
	# Electron runs as the user and reads app.asar / the helper from here. A
	# 0700 dir here crashes launch even though the files inside are readable.
	assert_dir_traversable "$resources_dir"
	assert_dir_traversable "$resources_dir/Release"

	# Unpacked native modules: better-sqlite3 + sqlite3 (rebuilt for Electron
	# 42's V8 14.8) live under the unpacked .webpack tree and must ship as real
	# files (asar can't load a native .node from inside the archive) AND as linux
	# ELF -- the shipped app dlopens them at startup, so a Windows .node here
	# crashes before any window opens.
	local nm_rel
	nm_rel="app.asar.unpacked/.webpack/main/native_modules/build/Release"
	assert_linux_elf "$resources_dir/$nm_rel/better_sqlite3.node"
	assert_linux_elf "$resources_dir/$nm_rel/node_sqlite3.node"

	# The clean-room Rust Linux helper the patched resolver points at.
	local helper="$resources_dir/Release/wispr-flow-linux-helper"
	assert_file_exists "$helper"
	assert_executable "$helper"

	# Patch markers must be present in the shipped app.asar (helper-resolver
	# Linux branch + macOS Applications-folder gate). Reuses the build-time
	# verifier so a half-patched bundle fails artifact inspection too.
	local verify_sh
	verify_sh="$(_verify_patches_sh)"
	if [[ -x $verify_sh ]]; then
		if "$verify_sh" "$resources_dir/app.asar" >/dev/null 2>&1; then
			pass "verify-patches.sh: Linux patch markers present in app.asar"
		else
			fail "verify-patches.sh: Linux patch markers MISSING in app.asar"
		fi
	else
		pass "Skipping verify-patches.sh (not found at $verify_sh)"
	fi
}

# Headless launch smoke test. Boots the packaged app under Xvfb + a private
# D-Bus session and polls launcher.log for the helper-readiness marker
# ('Helper service is ready: true' — logged once the unmodified Electron app
# spawns the clean-room helper and completes the IsReady->ACK handshake; the
# app reaches live launch). Reaching it proves the asar
# loaded, the patched helper-resolver picked the Linux branch, the renamed
# binary set isPackaged=true (migrations ran), and the helper IPC contract is
# honoured — far more than a structure check.
#
# Usage:
#   run_launch_smoke_test <label> <pkill_match> <run_as> <cmd> [args...]
#     label        human name for pass/fail messages
#     pkill_match  pattern for the pkill -f child sweep (may be empty).
#                  Honoured only when CI is set; see the note below.
#     run_as       unprivileged user to drop to, or '' to run as-is. The
#                  deb/rpm install chrome-sandbox setuid-root and the launcher
#                  does NOT pass --no-sandbox, so Electron refuses to run as
#                  root: a root container must drop privileges to exercise the
#                  real setuid sandbox path.
#     cmd [args]   the launch command
#
# Missing tools (xvfb-run/dbus-run-session/setsid, or runuser when run_as is
# set) -> skip, not failure: loud failure on tool absence belongs at the CI
# workflow layer.
#
# The readiness marker alone is blind to one known failure: when the app
# spawns the helper without the session env (helper-env.sh no-oping on a new
# bundle), the helper still answers IsReady but picks the no-op `stub`
# injection backend, so recording works and nothing is ever typed. The
# helper logs its backend choice on stderr before it answers, and the app
# relays that into launcher.log; _smoke_check_backend reads that line after
# the marker and fails on `stub`. See docs/learnings/helper-spawn-env.md.
#
# The pkill -f sweep runs only under CI. Every caller's pattern (the
# /usr/lib/wispr-flow install root, the AppImage path) also matches a
# developer's live Wispr Flow, so a local run that reaped by pattern would
# take the real app down with the test's; the sibling project shipped
# exactly that regression. Locally the process-group kill is the only
# reaper, which is enough because the install tier (the one path where PAM
# re-setsid()s the child out of the group) is itself CI-only.

_smoke_launch_pid=''
_smoke_cache_root=''
_smoke_xvfb_log=''
_smoke_pkill_match=''

# Assert the helper picked a real injection backend. The helper's startup
# stderr is relayed into launcher.log as
#   [... INFO  wispr_flow_linux_helper::backend] injection: X11 (...)
#   [... WARN  wispr_flow_linux_helper::backend] injection: stub (no-op) ...
# The line normally precedes the readiness marker (the helper logs it before
# it answers IsReady), but the app relays stderr in chunks, so allow a short
# grace period. No line at all is a failure too: a PASS must be read from
# the log, never inferred from its absence.
_smoke_check_backend() {
	local label="$1" launcher_log="$2"
	local needle='::backend] injection: '
	local deadline line backend
	deadline=$((SECONDS + 5))
	while ((SECONDS < deadline)); do
		[[ -f $launcher_log ]] && grep -qF "$needle" "$launcher_log" && break
		sleep 0.5
	done
	line=$(grep -F -m1 "$needle" "$launcher_log" 2>/dev/null)
	if [[ -z $line ]]; then
		fail "$label: helper logged no injection backend" \
			"(no '$needle' line in launcher.log)"
		return
	fi
	backend="${line#*"$needle"}"
	backend="${backend%%\\n*}"
	backend="${backend%%\'*}"
	if [[ $backend == stub* ]]; then
		fail "$label: helper fell back to the stub injection backend" \
			"($backend): the session env did not reach the helper" \
			'(helper-env.sh no-op?)'
	else
		pass "$label helper injection backend: $backend"
	fi
}

_launch_smoke_cleanup() {
	if [[ -n $_smoke_launch_pid ]]; then
		kill -KILL -- "-$_smoke_launch_pid" 2>/dev/null
		[[ -n $_smoke_pkill_match ]] \
			&& pkill -KILL -f "$_smoke_pkill_match" 2>/dev/null
	fi
	[[ -n $_smoke_cache_root ]] && rm -rf "$_smoke_cache_root"
	[[ -n $_smoke_xvfb_log ]] && rm -rf "$_smoke_xvfb_log"
	_e2e_restore_helper
}

# True when a log carries the sandbox-namespace-denied signature: a CI
# container forbidding Chromium's user/PID namespace sandbox. That is an
# environment limit, not an app defect, so callers treat it as a skip.
_smoke_sandbox_denied() {
	local log
	for log in "$@"; do
		[[ -f $log ]] || continue
		grep -qE 'Failed to move to new namespace|zygote_host_impl_linux' \
			"$log" && return 0
		grep -q 'Operation not permitted' "$log" \
			&& grep -q 'namespace' "$log" && return 0
	done
	return 1
}

run_launch_smoke_test() {
	local label="$1" pkill_match="$2" run_as="$3"
	shift 3

	# CI-only sweep (see the header). Cleared here so both the end-of-run
	# sweep and the cleanup trap read the same decision.
	[[ -n ${CI:-} ]] || pkill_match=''

	local skip="Skipping launch smoke test for $label"
	if ! { command -v xvfb-run && command -v dbus-run-session \
		&& command -v setsid; } &>/dev/null; then
		pass "$skip (xvfb-run/dbus-run-session/setsid missing)"
		return
	fi
	if [[ -n $run_as ]] && ! command -v runuser &>/dev/null; then
		pass "$skip (runuser missing)"
		return
	fi

	local cache_root xvfb_log launcher_log
	cache_root=$(mktemp -d)
	xvfb_log=$(mktemp)
	# Must match setup_logging in launcher-common.sh: $XDG_CACHE_HOME/wispr-flow.
	launcher_log="$cache_root/wispr-flow/launcher.log"
	_smoke_cache_root="$cache_root"
	_smoke_xvfb_log="$xvfb_log"
	_smoke_pkill_match="$pkill_match"

	# setsid puts xvfb-run + Xvfb + dbus + launcher + electron in a fresh
	# process group so we can reap the whole tree. XDG_CACHE_HOME is
	# redirected so the test owns the launcher.log the marker lands in.
	local -a runner=(setsid)
	if [[ -n $run_as ]]; then
		chmod 0777 "$cache_root"
		runner+=(runuser -u "$run_as" --)
	fi
	runner+=(env "XDG_CACHE_HOME=$cache_root"
		xvfb-run -a -s '-screen 0 1280x720x24'
		dbus-run-session -- "$@")

	"${runner[@]}" >"$xvfb_log" 2>&1 &
	_smoke_launch_pid=$!

	local readiness_marker='Helper service is ready: true'
	local readiness_timeout=45 deadline saw_marker=0
	deadline=$((SECONDS + readiness_timeout))
	while ((SECONDS < deadline)); do
		if [[ -f $launcher_log ]] \
			&& grep -qF "$readiness_marker" "$launcher_log"; then
			saw_marker=1
			break
		fi
		kill -0 "$_smoke_launch_pid" 2>/dev/null || break
		sleep 0.5
	done

	if ((saw_marker == 1)); then
		pass "$label reached helper-ready state under Xvfb"
		_smoke_check_backend "$label" "$launcher_log"
	else
		local detail exit_code
		if kill -0 "$_smoke_launch_pid" 2>/dev/null; then
			detail="$label did not reach ready state within ${readiness_timeout}s"
		else
			wait "$_smoke_launch_pid" 2>/dev/null
			exit_code=$?
			detail="$label exited before reaching ready state (exit: $exit_code)"
		fi
		if [[ -f $launcher_log ]]; then
			echo '--- launcher.log (last 40 lines) ---' >&2
			tail -40 "$launcher_log" >&2
			echo '------------------------------------' >&2
		fi
		if [[ -s $xvfb_log ]]; then
			echo '--- xvfb-run stderr (last 20 lines) ---' >&2
			tail -20 "$xvfb_log" >&2
			echo '---------------------------------------' >&2
		fi
		# Namespace-sandbox denial is an environment limit, not a defect.
		if _smoke_sandbox_denied "$launcher_log" "$xvfb_log"; then
			pass "$label: SKIP - Chromium sandbox cannot initialize in this container (namespace creation denied by seccomp/userns policy); launch not exercised here."
		else
			fail "$detail"
		fi
	fi

	kill -TERM -- "-$_smoke_launch_pid" 2>/dev/null || true
	sleep 1
	kill -KILL -- "-$_smoke_launch_pid" 2>/dev/null || true
	wait "$_smoke_launch_pid" 2>/dev/null || true
	# Sweep any electron/helper child that escaped the group (PAM re-setsid
	# under runuser puts the child in its own session, so the group kill
	# above misses it — this sweep is the actual reaper there). Empty
	# outside CI, so a local run never reaps by pattern.
	if [[ -n $pkill_match ]]; then
		pkill -KILL -f "$pkill_match" 2>/dev/null || true
	fi

	rm -rf "$cache_root" "$xvfb_log"
	_smoke_launch_pid=''
	_smoke_cache_root=''
	_smoke_xvfb_log=''
}

# Scripted push-to-talk run. Boots an AppDir under Xvfb with the helper
# swapped for tests/fake-helper.py, then drives key events through the
# fake's control FIFO and reads launcher.log for the app's reaction. The
# smoke test above proves the helper handshakes; this proves the hotkey path
# behind it works: KeypressEvent VK codes reach the keyboard service, the
# Linux shortcut defaults (linux-main-shortcut-defaults.sh) map Ctrl+Win to
# push-to-talk, and the action starts dictation.
#
# The profile is seeded with onboarding complete, because the app refuses an
# action down before onboarding. It is never signed in, so dictation stops at
# the SignedOut notification right after startDictation; recording, the
# transcript and PasteText need an account and are not covered here.
#
# Usage:
#   run_dictation_e2e_test <label> <appdir>
#     appdir   a writable AppDir (an extracted AppImage) with AppRun at its
#              root. The helper binary is moved aside for the run and put
#              back by _e2e_restore_helper, which _launch_smoke_cleanup also
#              calls so a caller's existing trap covers an interrupted run.
#
# Missing tools (xvfb-run/dbus-run-session/setsid/python3) -> skip, as in
# run_launch_smoke_test.

_e2e_helper=''
_e2e_helper_saved=''

_e2e_restore_helper() {
	if [[ -n $_e2e_helper_saved && -e $_e2e_helper_saved ]]; then
		mv -f "$_e2e_helper_saved" "$_e2e_helper"
	fi
	_e2e_helper=''
	_e2e_helper_saved=''
}

# Write control lines to the fake helper's FIFO. The open blocks until the
# fake has its end open, so it is bounded: a helper that never opened the
# FIFO (the swap did not take) fails the step instead of hanging the test.
_e2e_send() {
	local ctl="$1"
	shift
	printf '%s\n' "$@" | timeout 10 tee "$ctl" >/dev/null
}

# Line number of the first match of a fixed string at or after line $3, or
# empty. Used to assert that markers appear in order.
_e2e_line_of() {
	local log="$1" needle="$2" from="${3:-1}"
	tail -n "+$from" "$log" 2>/dev/null \
		| grep -nF -m1 -- "$needle" \
		| { IFS=: read -r n _ && echo $((n + from - 1)); }
}

run_dictation_e2e_test() {
	local label="$1" appdir="$2"
	local skip="Skipping dictation e2e test for $label"
	if ! { command -v xvfb-run && command -v dbus-run-session \
		&& command -v setsid && command -v python3; } &>/dev/null; then
		pass "$skip (xvfb-run/dbus-run-session/setsid/python3 missing)"
		return
	fi

	local helper="$appdir/usr/lib/wispr-flow/resources/Release/wispr-flow-linux-helper"
	local fake
	fake="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fake-helper.py"
	if [[ ! -x $appdir/AppRun || ! -f $helper ]]; then
		fail "$label e2e: no AppRun or helper binary under $appdir"
		return
	fi
	if [[ ! -w ${helper%/*} ]]; then
		pass "$skip (helper dir not writable; needs an extracted AppDir)"
		return
	fi

	local work home ctl launcher_log xvfb_log
	work=$(mktemp -d)
	home="$work/home"
	ctl="$work/ctl"
	launcher_log="$home/.cache/wispr-flow/launcher.log"
	xvfb_log="$work/xvfb.log"
	mkdir -p "$home/.config/Wispr Flow" "$home/.cache"
	mkfifo "$ctl"
	printf '%s\n' '{"prefs":{"user":{"onboardingCompleted":true}}}' \
		>"$home/.config/Wispr Flow/config.json"
	_smoke_cache_root="$work"

	_e2e_helper="$helper"
	_e2e_helper_saved="$helper.e2e-real"
	mv "$helper" "$_e2e_helper_saved"
	printf '#!/bin/sh\nexec python3 %q "$@"\n' "$fake" >"$helper"
	chmod +x "$helper"

	# HOME and both XDG dirs point at the scratch profile, so the run never
	# reads or writes a developer's real Wispr Flow profile or lock.
	setsid env "HOME=$home" "XDG_CONFIG_HOME=$home/.config" \
		"XDG_CACHE_HOME=$home/.cache" "WISPR_FAKE_HELPER_CTL=$ctl" \
		xvfb-run -a -s '-screen 0 1280x720x24' \
		dbus-run-session -- "$appdir/AppRun" >"$xvfb_log" 2>&1 &
	_smoke_launch_pid=$!

	local deadline ready=0
	deadline=$((SECONDS + 45))
	while ((SECONDS < deadline)); do
		if grep -qF 'Helper service is ready: true' "$launcher_log" \
			2>/dev/null; then
			ready=1
			break
		fi
		kill -0 "$_smoke_launch_pid" 2>/dev/null || break
		sleep 0.5
	done

	if ((ready == 0)); then
		fail "$label e2e: app never reached helper-ready with the fake helper"
		[[ -f $launcher_log ]] && tail -30 "$launcher_log" >&2
		[[ -s $xvfb_log ]] && tail -15 "$xvfb_log" >&2
		_e2e_finish
		return
	fi
	pass "$label e2e: app reached helper-ready with the fake helper"

	# Wrong chord first: right Ctrl (163) + Win must not trigger push-to-talk.
	# Received-first-key proves the events reached the keyboard service, so
	# the absence of an action below is a real negative, not a dead pipe.
	if ! _e2e_send "$ctl" 'press 163' 'press 91' 'sleep 300' \
		'release 91' 'release 163'; then
		fail "$label e2e: fake helper's control FIFO never opened"
		_e2e_finish
		return
	fi
	local mark='[Keyboard Service] Received first key event'
	deadline=$((SECONDS + 10))
	while ((SECONDS < deadline)); do
		grep -qF "$mark" "$launcher_log" && break
		sleep 0.5
	done
	sleep 1
	if ! grep -qF "$mark" "$launcher_log"; then
		fail "$label e2e: keyboard service never saw a KeypressEvent"
		_e2e_finish
		return
	fi
	if grep -qF 'Ptt action down' "$launcher_log"; then
		fail "$label e2e: right Ctrl + Win triggered push-to-talk"
	else
		pass "$label e2e: right Ctrl + Win does not trigger push-to-talk"
	fi

	# The default chord: left Ctrl (162) then left Win (91), held.
	local from
	from=$(($(wc -l <"$launcher_log") + 1))
	_e2e_send "$ctl" 'press 162' 'sleep 50' 'press 91' 'sleep 1500' \
		'release 91' 'release 162'

	local -a markers=(
		'[Keyboard Service] Handling action from keycodes: ctrl + win'
		'Ptt action down. Dictation status: idle'
		'startDictation. Dictation status: idle. Action source: keyboard'
	)
	local m line prev="$from" missing=''
	deadline=$((SECONDS + 10))
	while ((SECONDS < deadline)); do
		[[ -n $(_e2e_line_of "$launcher_log" "${markers[-1]}" "$from") ]] \
			&& break
		sleep 0.5
	done
	for m in "${markers[@]}"; do
		line=$(_e2e_line_of "$launcher_log" "$m" "$prev")
		if [[ -z $line ]]; then
			missing="$m"
			break
		fi
		prev="$line"
	done
	if [[ -n $missing ]]; then
		fail "$label e2e: Ctrl+Win did not reach '$missing' (in order)"
		tail -n "+$from" "$launcher_log" | grep -vF 'GetDeviceInfo' \
			| tail -30 >&2
	else
		pass "$label e2e: Ctrl+Win -> ctrl + win action -> Ptt down" \
			'-> startDictation, in order'
	fi
	_e2e_finish
}

_e2e_finish() {
	if [[ -n $_smoke_launch_pid ]]; then
		kill -TERM -- "-$_smoke_launch_pid" 2>/dev/null
		sleep 1
		kill -KILL -- "-$_smoke_launch_pid" 2>/dev/null
		wait "$_smoke_launch_pid" 2>/dev/null
	fi
	_e2e_restore_helper
	[[ -n $_smoke_cache_root ]] && rm -rf "$_smoke_cache_root"
	_smoke_launch_pid=''
	_smoke_cache_root=''
}

print_summary() {
	echo
	echo '================================'
	printf 'Results: %d passed, %d failed\n' "$_pass_count" "$_fail_count"
	echo '================================'
	# Always terminal: callers use print_summary both as the final report and
	# as an early stop after a skip/precondition gate, so it must exit (not
	# fall through, or the script would continue past the gate).
	if [[ $_fail_count -gt 0 ]]; then
		exit 1
	fi
	exit 0
}
