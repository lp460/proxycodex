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


# ---------------------------------------------------------------------------
# Helper: when the client (Codex Desktop) sends zero tools, the model keeps
# describing tool calls it can never execute. Inject a note so it answers in
# plain text instead. CLI sessions send tools (>0) and are left untouched.
# ---------------------------------------------------------------------------

NO_TOOLS_NOTE = ("Note système : aucun outil n'est disponible dans cette session "
                 "et aucune exécution d'outil ne se produira. Ne décris pas et ne "
                 "planifie pas d'appels d'outils ; réponds directement en texte "
                 "à la demande de l'utilisateur.")

TOOL_UNAVAILABLE_OUTPUT = ("Outil non disponible dans cette session : aucune exécution "
                           "d'outil n'est possible. Réponds directement à la demande "
                           "de l'utilisateur, sans appeler d'outil.")


def apply_no_tools_note(req, tools_count):
    if tools_count > 0:
        return req
    raw = req.get("input")
    note_item = {
        "type": "message",
        "role": "developer",
        "content": [{"type": "input_text", "text": NO_TOOLS_NOTE}],
    }
    if isinstance(raw, list):
        req["input"] = raw + [note_item]
    elif isinstance(raw, str):
        req["input"] = [{"type": "message", "role": "user", "content": raw}, note_item]
    else:
        req["input"] = [note_item]
    return req


def has_function_calls(response):
    return any(i.get("type") == "function_call" for i in (response or {}).get("output", []))


def append_synthetic_tool_results(req, response):
    """Answer every pending function_call with 'tool unavailable' so the model
    can finish with a plain-text answer."""
    history = req.get("input")
    if not isinstance(history, list):
        history = [{"type": "message", "role": "user", "content": history}]
    new_input = history + (response.get("output") or [])
    for item in (response.get("output") or []):
        if item.get("type") == "function_call":
            new_input.append({
                "type": "function_call_output",
                "call_id": item.get("call_id", ""),
                "output": TOOL_UNAVAILABLE_OUTPUT,
            })
    req["input"] = new_input
    req["stream"] = False
    return req


def emit_stream_from_response(resp):
    """Emit a valid Responses-API SSE stream from a completed response object."""
    events = [{"type": "response.created", "response": resp},
              {"type": "response.in_progress", "response": resp}]
    for idx, item in enumerate(resp.get("output", [])):
        itype = item.get("type")
        events.append({"type": "response.output_item.added", "output_index": idx, "item": item})
        if itype in ("reasoning", "message"):
            delta_key = "reasoning_text.delta" if itype == "reasoning" else "output_text.delta"
            done_key = "reasoning_text.done" if itype == "reasoning" else "output_text.done"
            for ci, part in enumerate(item.get("content") or []):
                events.append({"type": "response.content_part.added", "item_id": item.get("id"),
                               "output_index": idx, "content_index": ci, "part": part})
                events.append({"type": "response." + delta_key, "item_id": item.get("id"),
                               "output_index": idx, "content_index": ci, "delta": part.get("text", "")})
                events.append({"type": "response." + done_key, "item_id": item.get("id"),
                               "output_index": idx, "content_index": ci, "text": part.get("text", "")})
                events.append({"type": "response.content_part.done", "item_id": item.get("id"),
                               "output_index": idx, "content_index": ci, "part": part})
        events.append({"type": "response.output_item.done", "output_index": idx, "item": item})
    events.append({"type": "response.completed", "response": resp})
    events.append({"type": "response.done", "response": resp})
    return b"".join(sse(e) for e in events)


