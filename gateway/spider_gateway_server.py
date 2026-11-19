#!/usr/bin/env python3
"""
Marco Movie Self-Hosted BYO Spider Gateway (Reference Implementation)
Protocol: marco-spider-gateway-v1

Zero central/official server. Run this on your own LAN PC, NAS, Docker host,
or Termux/Android device to bridge unadapted TVBox `csp_*` spiders (including
T4 backends or custom Python/CLI spider runners) to Marco Movie on iOS, macOS,
Windows, and HarmonyOS.

Security:
  - Always requires a Bearer token (generated randomly on startup if unset).
  - UDP port 41978 LAN discovery NEVER exposes the token.
  - Only proxies lightweight CMS JSON metadata (home/category/search/detail/play);
    actual video streams are played directly by the Marco Movie client.
"""
from __future__ import annotations

import base64
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import secrets
import socket
import threading
import urllib.parse
import urllib.request

PROTOCOL_ID = "marco-spider-gateway-v1"
DISCOVERY_UDP_PORT = 41978
DISCOVERY_PROBE = b"MARCO_SPIDER_GATEWAY_PROBE_V1"
MAX_BODY_BYTES = 2 * 1024 * 1024


def load_route_map(path: str) -> dict[str, dict]:
    if not path or not os.path.isfile(path):
        return {}
    with open(path, "r", encoding="utf-8") as fh:
        raw = json.load(fh)
    if isinstance(raw, dict) and isinstance(raw.get("routes"), dict):
        return {k.lower(): v for k, v in raw["routes"].items() if isinstance(v, dict)}
    if isinstance(raw, dict):
        return {k.lower(): v for k, v in raw.items() if isinstance(v, dict)}
    return {}


def invoke_t4_upstream(base_url: str, action: str, params: dict, site: dict) -> dict:
    parsed = urllib.parse.urlparse(base_url)
    if parsed.scheme not in ("http", "https") or not parsed.netloc:
        raise ValueError("Invalid upstream T4 URL")
    query: dict[str, str] = {}
    if action in ("home", "homeVod"):
        query["filter"] = "true"
    elif action == "category":
        query["ac"] = "detail"
        query["t"] = str(params.get("tid", ""))
        query["pg"] = str(params.get("pg", 1))
        flt = params.get("filter") or {}
        if isinstance(flt, dict) and flt:
            encoded = base64.urlsafe_b64encode(
                json.dumps(flt, ensure_ascii=False).encode("utf-8")
            ).decode("ascii")
            query["ext"] = encoded
    elif action == "search":
        query["wd"] = str(params.get("wd", ""))
        query["pg"] = str(params.get("pg", 1))
        query["quick"] = "false"
    elif action == "detail":
        query["ac"] = "detail"
        query["ids"] = str(params.get("id", ""))
    elif action == "play":
        query["play"] = str(params.get("id", ""))
        query["flag"] = str(params.get("flag", ""))
    else:
        raise ValueError(f"Unsupported action: {action}")

    if site.get("ext") and "ext" not in query and action != "play":
        query["ext"] = str(site["ext"])

    existing_q = urllib.parse.parse_qsl(parsed.query, keep_blank_values=True)
    merged_q = urllib.parse.urlencode(existing_q + list(query.items()))
    target = urllib.parse.urlunparse(parsed._replace(query=merged_q))
    req = urllib.request.Request(
        target,
        headers={
            "User-Agent": "okhttp/3.15",
            "Accept": "application/json, text/plain, */*",
        },
    )
    with urllib.request.urlopen(req, timeout=18) as resp:
        body = resp.read(8 * 1024 * 1024).decode("utf-8", errors="replace")
    try:
        return json.loads(body)
    except json.JSONDecodeError:
        return {"raw": body}


