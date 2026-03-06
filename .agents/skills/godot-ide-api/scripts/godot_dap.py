#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import socket
import sys
import time
from dataclasses import dataclass
from typing import Any


DEFAULT_HOST = "127.0.0.1"
DEFAULT_DAP_PORT = 6006


@dataclass
class DebugException:
    text: str
    stack: list[dict[str, Any]]


class DAPClient:
    def __init__(self, host: str, port: int, timeout: float = 3.0) -> None:
        self.host = host
        self.port = port
        self.timeout = timeout
        self.sock: socket.socket | None = None
        self.seq = 1
        self._buffer = b""

    def __enter__(self) -> "DAPClient":
        self.sock = socket.create_connection((self.host, self.port), timeout=self.timeout)
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        if self.sock is not None:
            try:
                self.sock.close()
            except OSError:
                pass
            self.sock = None

    def send(self, command: str, arguments: dict[str, Any]) -> None:
        if self.sock is None:
            raise RuntimeError("DAP socket is not connected")
        payload = {
            "seq": self.seq,
            "type": "request",
            "command": command,
            "arguments": arguments,
        }
        body = json.dumps(payload, separators=(",", ":"))
        packet = f"Content-Length: {len(body)}\r\n\r\n{body}".encode("utf-8")
        self.sock.sendall(packet)
        self.seq += 1

    def receive(self, timeout: float) -> list[dict[str, Any]]:
        if self.sock is None:
            raise RuntimeError("DAP socket is not connected")
        self.sock.settimeout(timeout)
        messages: list[dict[str, Any]] = []
        deadline = time.time() + timeout

        while time.time() < deadline:
            try:
                chunk = self.sock.recv(8192)
            except socket.timeout:
                break

            if not chunk:
                break

            self._buffer += chunk
            while True:
                split = self._buffer.find(b"\r\n\r\n")
                if split < 0:
                    break

                header = self._buffer[:split]
                match = re.search(rb"Content-Length:\s*(\d+)", header, re.IGNORECASE)
                if not match:
                    self._buffer = self._buffer[split + 4 :]
                    continue

                body_len = int(match.group(1))
                if len(self._buffer) < split + 4 + body_len:
                    break

                body = self._buffer[split + 4 : split + 4 + body_len]
                self._buffer = self._buffer[split + 4 + body_len :]
                messages.append(json.loads(body.decode("utf-8", "replace")))

        return messages

    def initialize(self) -> bool:
        self.send(
            "initialize",
            {
                "clientID": "codex",
                "clientName": "codex",
                "adapterID": "godot",
                "pathFormat": "path",
                "linesStartAt1": True,
                "columnsStartAt1": True,
                "supportsVariableType": True,
                "supportsVariablePaging": True,
                "supportsRunInTerminalRequest": False,
            },
        )
        for message in self.receive(1.0):
            if (
                message.get("type") == "response"
                and message.get("command") == "initialize"
                and message.get("success") is True
            ):
                return True
        return False

    def launch(self, project: str, scene: str) -> None:
        self.send("launch", {"project": project, "scene": scene})
        self.send("configurationDone", {})

    def stack_trace(self, thread_id: int) -> list[dict[str, Any]]:
        self.send("stackTrace", {"threadId": thread_id, "startFrame": 0, "levels": 8})
        for message in self.receive(1.0):
            if (
                message.get("type") == "response"
                and message.get("command") == "stackTrace"
                and message.get("success") is True
            ):
                return list(message.get("body", {}).get("stackFrames", []))
        return []

    def disconnect(self) -> None:
        try:
            self.send("disconnect", {"terminateDebuggee": True})
            self.receive(0.3)
        except OSError:
            pass


def probe_command(args: argparse.Namespace) -> int:
    ports = [int(value) for value in args.ports.split(",") if value.strip()]
    found = False

    for port in ports:
        try:
            with DAPClient(args.host, port, timeout=1.0) as client:
                if client.initialize():
                    print(f"DAP OK {args.host}:{port}")
                    found = True
                else:
                    print(f"NO DAP {args.host}:{port}")
        except OSError as exc:
            print(f"UNREACHABLE {args.host}:{port} {exc}")

    return 0 if found else 1


def collect_launch_run(args: argparse.Namespace) -> tuple[list[str], list[DebugException]]:
    outputs: list[str] = []
    exceptions: list[DebugException] = []

    with DAPClient(args.host, args.port) as client:
        if not client.initialize():
            raise RuntimeError(f"Failed to initialize Godot DAP on {args.host}:{args.port}")

        client.launch(args.project, args.scene)
        deadline = time.time() + args.timeout

        while time.time() < deadline:
            for message in client.receive(0.6):
                if message.get("type") != "event":
                    continue

                event = message.get("event")
                body = message.get("body", {})

                if event == "output":
                    output = body.get("output", "").strip()
                    if output:
                        outputs.append(output)

                if event == "stopped" and body.get("reason") == "exception":
                    thread_id = int(body.get("threadId", 1))
                    frames = client.stack_trace(thread_id)
                    stack: list[dict[str, Any]] = []
                    for frame in frames:
                        source = frame.get("source", {})
                        stack.append(
                            {
                                "path": source.get("path", ""),
                                "line": frame.get("line", 0),
                                "name": frame.get("name", ""),
                            }
                        )
                    exceptions.append(DebugException(body.get("text", "Unknown exception"), stack))

                if event == "terminated":
                    deadline = min(deadline, time.time() + 0.2)

        client.disconnect()

    return outputs, exceptions


def smoke_test_command(args: argparse.Namespace) -> int:
    outputs, exceptions = collect_launch_run(args)
    for line in outputs:
        print(line)

    if exceptions:
        for exception in exceptions:
            print(f"Exception: {exception.text}")
        print("RESULT: FAIL")
        return 1

    print("RESULT: OK")
    return 0


def debugger_report_command(args: argparse.Namespace) -> int:
    outputs, exceptions = collect_launch_run(args)

    print("=== DEBUGGER EXCEPTIONS ===")
    if not exceptions:
        print("NONE")
    else:
        for index, exception in enumerate(exceptions, start=1):
            print(f"[{index}] {exception.text}")
            for frame in exception.stack[:5]:
                path = frame.get("path", "")
                line = int(frame.get("line", 0))
                if path:
                    print(f"    at {path}:{line}")

    print("=== OUTPUT (last 20 lines) ===")
    for line in outputs[-20:]:
        print(line)

    return 1 if exceptions else 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Interact with a local Godot editor DAP endpoint.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    probe = subparsers.add_parser("probe", help="Probe likely local Godot DAP ports.")
    probe.add_argument("--host", default=DEFAULT_HOST)
    probe.add_argument("--ports", default="6006,6005")
    probe.set_defaults(func=probe_command)

    for name, help_text, func in [
        ("smoke-test", "Launch a project/scene and fail on debugger exceptions.", smoke_test_command),
        ("debugger-report", "Launch a project/scene and print debugger exceptions with stack traces.", debugger_report_command),
    ]:
        command = subparsers.add_parser(name, help=help_text)
        command.add_argument("--host", default=DEFAULT_HOST)
        command.add_argument("--port", type=int, default=DEFAULT_DAP_PORT)
        command.add_argument("--project", required=True)
        command.add_argument("--scene", default="res://scenes/Main.tscn")
        command.add_argument("--timeout", type=float, default=8.0)
        command.set_defaults(func=func)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    try:
        return int(args.func(args))
    except (OSError, RuntimeError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
