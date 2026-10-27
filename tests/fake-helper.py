#!/usr/bin/env python3
"""Scripted stand-in for wispr-flow-linux-helper, for end-to-end tests.

Speaks the helper IPC contract (docs/reference/ipc-contract.md): commands
arrive on stdin and every protocol message goes out on fd 3, each one a
pretty-printed JSON envelope escaped ('+' -> '+1', '|' -> '+2') and
terminated by '|'. It answers the readiness handshake and the commands the
app needs to stay healthy, and otherwise ACKs, like the real helper.

Key events are not captured from any device. The test drives them through a
control FIFO named by WISPR_FAKE_HELPER_CTL, one command per line:

    press <vk>       emit KeypressEvent key_event_press for Windows VK <vk>
    release <vk>     emit KeypressEvent key_event_release for <vk>
    sleep <ms>       pause before the next control line

Every command received from the app is logged to stderr as
'fake-helper: <- <Command>', which the app relays into launcher.log, so a
test can assert what the app asked for (PasteText, SimulateKeyPress...).
"""

import json
import os
import sys
import threading
import time

STARTED = time.monotonic()
_out_lock = threading.Lock()
_held = set()
_held_lock = threading.Lock()
_index = 0


def log(msg):
	sys.stderr.write(f"fake-helper: {msg}\n")
	sys.stderr.flush()


def escape(body):
	return body.replace("+", "+1").replace("|", "+2")


def unescape(chunk):
	return chunk.replace("+2", "|").replace("+1", "+")


def send(kind, name, value, uuid):
	env = {kind: {name: value, "uuid": uuid}}
	frame = escape(json.dumps(env, indent=2)) + "|"
	with _out_lock:
		os.write(3, frame.encode("utf-8"))


def respond(name, value, uuid):
	send("HelperAPIResponse", name, value, uuid)


def ack(uuid):
	respond("ACK", True, uuid)


def emit_key(vk, press):
	global _index
	with _held_lock:
		_index += 1
		idx = _index
		if press:
			_held.add(vk)
		else:
			_held.discard(vk)
	event = "key_event_press" if press else "key_event_release"
	send("HelperAPIRequest", "KeypressEvent", {"payload": {
		"eventType": event, "key": vk, "index": idx,
		"inputType": "keyboard",
	}}, f"kp-fake-{idx}")
	log(f"-> KeypressEvent {event} {vk}")


APP = {"appName": "fake-helper", "bundleId": "fake-helper", "url": ""}


def handle(command, value, uuid):
	payload = value.get("payload", {}) if isinstance(value, dict) else {}
	if command == "IsReady":
		ms = int((time.monotonic() - STARTED) * 1000)
		env = {"HelperAPIResponse": {
			"ACK": True, "uuid": uuid,
			"HelperLaunchTiming": {"helperMainEntryMs": ms},
		}}
		frame = escape(json.dumps(env, indent=2)) + "|"
		with _out_lock:
			os.write(3, frame.encode("utf-8"))
		return
	if command == "CheckStaleKeys":
		with _held_lock:
			held = set(_held)
		stale = [k for k in payload.get("keycodes", []) if k not in held]
		respond("StaleKeysResponse", {"payload": {"staleKeys": stale}}, uuid)
		return
	if command == "GetAccessibilityStatus":
		respond("AccessibilityStatus", {"payload": {"status": True}}, uuid)
		return
	if command == "GetActiveAppInfo":
		info = dict(APP, windowTitle="fake-helper")
		respond("ActiveAppInfo", {"payload": info}, uuid)
		return
	if command == "GetAppInfo":
		respond("AppInfo", {"payload": APP}, uuid)
		return
	if command == "GetRunningApps":
		apps = [{"bundleId": APP["bundleId"], "name": APP["appName"]}]
		respond("RunningApps", {"payload": {"apps": apps}}, uuid)
		return
	if command == "HelperAppShutdown":
		ack(uuid)
		os._exit(0)
	ack(uuid)


METADATA = {"uuid", "sentryTrace", "sentryBaggage"}


def dispatch(body):
	try:
		msg = json.loads(body)
	except ValueError as err:
		log(f"unparsable frame ({err}): {body[:200]!r}")
		return
	request = msg.get("HelperAPIRequest")
	if request is None:
		return  # the app's responses to our events need no answer
	uuid = request.get("uuid", "")
	names = [k for k in request if k not in METADATA]
	if not names:
		return
	command = names[0]
	if command not in ("IsReady", "CheckStaleKeys"):
		log(f"<- {command}")
	handle(command, request[command], uuid)


def read_stdin():
	buf = ""
	stdin = sys.stdin.buffer
	while True:
		data = os.read(stdin.fileno(), 65536)
		if not data:
			os._exit(0)  # the app went away
		buf += data.decode("utf-8", errors="replace")
		*frames, buf = buf.split("|")
		for frame in frames:
			if frame.strip():
				dispatch(unescape(frame))


def run_control(path):
	while True:
		with open(path, "r", encoding="utf-8") as ctl:
			for line in ctl:
				parts = line.split()
				if not parts:
					continue
				try:
					if parts[0] == "press":
						emit_key(int(parts[1]), True)
					elif parts[0] == "release":
						emit_key(int(parts[1]), False)
					elif parts[0] == "sleep":
						time.sleep(int(parts[1]) / 1000)
					else:
						log(f"unknown control line: {line.strip()!r}")
				except (IndexError, ValueError):
					log(f"bad control line: {line.strip()!r}")


def main():
	try:
		os.fstat(3)
	except OSError:
		log("no fd 3: must be spawned by the app with a 4-pipe stdio")
		return 1
	# Matches the line _smoke_check_backend reads, so the existing smoke
	# assertions run unchanged against the fake.
	log("[fake INFO  wispr_flow_linux_helper::backend] injection: fake")
	ctl = os.environ.get("WISPR_FAKE_HELPER_CTL")
	if ctl:
		threading.Thread(target=run_control, args=(ctl,), daemon=True).start()
	else:
		log("WISPR_FAKE_HELPER_CTL unset: no key events will be sent")
	read_stdin()
	return 0


if __name__ == "__main__":
	sys.exit(main())
