#!/usr/bin/env bats
#
# fake-helper.bats -- tests/fake-helper.py, the scripted helper the dictation
# e2e run swaps in, driven the way the app drives it: framed requests on
# stdin, framed replies read back from fd 3. Covers the readiness ACK and its
# uuid echo, the '+'/'|' escaping both ways, the stale-key answer tracking
# what the control FIFO pressed, KeypressEvent frames with a rising index,
# the benign ACK for anything else, and the refusal to run without fd 3.
# The e2e run itself (tests/test-artifact-common.sh) proves the real app
# accepts these frames; this file pins the frames so a fake bug fails here
# by name instead of as a confusing e2e miss.
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
FAKE="$SCRIPT_DIR/fake-helper.py"

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP
	CTL="$TEST_TMP/ctl"
	mkfifo "$CTL"
	DRIVER="$TEST_TMP/driver.py"
	# Spawns the fake with a 4-pipe stdio like the app does, then runs the
	# steps given as args: 'send:<json>' frames and writes one request,
	# 'ctl:<line>' writes a control line, 'read:<n>' waits for n frames on
	# fd 3. Every frame read is printed unescaped as compact JSON, one per
	# line; the fake's stderr goes to $TEST_TMP/stderr.
	cat > "$DRIVER" <<'PY'
import json, os, subprocess, sys, time
fake, ctl, steps = sys.argv[1], sys.argv[2], sys.argv[3:]
r3, w3 = os.pipe()
env = dict(os.environ, WISPR_FAKE_HELPER_CTL=ctl)
err = open(os.path.join(os.environ["TEST_TMP"], "stderr"), "w")
# Popen closes every fd outside pass_fds after any preexec hook, so fd 3 is
# placed by sh right before exec instead.
p = subprocess.Popen(
	["sh", "-c", 'exec 3>&"$0"; exec "$@"', str(w3),
	 sys.executable, fake],
	stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=err, env=env,
	pass_fds=(w3,))
os.close(w3)
buf = ""
def esc(s): return s.replace("+", "+1").replace("|", "+2")
def unesc(s): return s.replace("+2", "|").replace("+1", "+")
def read(n):
	global buf
	frames, deadline = [], time.time() + 5
	while len(frames) < n and time.time() < deadline:
		while "|" in buf and len(frames) < n:
			chunk, buf = buf.split("|", 1)
			frames.append(json.loads(unesc(chunk)))
		if len(frames) < n:
			buf += os.read(r3, 65536).decode()
	for f in frames:
		print(json.dumps(f, sort_keys=True))
for step in steps:
	kind, arg = step.split(":", 1)
	if kind == "send":
		p.stdin.write((esc(json.dumps(json.loads(arg), indent=2)) + "|").encode())
		p.stdin.flush()
	elif kind == "ctl":
		with open(ctl, "w") as c:
			c.write(arg + "\n")
	elif kind == "read":
		read(int(arg))
p.stdin.close()
p.wait(timeout=5)
PY
}

teardown() {
	rm -rf "$TEST_TMP"
}

_drive() {
	run timeout 20 python3 "$DRIVER" "$FAKE" "$CTL" "$@"
}

@test "fake-helper: IsReady gets an ACK echoing the uuid, with launch timing" {
	_drive 'send:{"HelperAPIRequest":{"IsReady":true,"uuid":"u-1"}}' 'read:1'
	[[ "$status" -eq 0 ]]
	[[ "$output" == *'"ACK": true'* ]]
	[[ "$output" == *'"uuid": "u-1"'* ]]
	[[ "$output" == *'"helperMainEntryMs":'* ]]
}

@test "fake-helper: '+' and '|' survive the framing in both directions" {
	_drive 'send:{"HelperAPIRequest":{"PasteText":{"payload":{"text":"a|b+c"}},"uuid":"p|1+2"}}' \
		'read:1'
	[[ "$status" -eq 0 ]]
	# One frame back, and its uuid came through escape+unescape intact.
	[[ "${#lines[@]}" -eq 1 ]]
	[[ "$output" == *'"uuid": "p|1+2"'* ]]
	grep -qF 'fake-helper: <- PasteText' "$TEST_TMP/stderr"
}

@test "fake-helper: CheckStaleKeys reports only keys the FIFO is not holding" {
	_drive 'ctl:press 162' 'read:1' \
		'send:{"HelperAPIRequest":{"CheckStaleKeys":{"payload":{"keycodes":[162,91]}},"uuid":"s-1"}}' \
		'read:1'
	[[ "$status" -eq 0 ]]
	[[ "${lines[1]}" == *'"StaleKeysResponse": {"payload": {"staleKeys": [91]}}'* ]]
	[[ "${lines[1]}" == *'"uuid": "s-1"'* ]]
}

@test "fake-helper: control lines become KeypressEvents with a rising index" {
	_drive 'ctl:press 162' 'ctl:press 91' 'ctl:release 91' 'read:3'
	[[ "$status" -eq 0 ]]
	[[ "${lines[0]}" == *'"eventType": "key_event_press"'* ]]
	[[ "${lines[0]}" == *'"key": 162'* && "${lines[0]}" == *'"index": 1'* ]]
	[[ "${lines[1]}" == *'"key": 91'* && "${lines[1]}" == *'"index": 2'* ]]
	[[ "${lines[2]}" == *'"eventType": "key_event_release"'* ]]
	[[ "${lines[2]}" == *'"index": 3'* ]]
	[[ "${lines[2]}" == *'"inputType": "keyboard"'* ]]
	[[ "${lines[2]}" == *'"HelperAPIRequest"'* ]]
}

@test "fake-helper: an unknown command gets a benign ACK, not silence" {
	_drive 'send:{"HelperAPIRequest":{"NoSuchCommand":true,"uuid":"x-1"}}' 'read:1'
	[[ "$status" -eq 0 ]]
	[[ "$output" == *'"ACK": true'* && "$output" == *'"uuid": "x-1"'* ]]
}

@test "fake-helper: GetActiveAppInfo answers with an ActiveAppInfo payload" {
	_drive 'send:{"HelperAPIRequest":{"GetActiveAppInfo":true,"uuid":"a-1"}}' 'read:1'
	[[ "$status" -eq 0 ]]
	[[ "$output" == *'"ActiveAppInfo": {"payload": {'* ]]
	[[ "$output" == *'"appName": "fake-helper"'* ]]
}

@test "fake-helper: refuses to run without fd 3" {
	run python3 "$FAKE" </dev/null 3>&-
	[[ "$status" -eq 1 ]]
	[[ "$output" == *'no fd 3'* ]]
}