def create_server(
    host: str = "0.0.0.0",
    port: int = 9981,
    token: str = "",
    device_name: str = "Marco Self-Hosted Gateway",
    routes_file: str = "",
    supports_native_so: bool = False,
) -> ThreadingHTTPServer:
    effective_token = token.strip() or secrets.token_hex(16)
    routes = load_route_map(routes_file)

    class GatewayHandler(BaseHTTPRequestHandler):
        server_version = "MarcoSpiderGateway/1.0"

        def log_message(self, fmt: str, *args) -> None:
            return

        def _send_json(self, code: int, payload: dict) -> None:
            body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("X-Marco-Gateway-Protocol", PROTOCOL_ID)
            self.end_headers()
            self.wfile.write(body)

        def _check_auth(self) -> bool:
            auth = (self.headers.get("Authorization") or "").strip()
            expected = f"Bearer {effective_token}"
            if not secrets.compare_digest(auth, expected):
                self._send_json(401, {"ok": False, "error": "Unauthorized"})
                return False
            return True

        def do_GET(self) -> None:
            path = urllib.parse.urlparse(self.path).path
            if path != "/marco-gateway/v1/health":
                self._send_json(404, {"ok": False, "error": "Not found"})
                return
            if not self._check_auth():
                return
            self._send_json(
                200,
                {
                    "ok": True,
                    "protocol": PROTOCOL_ID,
                    "deviceName": device_name,
                    "engine": "self-hosted-python",
                    "supportsNativeSo": supports_native_so,
                    "routeCount": len(routes),
                },
            )

        def do_POST(self) -> None:
            path = urllib.parse.urlparse(self.path).path
            if path != "/marco-gateway/v1/invoke":
                self._send_json(404, {"ok": False, "error": "Not found"})
                return
            if not self._check_auth():
                return
            try:
                length = int(self.headers.get("Content-Length") or "0")
            except ValueError:
                length = -1
            if length <= 0 or length > MAX_BODY_BYTES:
                self._send_json(400, {"ok": False, "error": "Invalid request body size"})
                return
            raw_body = self.rfile.read(length)
            try:
                req = json.loads(raw_body.decode("utf-8"))
            except Exception:
                self._send_json(400, {"ok": False, "error": "Malformed JSON payload"})
                return

            action = str(req.get("action") or "").strip()
            site = req.get("site") if isinstance(req.get("site"), dict) else {}
            params = req.get("params") if isinstance(req.get("params"), dict) else {}
            api = str(site.get("api") or "").strip().lower()
            route = routes.get(api) or routes.get("*")
            if not route:
                self._send_json(
                    404,
                    {
                        "ok": False,
                        "error": f"No gateway route configured for {api or 'unknown'}",
                    },
                )
                return

            try:
                t4_url = str(route.get("t4Url") or "").strip()
                if not t4_url:
                    raise ValueError("Route missing t4Url")
                data = invoke_t4_upstream(t4_url, action, params, site)
                self._send_json(200, {"ok": True, "data": data})
            except Exception as exc:
                self._send_json(502, {"ok": False, "error": str(exc)})

    httpd = ThreadingHTTPServer((host, port), GatewayHandler)
    httpd.gateway_token = effective_token  # type: ignore[attr-defined]
    return httpd


def start_udp_discovery_responder(
    http_port: int,
    device_name: str,
    supports_native_so: bool = False,
) -> tuple[socket.socket, threading.Event] | None:
    stop_event = threading.Event()
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind(("", DISCOVERY_UDP_PORT))
        sock.settimeout(0.5)
    except OSError:
        return None

    reply_payload = json.dumps(
        {
            "protocol": PROTOCOL_ID,
            "port": http_port,
            "deviceName": device_name,
            "engine": "self-hosted-python",
            "supportsNativeSo": supports_native_so,
            "requiresToken": True,
        },
        ensure_ascii=False,
    ).encode("utf-8")

    def loop() -> None:
        while not stop_event.is_set():
            try:
                data, addr = sock.recvfrom(512)
                if data.strip() == DISCOVERY_PROBE:
                    sock.sendto(reply_payload, addr)
            except socket.timeout:
                continue
            except OSError:
                break
        sock.close()

    thread = threading.Thread(target=loop, name="marco-gw-udp", daemon=True)
    thread.start()
    return sock, stop_event


def main() -> None:
    host = os.environ.get("MARCO_GATEWAY_HOST", "0.0.0.0")
    port = int(os.environ.get("MARCO_GATEWAY_PORT", "9981"))
    token = os.environ.get("MARCO_GATEWAY_TOKEN", "").strip()
    device_name = os.environ.get(
        "MARCO_GATEWAY_NAME", socket.gethostname() or "Marco Self-Hosted Gateway"
    )
    routes_file = os.environ.get("MARCO_GATEWAY_ROUTES", "")
    supports_so = os.environ.get("MARCO_GATEWAY_SUPPORTS_SO", "false").lower() == "true"

    httpd = create_server(
        host=host,
        port=port,
        token=token,
        device_name=device_name,
        routes_file=routes_file,
        supports_native_so=supports_so,
    )
    discovery = start_udp_discovery_responder(
        http_port=httpd.server_port,
        device_name=device_name,
        supports_native_so=supports_so,
    )
    print(f"[Marco Spider Gateway] Listening on {host}:{httpd.server_port} (HTTP)")
    print(f"[Marco Spider Gateway] Device Name : {device_name}")
    print(f"[Marco Spider Gateway] Bearer Token: {httpd.gateway_token}")
    print("[Marco Spider Gateway] Protocol    : marco-spider-gateway-v1")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        if discovery is not None:
            discovery[1].set()
        httpd.server_close()


if __name__ == "__main__":
    main()
