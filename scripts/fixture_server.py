#!/usr/bin/env python3
"""Local protocol fixture; no real xbot account or model calls. Bind loopback only."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import threading
import time
import argparse

lock = threading.Condition()
events = []
history = []
turn = 0
pending_ask = None
sessions = [{"chat_id": "fixture", "channel": "web", "label": "协议联调", "preview": "本地测试服务器"}]
settings = {"get_user_thinking_mode": "", "get_context_mode": "phase1", "get_user_max_output_tokens": 4096, "get_user_max_context": 32768, "get_llm_concurrency": 2}
compression = 0.8
mobile_requests = {"messages": 0, "uploads": 0, "reports": 0, "deletions": 0}
rich_text = """## 完整内容验收

| 项目 | 状态 |
| :--- | ---: |
| iOS | 已对齐 |

```mermaid
graph TD
  A[SwiftUI] --> B[SSE]
  B --> C[完成]
```

![示例图片](/image.png)
"""

def emit(event):
    with lock:
        event["seq"] = len(events) + 1
        event.update(chat_id="fixture", channel="web")
        events.append(event); lock.notify_all()

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, fmt, *args):
        print(fmt % args, flush=True)
    def send_json(self, data, status=200, cookie=False):
        raw = json.dumps({"ok": status < 400, "data": data}, ensure_ascii=False).encode()
        self.send_response(status); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        if cookie: self.send_header("Set-Cookie", "xbot_fixture=authorized; Path=/; Max-Age=3600; HttpOnly; SameSite=Lax")
        self.end_headers(); self.wfile.write(raw)
    def authorized(self): return "xbot_fixture=authorized" in self.headers.get("Cookie", "")
    def do_POST(self):
        global turn, compression, pending_ask
        path = self.path.split("?")[0]
        raw = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        body = json.loads(raw or b"{}") if "multipart" not in self.headers.get("Content-Type", "") else {}
        if path == "/api/auth/config": return self.send_json({"bootstrap": False})
        if path == "/api/mobile/policy": return self.send_json({}, 404)  # Exercise an unmodified self-hosted server.
        if path == "/__test/counts": return self.send_json(mobile_requests)
        if path == "/__test/reset":
            with lock:
                events.clear(); history.clear(); turn = 0; pending_ask = None
                for key in mobile_requests: mobile_requests[key] = 0
                lock.notify_all()
            return self.send_json({})
        if path == "/__test/notice":
            emit({"type": "text", "turn_id": 10000 + len(events), "content": "后台完成验收"}); return self.send_json({})
        if path == "/api/auth/login":
            if body == {"username": "tester", "password": "fixture-password"}: return self.send_json({"ok": True}, cookie=True)
            return self.send_json(None, 401)
        if not self.authorized(): return self.send_json(None, 401)
        if path == "/api/auth/logout": return self.send_json({})
        if path == "/api/mobile/account-deletion":
            if body.get("username") != "tester" or body.get("password") != "fixture-password": return self.send_json({}, 401)
            mobile_requests["deletions"] += 1
            return self.send_json({"id": "d" * 64, "status": "pending", "deadline": "2026-11-01T00:00:00Z"})
        if path == "/api/mobile/status": return self.send_json({"id": body.get("id"), "status": "pending", "deadline": "2026-11-01T00:00:00Z"})
        if path == "/api/mobile/reports":
            mobile_requests["reports"] += 1
            return self.send_json({"id": "f" * 64, "status": "received"})
        if path == "/api/files/upload":
            mobile_requests["uploads"] += 1
            return self.send_json({"upload_key": "fixture-upload", "name": "fixture.png", "size": len(raw), "mime": "image/png"})
        if path == "/api/session-tree": return self.send_json({"sessions": sessions})
        if path == "/api/history": return self.send_json({"messages": history, "last_seq": len(events), "processing": False, "active_progress": {"phase": "done"}})
        if path == "/api/message":
            mobile_requests["messages"] += 1
            turn += 1; tid = turn; text = body.get("content", "")
            history.append({"turn_id": tid, "history_id": tid * 10, "role": "user", "content": text})
            if text == "need-input":
                pending_ask = {"request_id": "fixture-ask", "questions": [{"question": "选择一个方案", "options": ["方案 A", "方案 B"], "allow_other": True}]}
                emit({"type": "ask_user", "progress": pending_ask})
            else:
                emit({"type": "progress_structured", "progress": {"turn_id": tid, "iteration": 1, "phase": "running", "stream_delta": "正在处理…"}})
                output = rich_text if text == "rich-markdown" else "已收到：" + text
                emit({"type": "text", "turn_id": tid, "content": output})
                history.append({"turn_id": tid, "role": "assistant", "content": output})
            return self.send_json({"turn_id": tid, "chat_id": "fixture", "queued": False})
        if path == "/api/ask_user/respond":
            assert body["answers"] == {"1": "方案 A"}, "AskUser must use one-based question keys"
            pending_ask = None
            output = "已选择：" + body["answers"]["1"]
            emit({"type": "ask_user_resolved", "request_id": "fixture-ask"})
            emit({"type": "text", "turn_id": turn, "content": output})
            history.append({"turn_id": turn, "role": "assistant", "content": output})
            return self.send_json({})
        if path == "/api/rpc":
            method = body["method"]
            params = body.get("params", {})
            setters = {"set_user_thinking_mode": ("get_user_thinking_mode", "mode"), "set_context_mode": ("get_context_mode", "mode"), "set_user_max_output_tokens": ("get_user_max_output_tokens", "max_tokens"), "set_user_max_context": ("get_user_max_context", "max_context"), "set_llm_concurrency": ("get_llm_concurrency", "personal")}
            if method == "set_user_thinking_mode" and params.get("mode") not in ("", "enabled", "think-max", "disabled"): return self.send_json({}, 400)
            if method in setters:
                read, key = setters[method]; settings[read] = params[key]
            if method == "set_compression_threshold":
                assert 0 <= params["threshold"] <= 1
                compression = params["threshold"]
            if method == "get_settings":
                assert params == {"namespace": "agent"}
                return self.send_json({"compression_threshold": str(compression)})
            result = {"get_pending_ask_user": pending_ask, "list_all_model_entries": [{"sub_id": "local", "sub_name": "测试订阅", "model": "fixture-model", "status": "online"}], "get_session_subscription": {"subscription_id": "local", "model": "fixture-model"}, "get_default_model": {"sub_id": "local", "model": "fixture-model"}, "list_subscriptions": [], "get_tools_settings": {"tools": []}, **settings}.get(method, {})
            return self.send_json(result)
        if path == "/api/chats/create":
            chat_id = "created-" + str(len(sessions)); sessions.append({"chat_id": chat_id, "channel": "web", "label": body["label"]}); return self.send_json({"chat_id": chat_id})
        if path == "/api/cancel": emit({"type": "session", "session": {"action": "idle"}}); return self.send_json({})
        return self.send_json({}, 404)
    def do_GET(self):
        if self.path == "/healthz": return self.send_json({"fixture": True})
        if self.path == "/ios/latest.json":
            raw = json.dumps({"platform": "ios", "versionName": "9.0.0", "versionCode": 900, "url": "https://testflight.apple.com/join/fixture", "changelog": "本地更新流程验证", "mandatory": False}).encode()
            self.send_response(200); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(raw))); self.end_headers(); self.wfile.write(raw); return
        if not self.authorized(): return self.send_json(None, 401)
        if self.path == "/image.png":
            data = (Path(__file__).resolve().parent.parent / "Sources/XbotApp/Assets.xcassets/AppIcon.appiconset/AppIcon.png").read_bytes()
            self.send_response(200); self.send_header("Content-Type", "image/png"); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data); return
        if not self.path.startswith("/api/sse"): return self.send_json({}, 404)
        cursor = int(self.headers.get("Last-Event-ID", 0))
        self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.send_header("Cache-Control", "no-cache"); self.end_headers()
        try:
            while True:
                with lock:
                    pending = events[cursor:]
                if not pending: self.wfile.write(b": heartbeat\n\n"); self.wfile.flush()
                for event in pending:
                    payload = json.dumps(event, ensure_ascii=False)
                    self.wfile.write(f'id: {event["seq"]}\ndata: {payload}\n\n'.encode()); self.wfile.flush(); cursor = event["seq"]
                with lock: lock.wait(timeout=1)
        except (BrokenPipeError, ConnectionResetError): self.close_connection = True
    def handle(self):
        try: super().handle()
        except (BrokenPipeError, ConnectionResetError): pass

if __name__ == "__main__":
    parser = argparse.ArgumentParser(); parser.add_argument("--port", type=int, default=18081)
    args = parser.parse_args()
    print(f"Fixture listening on http://127.0.0.1:{args.port}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()
