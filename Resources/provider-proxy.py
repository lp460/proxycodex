#!/usr/bin/env python3
"""Local adapter proxies for third-party providers used by Codex Desktop.

Codex Desktop expects provider model lists in its own catalog schema
(`{"models": [...]}`) and speaks the OpenAI Responses API. This proxy:

- relay mode    (OpenAI-compatible upstreams): translates GET /v1/models and
                 relays everything else with auth intact.
- anthropic mode (Claude): translates GET /v1/models AND POST /v1/responses
                 (Responses API <-> Anthropic Messages API), including SSE
                 streaming and tool calls.

Usage: provider-proxy.py <port> <upstream_base> <display_name> <model1,model2...> [relay|anthropic]
"""
import json
import os
import subprocess
import ssl
import sys
import time
import uuid
import urllib.request
import urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1])
UPSTREAM = sys.argv[2].rstrip("/")
if UPSTREAM.endswith("/v1"):
    UPSTREAM = UPSTREAM[:-3]  # normalise: path segments carry their own /v1
DISPLAY = sys.argv[3]
MODELS = [m for m in sys.argv[4].split(",") if m]
ADAPTER = sys.argv[5] if len(sys.argv) > 5 else "relay"

ENTRY_TEMPLATE = {
    "slug": "x",
    "display_name": "X",
    "description": "via AI Provider Switcher.",
    "default_reasoning_level": "low",
    "supported_reasoning_levels": [
        {"effort": "low", "description": "Fast responses with lighter reasoning"},
        {"effort": "medium", "description": "Balances speed and reasoning depth"},
        {"effort": "high", "description": "Greater reasoning depth for complex problems"},
    ],
    "shell_type": "shell_command",
    "visibility": "list",
    "supported_in_api": True,
    "priority": 50,
    "additional_speed_tiers": [],
    "service_tiers": [],
    "upgrade": None,
    "availability_nux": None,
    "base_instructions": None,
    "model_messages": None,
    "include_skills_usage_instructions": None,
    "default_reasoning_summary": None,
    "support_verbosity": None,
    "default_verbosity": None,
    "apply_patch_tool_type": None,
    "web_search_tool_type": None,
    "truncation_policy": None,
    "supports_parallel_tool_calls": None,
    "supports_image_detail_original": None,
    "context_window": None,
    "max_context_window": None,
    "comp_hash": None,
    "effective_context_window_percent": None,
    "experimental_supported_tools": None,
    "input_modalities": None,
    "supports_search_tool": None,
    "use_responses_lite": None,
    "tool_mode": None,
    "multi_agent_version": None,
}


def models_response():
    entries = []
    for i, slug in enumerate(MODELS, start=50):
        e = dict(ENTRY_TEMPLATE)
        e["slug"] = slug
        e["display_name"] = f"{DISPLAY} · {slug}"
        e["description"] = f"{DISPLAY} model {slug}."
        e["priority"] = i
        entries.append(e)
    return json.dumps({"models": entries}).encode()


def ssl_context():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


# ---------------------------------------------------------------------------
# Anthropic adapter: Responses API <-> Messages API
# Auth follows Claude Code's own environment (~/.claude/settings.json):
# ANTHROPIC_AUTH_TOKEN (OAuth bearer) + ANTHROPIC_BASE_URL. No API key needed.
# ---------------------------------------------------------------------------

def claude_settings_env():
    try:
        with open(os.path.expanduser("~/.claude/settings.json")) as f:
            return json.load(f).get("env", {})
    except Exception:
        return {}


def _keychain_oauth_blob():
    try:
        out = subprocess.run(
            ["security", "find-generic-password", "-w", "-s", "Claude Code-credentials"],
            capture_output=True, text=True, timeout=10)
        return json.loads((out.stdout or "").strip()).get("claudeAiOauth", {})
    except Exception:
        return {}


def _try_refresh(oauth):
    """Best-effort OAuth refresh (expired access token)."""
    rt = (oauth.get("refreshToken") or "").strip()
    if not rt:
        return None
    import urllib.parse
    body = urllib.parse.urlencode({"grant_type": "refresh_token", "refresh_token": rt}).encode()
    for url in ("https://api.anthropic.com/v1/oauth/token", "https://claude.ai/oauth/token"):
        try:
            req = urllib.request.Request(
                url, data=body, headers={"Content-Type": "application/x-www-form-urlencoded"})
            resp = urllib.request.urlopen(req, context=ssl_context(), timeout=15)
            token = json.loads(resp.read().decode("utf-8")).get("access_token", "")
            if token:
                return token
        except Exception:
            continue
    return None