def post_responses_json(url, req, headers, timeout=180):
    """POST a Responses-API request, return the parsed JSON response."""
    up = urllib.request.Request(url, data=json.dumps(req).encode(), headers=headers, method="POST")
    with urllib.request.urlopen(up, context=ssl_context(), timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def complete_tool_calls_relay(upstream_url, req, headers, response, max_rounds=2):
    """Loop until the model answers in text: each round answers pending
    function_calls with 'tool unavailable' and re-asks the model."""
    for _ in range(max_rounds):
        if not has_function_calls(response):
            return response
        req = append_synthetic_tool_results(req, response)
        response = post_responses_json(upstream_url + "/v1/responses", req, headers)
    return response


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

def complete_tool_calls_anthropic(req, hdrs, resp_object, max_rounds=2):
    """Answer pending function_calls with 'tool unavailable' (Anthropic path)."""
    for _ in range(max_rounds):
        if not has_function_calls(resp_object):
            return resp_object
        req = append_synthetic_tool_results(req, resp_object)
        anth = responses_to_anthropic(req)
        anth["stream"] = False
        up = urllib.request.Request(
            anthropic_messages_url(), data=json.dumps(anth).encode(), headers=hdrs, method="POST")
        with urllib.request.urlopen(up, context=ssl_context(), timeout=180) as r:
            anth_resp = json.loads(r.read().decode("utf-8"))
        resp_object = anthropic_to_responses(anth_resp, req.get("model"), resp_object.get("id"))
    return resp_object


def do_anthropic_request(body_bytes, headers, stream):
    """POST /v1/responses translated to the Anthropic-compatible /v1/messages."""
    req = json.loads(body_bytes.decode("utf-8"))
    tools_count = len(req.get("tools") or [])
    req = apply_no_tools_note(req, tools_count)
    anth = responses_to_anthropic(req)
    if stream:
        anth["stream"] = True
    url = anthropic_messages_url()
    hdrs = anthropic_headers(headers.get("Authorization", ""))
    hdrs["Content-Type"] = "application/json"
    up = urllib.request.Request(url, data=json.dumps(anth).encode(), headers=hdrs, method="POST")
    try:
        resp = urllib.request.urlopen(up, context=ssl_context(), timeout=180)
    except urllib.error.HTTPError as e:
        return e.code, e.read(), "application/json"
    if stream and tools_count > 0:
        return 200, _stream(resp, req.get("model")), "text/event-stream"
    if stream:
        translator = AnthropicStreamTranslator(req.get("model"))
        for raw in resp:
            for line in raw.decode("utf-8", "replace").split("\n"):
                translator.feed(line)
        final = translator.response
        if req and has_function_calls(final):
            final = complete_tool_calls_anthropic(req, hdrs, final)
        final["id"] = final.get("id") or f"resp_{uuid.uuid4().hex[:24]}"
        final["status"] = "completed"
        return 200, emit_stream_from_response(final), "text/event-stream"
    body = json.loads(resp.read().decode("utf-8"))
    out = anthropic_to_responses(body, req.get("model"))
    if req and has_function_calls(out):
        out = complete_tool_calls_anthropic(req, hdrs, out)
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
        length = int(self.headers.get("Content-Length") or 0)
        data = self.rfile.read(length) if length else None
        model, tools, stream = "?", 0, False
        if data:
            try:
                req = json.loads(data)
                model = req.get("model", "?")
                tools = len(req.get("tools") or [])
                stream = bool(req.get("stream"))
            except Exception:
                pass
        sys.stderr.write("[proxy %s] POST %s model=%s tools=%s stream=%s\n"
                         % (DISPLAY, self.path, model, tools, stream))
        if data:
            try:
                req = json.loads(data)
                inp = req.get("input")
                if isinstance(inp, str):
                    prompt = inp
                elif isinstance(inp, list):
                    prompt = " ".join(
                        (p.get("content") or "") if isinstance(p, dict) else ""
                        for p in inp
                        if isinstance(p, dict) and p.get("type") == "message"
                        and isinstance(p.get("content"), str))
                else:
                    prompt = ""
                flag = "REMINDERS" if "system_reminder" in (inp and json.dumps(inp) or "") else "clean"
                sys.stderr.write("[proxy %s] prompt: %s | %s\n"
                                 % (DISPLAY, flag, prompt[:300].replace("\n", " ")))
            except Exception:
                pass
        if ADAPTER == "anthropic" and self.path.startswith("/v1/responses"):
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
        self.relay(body_bytes=data)

    def do_DELETE(self):
        self.relay()

    def relay(self, body_bytes=None):
        url = UPSTREAM + self.path
        if body_bytes is None:
            length = int(self.headers.get("Content-Length") or 0)
            body_bytes = self.rfile.read(length) if length else None
        tools_count = 0
        req = None
        if body_bytes and self.path.startswith("/v1/responses"):
            try:
                req = json.loads(body_bytes)
                tools_count = len(req.get("tools") or [])
                req = apply_no_tools_note(req, tools_count)
                body_bytes = json.dumps(req).encode()
            except Exception:
                req = None
        headers = {k: v for k, v in self.headers.items()
                   if k.lower() not in ("host", "accept-encoding", "content-length", "transfer-encoding")}
        try:
            with urllib.request.urlopen(
                    urllib.request.Request(url, data=body_bytes, headers=headers, method=self.command),
                    context=ssl_context(), timeout=180) as resp:
                ctype = resp.headers.get("Content-Type", "")
                if "event-stream" in ctype and tools_count > 0:
                    # CLI sessions: live streaming, untouched.
                    self.send_response(resp.status)
                    for k, v in resp.headers.items():
                        if k.lower() in ("content-type", "content-length", "connection"):
                            self.send_header(k, v)
                    self.end_headers()
                    while True:
                        chunk = resp.read(4096)
                        if not chunk:
                            break
                        self.wfile.write(chunk)
                        self.wfile.flush()
                    return
                body = resp.read()
                if "event-stream" in ctype:
                    # Desktop (tools=0): buffer the stream, extract the final
                    # response object, complete pending tool calls, re-emit.
                    completed = None
                    for line in body.decode("utf-8", "replace").split("\n"):
                        if line.startswith("data: "):
                            try:
                                event = json.loads(line[6:])
                            except Exception:
                                continue
                            if event.get("type") == "response.completed":
                                completed = event.get("response")
                    final = completed or {}
                else:
                    final = json.loads(body.decode("utf-8"))
                if req and has_function_calls(final):
                    final = complete_tool_calls_relay(url, req, headers, final)
                    final["id"] = final.get("id") or f"resp_{uuid.uuid4().hex[:24]}"
                    final["object"] = "response"
                    final["status"] = "completed"
                payload = (emit_stream_from_response(final)
                           if "event-stream" in ctype else json.dumps(final).encode())
                self.send_response(200)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
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
