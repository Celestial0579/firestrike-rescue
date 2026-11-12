#!/usr/bin/env python3
"""Attrappe der Claude-API für den Selbsttest (frs --selftest, selftest_claude).

Der Selbsttest prüft die Sperre für Claude mit der echten Claude-Code-CLI, aber ohne Konto und
ohne Modell. Diese Attrappe spielt das Modell: Auf die erste Anfrage mit Werkzeugen antwortet
sie mit genau einem Werkzeugaufruf (aus der Datei AUFRUF, zum Beispiel Bash mit dem Befehl
"blockdev --setrw /dev/loop7"), auf jede weitere mit dem Wort FERTIG. Ob der Aufruf läuft,
entscheidet dann Claude Code mit seinen Einstellungen, nicht das Modell.

Die Attrappe lauscht nur auf 127.0.0.1 und nur, solange der Selbsttest läuft.

Aufruf: selftest-claude-api.py PORTDATEI AUFRUF PROTOKOLL
    PORTDATEI   Hierhin schreibt die Attrappe den Port, den sie bekommen hat.
    AUFRUF      JSON-Datei: {"name": "Bash", "input": {"command": "..."}}
    PROTOKOLL   Je Anfrage eine Zeile.
"""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT_FILE, CALL_FILE, LOG_FILE = sys.argv[1:4]


def log(line):
    with open(LOG_FILE, "a", encoding="utf-8") as f:
        f.write(line + "\n")


def has_tool_result(body):
    for msg in body.get("messages", []):
        content = msg.get("content")
        if isinstance(content, list):
            for block in content:
                if isinstance(block, dict) and block.get("type") == "tool_result":
                    return True
    return False


def sse(event, data):
    return ("event: %s\ndata: %s\n\n" % (event, json.dumps(data))).encode()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def _json(self, code, obj):
        raw = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        log("GET " + self.path)
        self._json(200, {"data": [], "has_more": False})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length else b"{}"
        try:
            body = json.loads(raw)
        except ValueError:
            body = {}
        if not isinstance(body, dict):
            body = {}
        path = self.path.split("?")[0]
        tools = [t.get("name") for t in body.get("tools", []) if isinstance(t, dict)]
        with open(CALL_FILE, encoding="utf-8") as f:
            call = json.load(f)
        # Der Aufruf geht nur an die Sitzung selbst (sie bietet Bash an), nicht an Hilfsanfragen
        # ohne Werkzeuge, und nur einmal.
        want_tool = "Bash" in tools and not has_tool_result(body)
        log("POST %s stream=%s tools=%d call=%s" % (path, body.get("stream"), len(tools), want_tool))
        if path.endswith("/count_tokens"):
            self._json(200, {"input_tokens": 10})
            return
        if not path.endswith("/v1/messages"):
            self._json(200, {})
            return

        model = body.get("model", "attrappe")
        if want_tool:
            block = {"type": "tool_use", "id": "toolu_selbsttest_1", "name": call["name"], "input": call["input"]}
            stop = "tool_use"
        else:
            block = {"type": "text", "text": "FERTIG"}
            stop = "end_turn"

        usage = {"input_tokens": 10, "output_tokens": 10,
                 "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}
        if not body.get("stream"):
            self._json(200, {"id": "msg_selbsttest", "type": "message", "role": "assistant",
                             "model": model, "content": [block], "stop_reason": stop,
                             "stop_sequence": None, "usage": usage})
            return

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        out = self.wfile
        out.write(sse("message_start", {"type": "message_start", "message": {
            "id": "msg_selbsttest", "type": "message", "role": "assistant", "model": model,
            "content": [], "stop_reason": None, "stop_sequence": None, "usage": usage}}))
        if block["type"] == "tool_use":
            out.write(sse("content_block_start", {"type": "content_block_start", "index": 0,
                      "content_block": {"type": "tool_use", "id": block["id"], "name": block["name"], "input": {}}}))
            out.write(sse("content_block_delta", {"type": "content_block_delta", "index": 0,
                      "delta": {"type": "input_json_delta", "partial_json": json.dumps(block["input"])}}))
        else:
            out.write(sse("content_block_start", {"type": "content_block_start", "index": 0,
                      "content_block": {"type": "text", "text": ""}}))
            out.write(sse("content_block_delta", {"type": "content_block_delta", "index": 0,
                      "delta": {"type": "text_delta", "text": block["text"]}}))
        out.write(sse("content_block_stop", {"type": "content_block_stop", "index": 0}))
        out.write(sse("message_delta", {"type": "message_delta",
                  "delta": {"stop_reason": stop, "stop_sequence": None}, "usage": {"output_tokens": 10}}))
        out.write(sse("message_stop", {"type": "message_stop"}))
        out.flush()
        self.close_connection = True


server = HTTPServer(("127.0.0.1", 0), Handler)
tmp = PORT_FILE + ".neu"
with open(tmp, "w", encoding="utf-8") as f:
    f.write("%d\n" % server.server_address[1])
os.replace(tmp, PORT_FILE)
server.serve_forever()