def _anthropic_oauth_token():
    """Claude Code's real Anthropic OAuth access token from the keychain."""
    oauth = _keychain_oauth_blob()
    token = (oauth.get("accessToken") or "").strip()
    if not token:
        return None
    expires_at = oauth.get("expiresAt")
    if isinstance(expires_at, (int, float)) and expires_at and expires_at < time.time() * 1000:
        token = _try_refresh(oauth) or None
    return token


def anthropic_base_url():
    if _anthropic_oauth_token():
        return UPSTREAM  # real Anthropic (api.anthropic.com)
    env = claude_settings_env()
    base = (env.get("ANTHROPIC_BASE_URL") or "").strip().rstrip("/")
    if base:
        return base
    return UPSTREAM


def anthropic_messages_url():
    base = anthropic_base_url()
    if base.endswith("/v1"):
        return base + "/messages"
    return base + "/v1/messages"


def anthropic_headers(request_authorization):
    """Real Anthropic first (Claude Code's keychain OAuth), then Claude Code's
    settings.json env, then a request-level API key."""
    token = _anthropic_oauth_token()
    if token:
        return {
            "Authorization": "Bearer " + token,
            "anthropic-version": "2023-06-01",
            "anthropic-beta": "oauth-2025-04-20",
        }
    env = claude_settings_env()
    token = (env.get("ANTHROPIC_AUTH_TOKEN") or "").strip()
    if token:
        return {
            "Authorization": "Bearer " + token,
            "anthropic-version": "2023-06-01",
        }
    key = (request_authorization or "").replace("Bearer ", "").strip()
    return {
        "x-api-key": key,
        "anthropic-version": "2023-06-01",
    }


def _input_to_text(part):
    t = part.get("type", "")
    if t in ("input_text", "output_text", "text"):
        return part.get("text", "")
    if t == "input_image":
        return "[image]"
    return ""


def responses_to_anthropic(body):
    """Translate a Responses API request body to an Anthropic Messages body."""
    model = body.get("model") or MODELS[0]
    max_tokens = body.get("max_output_tokens") or 4096
    raw = body.get("input")
    messages = []
    system_parts = []
    if isinstance(raw, str):
        messages.append({"role": "user", "content": raw})
    elif isinstance(raw, list):
        for item in raw:
            t = item.get("type")
            if t == "message":
                role = item.get("role") or "user"
                content = item.get("content")
                if role in ("developer", "system"):
                    # Anthropic has no developer role: fold into the system prompt.
                    parts = content if isinstance(content, list) else [{"type": "text", "text": content}]
                    text = "".join(_input_to_text(p) for p in parts).strip()
                    if text:
                        system_parts.append(text)
                    continue
                blocks = []
                if isinstance(content, str):
                    blocks.append({"type": "text", "text": content})
                elif isinstance(content, list):
                    for part in content:
                        pt = part.get("type")
                        if pt in ("input_text", "output_text", "text"):
                            text = part.get("text", "")
                            if text and blocks and blocks[-1].get("type") == "text":
                                blocks[-1]["text"] += text
                            elif text:
                                blocks.append({"type": "text", "text": text})
                        elif pt == "function_call_output":
                            blocks.append({
                                "type": "tool_result",
                                "tool_use_id": part.get("call_id", ""),
                                "content": part.get("output", ""),
                            })
                if blocks:
                    messages.append({"role": role, "content": blocks})
            elif t == "function_call":
                args = item.get("arguments", "{}")
                try:
                    args = json.loads(args) if isinstance(args, str) else args
                except Exception:
                    args = {}
                messages.append({
                    "role": "assistant",
                    "content": [{
                        "type": "tool_use",
                        "id": item.get("call_id") or f"toolu_{uuid.uuid4().hex[:24]}",
                        "name": item.get("name", "unknown"),
                        "input": args,
                    }],
                })
    out = {"model": model, "max_tokens": max_tokens, "messages": messages}
    system = body.get("instructions")
    if system_parts:
        system = "\n\n".join([s for s in ([system] if system else []) + system_parts if s])
    if system:
        out["system"] = system
    tools = []
    for t in body.get("tools") or []:
        if t.get("type") == "function":
            fn = t.get("function", {})
            tools.append({
                "name": fn.get("name", "unknown"),
                "description": fn.get("description", ""),
                "input_schema": fn.get("parameters", {"type": "object", "properties": {}}),
            })
    if tools:
        out["tools"] = tools
    return out


