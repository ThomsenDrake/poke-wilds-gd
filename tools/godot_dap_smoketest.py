#!/usr/bin/env python3
"""Run a launch smoke test against a running Godot editor DAP endpoint."""

from __future__ import annotations

import argparse
import json
import re
import socket
import sys
import time
from typing import Any


def send(sock: socket.socket, payload: dict[str, Any]) -> None:
    body = json.dumps(payload, separators=(",", ":"))
    packet = f"Content-Length: {len(body)}\r\n\r\n{body}".encode("utf-8")
    sock.sendall(packet)


def recv_messages(sock: socket.socket, timeout: float) -> list[dict[str, Any]]:
    sock.settimeout(timeout)
    data = b""
    messages: list[dict[str, Any]] = []
    end_time = time.time() + timeout

    while time.time() < end_time:
        try:
            chunk = sock.recv(8192)
            if not chunk:
                break
            data += chunk
            while True:
                split = data.find(b"\r\n\r\n")
                if split < 0:
                    break
                header = data[:split]
                match = re.search(rb"Content-Length:\s*(\d+)", header, re.IGNORECASE)
                if not match:
                    data = data[split + 4 :]
                    continue
                body_len = int(match.group(1))
                if len(data) < split + 4 + body_len:
                    break
                body = data[split + 4 : split + 4 + body_len]
                data = data[split + 4 + body_len :]
                messages.append(json.loads(body.decode("utf-8", "replace")))
        except socket.timeout:
            break

    return messages


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=6006)
    parser.add_argument("--project", required=True)
    parser.add_argument("--scene", default="res://scenes/Main.tscn")
    parser.add_argument("--timeout", type=float, default=8.0)
    args = parser.parse_args()

    had_exception = False
    seq = 1

    with socket.create_connection((args.host, args.port), timeout=3) as sock:
        send(
            sock,
            {
                "seq": seq,
                "type": "request",
                "command": "initialize",
                "arguments": {
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
            },
        )
        seq += 1
        send(
            sock,
            {
                "seq": seq,
                "type": "request",
                "command": "launch",
                "arguments": {"project": args.project, "scene": args.scene},
            },
        )
        seq += 1
        send(sock, {"seq": seq, "type": "request", "command": "configurationDone", "arguments": {}})
        seq += 1

        end = time.time() + args.timeout
        while time.time() < end:
            for msg in recv_messages(sock, timeout=0.6):
                if msg.get("type") != "event":
                    continue
                event = msg.get("event")
                body = msg.get("body", {})
                if event == "output":
                    output = body.get("output", "").strip()
                    if output:
                        print(output)
                elif event == "stopped" and body.get("reason") == "exception":
                    had_exception = True
                    print(f"Exception: {body.get('text', 'Unknown debugger exception')}")
                elif event == "terminated":
                    end = min(end, time.time() + 0.2)
            time.sleep(0.1)

        send(
            sock,
            {
                "seq": seq,
                "type": "request",
                "command": "disconnect",
                "arguments": {"terminateDebuggee": True},
            },
        )

    if had_exception:
        print("RESULT: FAIL")
        return 1
    print("RESULT: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
