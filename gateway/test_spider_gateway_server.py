"""Unit tests for the self-hosted BYO Marco Spider Gateway reference server."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import spider_gateway_server as gw


class SpiderGatewayServerTests(unittest.TestCase):
    def setUp(self):
        class FakeT4Handler(BaseHTTPRequestHandler):
            def log_message(self, fmt, *args):
                return

            def do_GET(self):
                body = json.dumps({
                    "class": [{"type_id": "1", "type_name": "电影"}],
                    "list": [{"vod_id": "42", "vod_name": "测试影片"}],
                }).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        self.t4 = ThreadingHTTPServer(("127.0.0.1", 0), FakeT4Handler)
        threading.Thread(target=self.t4.serve_forever, daemon=True).start()

        self.tmp = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8")
        json.dump(
            {
                "routes": {
                    "csp_demoso": {
                        "t4Url": f"http://127.0.0.1:{self.t4.server_port}/t4",
                    }
                }
            },
            self.tmp,
        )
        self.tmp.close()

        self.server = gw.create_server(
            host="127.0.0.1",
            port=0,
            token="test-token-123",
            device_name="UnitTest Gateway",
            routes_file=self.tmp.name,
            supports_native_so=True,
        )
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.base = f"http://127.0.0.1:{self.server.server_port}"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.t4.shutdown()
        self.t4.server_close()
        os.unlink(self.tmp.name)

    def test_health_requires_valid_bearer_token(self):
        with self.assertRaises(urllib.error.HTTPError) as ctx:
            urllib.request.urlopen(f"{self.base}/marco-gateway/v1/health")
        self.assertEqual(ctx.exception.code, 401)

        req = urllib.request.Request(
            f"{self.base}/marco-gateway/v1/health",
            headers={"Authorization": "Bearer test-token-123"},
        )
        with urllib.request.urlopen(req) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        self.assertTrue(data["ok"])
        self.assertEqual(data["protocol"], gw.PROTOCOL_ID)
        self.assertTrue(data["supportsNativeSo"])

    def test_invoke_bridges_t4_upstream(self):
        payload = json.dumps({
            "protocol": gw.PROTOCOL_ID,
            "action": "home",
            "site": {"key": "demo", "name": "Demo", "api": "csp_DemoSo", "type": 3},
            "params": {"filter": True},
        }).encode("utf-8")
        req = urllib.request.Request(
            f"{self.base}/marco-gateway/v1/invoke",
            data=payload,
            method="POST",
            headers={
                "Authorization": "Bearer test-token-123",
                "Content-Type": "application/json",
            },
        )
        with urllib.request.urlopen(req) as resp:
            doc = json.loads(resp.read().decode("utf-8"))
        self.assertTrue(doc["ok"])
        self.assertEqual(doc["data"]["list"][0]["vod_id"], "42")


if __name__ == "__main__":
    unittest.main()