def anthropic_to_responses(resp, model, rid=None):
    """Translate a non-streaming Anthropic response to the Responses API shape."""
    content = resp.get("content", [])
    texts = [b.get("text", "") for b in content if b.get("type") == "text"]
    tool_calls = [b for b in content if b.get("type") == "tool_use"]
    output = []
    if texts:
        output.append({
            "type": "message",
            "id": f"msg_{uuid.uuid4().hex[:24]}",
            "status": "completed",
            "role": "assistant",
            "content": [{"type": "output_text", "text": "".join(texts)}],
        })
    for tc in tool_calls:
        output.append({
            "type": "function_call",
            "id": f"fc_{uuid.uuid4().hex[:24]}",
            "call_id": tc.get("id", f"toolu_{uuid.uuid4().hex[:24]}"),
            "name": tc.get("name", "unknown"),
            "arguments": json.dumps(tc.get("input", {})),
            "status": "completed",
        })
    usage = resp.get("usage", {})
    it = usage.get("input_tokens", 0)
    ot = usage.get("output_tokens", 0)
    return {
        "id": rid or f"resp_{uuid.uuid4().hex[:24]}",
        "object": "response",
        "created_at": int(time.time()),
        "status": "completed",
        "model": model,
        "output": output,
        "usage": {
            "input_tokens": it,
            "output_tokens": ot,
            "total_tokens": it + ot,
        },
    }


def sse(obj):
    return f"data: {json.dumps(obj)}\n\n".encode()


class AnthropicStreamTranslator:
    """Consumes Anthropic SSE lines, emits Responses API SSE."""

    def __init__(self, model):
        self.model = model
        self.rid = f"resp_{uuid.uuid4().hex[:24]}"
        self.response = {"id": self.rid, "object": "response", "created_at": int(time.time()),
                         "status": "in_progress", "model": model, "output": [], "usage": {}}
        self.sent_created = False
        self.current_tool = None
        self.text_item_id = None
        self.input_tokens = 0
        self.output_tokens = 0

    def _usage(self):
        return {
            "input_tokens": self.input_tokens,
            "output_tokens": self.output_tokens,
            "total_tokens": self.input_tokens + self.output_tokens,
        }

    def feed(self, line):
        if not line.startswith("data: "):
            return b""
        payload = line[6:].strip()
        if not payload or payload == "[DONE]":
            return b""
        try:
            event = json.loads(payload)
        except Exception:
            return b""
        etype = event.get("type")
        chunks = []
        if not self.sent_created:
            chunks.append(sse({"type": "response.created", "response": self.response}))
            chunks.append(sse({"type": "response.in_progress", "response": self.response}))
            self.sent_created = True
        if etype == "message_start":
            usage = (event.get("message") or {}).get("usage") or {}
            self.input_tokens = usage.get("input_tokens", 0) or 0
        elif etype == "content_block_start":
            block = event.get("content_block", {})
            if block.get("type") == "text":
                self.text_item_id = f"msg_{uuid.uuid4().hex[:24]}"
                chunks.append(sse({
                    "type": "response.output_item.added",
                    "output_index": len(self.response["output"]),
                    "item": {"type": "message", "id": self.text_item_id, "status": "in_progress",
                             "role": "assistant", "content": []},
                }))
                chunks.append(sse({
                    "type": "response.content_part.added",
                    "item_id": self.text_item_id,
                    "output_index": len(self.response["output"]),
                    "content_index": 0,
                    "part": {"type": "output_text", "text": ""},
                }))
            elif block.get("type") == "tool_use":
                self.current_tool = {
                    "type": "function_call",
                    "id": f"fc_{uuid.uuid4().hex[:24]}",
                    "call_id": block.get("id", ""),
                    "name": block.get("name", ""),
                    "arguments": "",
                    "status": "in_progress",
                }
                chunks.append(sse({
                    "type": "response.output_item.added",
                    "output_index": len(self.response["output"]),
                    "item": dict(self.current_tool),
                }))
        elif etype == "content_block_delta":
            delta = event.get("delta", {})
            if delta.get("type") == "text_delta":
                text = delta.get("text", "")
                chunks.append(sse({"type": "response.output_text.delta",
                                   "item_id": self.text_item_id,
                                   "output_index": len(self.response["output"]),
                                   "content_index": 0,
                                   "delta": text}))
            elif delta.get("type") == "input_json_delta" and self.current_tool:
                self.current_tool["arguments"] += delta.get("partial_json", "")
        elif etype == "content_block_stop":
            if self.current_tool is not None:
                chunks.append(sse({
                    "type": "response.output_item.done",
                    "output_index": len(self.response["output"]),
                    "item": {**self.current_tool, "status": "completed"},
                }))
                self.current_tool = None
            elif self.text_item_id is not None:
                chunks.append(sse({
                    "type": "response.content_part.done",
                    "item_id": self.text_item_id,
                    "output_index": len(self.response["output"]),
                    "content_index": 0,
                    "part": {"type": "output_text", "text": ""},
                }))
                chunks.append(sse({
                    "type": "response.output_item.done",
                    "output_index": len(self.response["output"]),
                    "item": {"type": "message", "id": self.text_item_id, "status": "completed",
                             "role": "assistant", "content": []},
                }))
                self.text_item_id = None
        elif etype == "message_delta":
            usage = event.get("usage") or {}
            self.output_tokens = usage.get("output_tokens", self.output_tokens) or self.output_tokens
        elif etype == "message_stop":
            self.response["status"] = "completed"
            self.response["usage"] = self._usage()
            chunks.append(sse({"type": "response.completed", "response": self.response}))
            chunks.append(sse({"type": "response.done", "response": self.response}))
        return b"".join(chunks)


# ---------------------------------------------------------------------------
# HTTP handler
# ---------------------------------------------------------------------------

def do_anthropic_request(body_bytes, headers, stream):
    """POST /v1/responses translated to the Anthropic-compatible /v1/messages."""
    req = json.loads(body_bytes.decode("utf-8"))
    anth = responses_to_anthropic(req)
    if stream:
        anth["stream"] = True
    url = anthropic_messages_url()
    hdrs = anthropic_headers(headers.get("Authorization", ""))
    hdrs["Content-Type"] = "application/json"
    up = urllib.request.Request(url, data=json.dumps(anth).encode(), headers=hdrs, method="POST")
    try:
        resp = urllib.request.urlopen(up, context=ssl_context())
    except urllib.error.HTTPError as e:
        return e.code, e.read(), "application/json"
    if stream:
        return 200, _stream(resp, req.get("model")), "text/event-stream"
    body = json.loads(resp.read().decode("utf-8"))
    out = anthropic_to_responses(body, req.get("model"))
    return 200, json.dumps(out).encode(), "application/json"


def _stream(upstream_resp, model):
    translator = AnthropicStreamTranslator(model)
    def gen():
        for raw in upstream_resp:
            for line in raw.decode("utf-8", "replace").split("\n"):
                out = translator.feed(line)
                if out:
                    yield out
    return gen()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/v1/models") or self.path.startswith("/models"):
            body = models_response()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.relay()

    def do_POST(self):
        if ADAPTER == "anthropic" and self.path.startswith("/v1/responses"):
            length = int(self.headers.get("Content-Length") or 0)
            data = self.rfile.read(length) if length else None
            stream = False
            model = "?"
            tools = 0
            if data:
                try:
                    req = json.loads(data)
                    stream = bool(req.get("stream"))
                    model = req.get("model", "?")
                    tools = len(req.get("tools") or [])
                except Exception:
                    pass
            sys.stderr.write("[proxy %s] POST %s model=%s tools=%s stream=%s\n"
                             % (DISPLAY, self.path, model, tools, stream))
            code, body, ctype = do_anthropic_request(data or b"{}", self.headers, stream)
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            if isinstance(body, bytes):
                self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if isinstance(body, bytes):
                self.wfile.write(body)
            else:  # generator (streaming)
                for chunk in body:
                    try:
                        self.wfile.write(chunk)
                        self.wfile.flush()
                    except Exception:
                        break
            return
        if self.path.startswith("/v1/responses"):
            length = int(self.headers.get("Content-Length") or 0)
            data = self.rfile.read(length) if length else None
            model, tools = "?", 0
            if data:
                try:
                    req = json.loads(data)
                    model = req.get("model", "?")
                    tools = len(req.get("tools") or [])
                except Exception:
                    pass
            sys.stderr.write("[proxy %s] POST %s model=%s tools=%s\n"
                             % (DISPLAY, self.path, model, tools))
        self.relay()

    def do_DELETE(self):
        self.relay()

    def relay(self):
        url = UPSTREAM + self.path
        length = int(self.headers.get("Content-Length") or 0)
        data = self.rfile.read(length) if length else None
        headers = {k: v for k, v in self.headers.items()
                   if k.lower() not in ("host", "accept-encoding")}
        req = urllib.request.Request(url, data=data, headers=headers, method=self.command)
        try:
            with urllib.request.urlopen(req, context=ssl_context()) as resp:
                body = resp.read()
                self.send_response(resp.status)
                for k, v in resp.headers.items():
                    if k.lower() in ("content-type", "content-length", "connection"):
                        self.send_header(k, v)
                self.end_headers()
                self.wfile.write(body)
        except urllib.error.HTTPError as e:
            body = e.read()
            self.send_response(e.code)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(body)
        except Exception as e:
            self.send_response(502)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"error": str(e)}).encode())

    def log_message(self, fmt, *args):
        sys.stderr.write("[proxy %s] %s %s\n" % (DISPLAY, self.command, self.path))


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"proxy {DISPLAY} ({ADAPTER}) sur http://127.0.0.1:{PORT}", flush=True)
    server.serve_forever()
