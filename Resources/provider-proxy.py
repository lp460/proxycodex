#!/usr/bin/env python3
"""Local adapter proxies for third-party providers used by Codex Desktop.

Codex Desktop expects provider model lists in its own catalog schema
(`{"models": [...]}`) and speaks the OpenAI Responses API. This proxy:

- relay mode    (OpenAI-compatible upstreams): translates GET /v1/models and
                 relays everything else with auth intact.
- anthropic mode (Claude): translates GET /v1/models AND POST /v1/responses
                 (Responses API <-> Anthropic Messages API), including SSE
                 streaming and tool calls.
- opencode modes (OpenCode Zen / Go): relay, plus auth resolved from OpenCode's
                 own credentials — Codex sends none for the keyless Zen provider.

Both modes bridge Codex's native tool flavors (freeform custom tools such as
apply_patch, `local_shell`, MCP function tools) so every provider gets the same
agentic feature set as OpenAI. See "Tool bridge" below.

Model masquerading: `<model1,model2...>` are the slugs Codex sees (its own model
slugs, so its full native feature contract applies) and the optional
`<real1,real2...>` are the provider models that really answer them, in the same
order. The adapter swaps the name on the way out and restores it on the way in,
so Codex never sees a slug it does not recognize.

Usage: provider-proxy.py <port> <upstream_base> <display_name> <model1,model2...> [relay|anthropic|opencode|opencode-go] [tools] [apply_patch] [images] [web_search] [parallel_tools] [custom_tools] [real1,real2...]
"""
import json
import hashlib
import os
import re
import subprocess
import ssl
import sys
import threading
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
SUPPORTS_TOOLS = len(sys.argv) > 6 and sys.argv[6] == "1"
SUPPORTS_APPLY_PATCH = len(sys.argv) > 7 and sys.argv[7] == "1"
SUPPORTS_IMAGES = len(sys.argv) > 8 and sys.argv[8] == "1"
SUPPORTS_WEB_SEARCH = len(sys.argv) > 9 and sys.argv[9] == "1"
SUPPORTS_PARALLEL_TOOLS = len(sys.argv) > 10 and sys.argv[10] == "1"
# Codex's non-function tool flavors (freeform custom tools, local_shell) are an
# OpenAI-only wire contract. Every other provider gets them bridged to function
# tools, so the capability is advertised as `function` in the catalog.
SUPPORTS_CUSTOM_TOOLS = len(sys.argv) > 11 and sys.argv[11] == "1"

# OpenRouter chooses very large completion budgets by default (GPT models can
# ask for 64k+ tokens). That budget is pre-authorized against credits before
# execution, so low-balance accounts receive HTTP 402 even for tiny prompts.
# Relay mode therefore always provides a practical explicit ceiling.
IS_OPENROUTER = "openrouter.ai" in UPSTREAM
OPENROUTER_MAX_OUTPUT_TOKENS = 16384

# Model masquerading: MODELS are the slugs Codex believes are native, REAL_MODELS
# the provider models answering them. Codex gates part of its feature set on the
# model it thinks it is talking to, so the slug must stay one of its own.
REAL_MODELS = [m for m in sys.argv[12].split(",") if m] if len(sys.argv) > 12 else []
if len(REAL_MODELS) < len(MODELS):
    REAL_MODELS += MODELS[len(REAL_MODELS):]
SLUG_TO_MODEL = dict(zip(MODELS, REAL_MODELS))
MASQUERADE = any(slug != model for slug, model in SLUG_TO_MODEL.items())


def upstream_model(name):
    """Real provider model behind a slug. A real model name passes through, so
    probes that already use it keep working."""
    return SLUG_TO_MODEL.get(name, name)


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
    # Optional fields are omitted instead of serialized as null: Codex's
    # catalog parser expects strings/maps when these keys are present.
    # `function` is the portable apply_patch flavor: the freeform variant is an
    # OpenAI-only wire contract, and the bridge turns it into a function tool.
    "apply_patch_tool_type": (("freeform" if (SUPPORTS_CUSTOM_TOOLS or MASQUERADE) else "function")
                              if SUPPORTS_APPLY_PATCH else None),
    "web_search_tool_type": "text_and_image" if SUPPORTS_WEB_SEARCH else None,
    "truncation_policy": {"mode": "tokens", "limit": 10000},
    "supports_parallel_tool_calls": SUPPORTS_PARALLEL_TOOLS,
    "supports_image_detail_original": SUPPORTS_IMAGES,
    "experimental_supported_tools": [],
    "input_modalities": ["text", "image"] if SUPPORTS_IMAGES else ["text"],
    "supports_search_tool": SUPPORTS_WEB_SEARCH,
    "use_responses_lite": False,
    # Plugins, MCP servers and skills are executed by Codex itself, so their
    # usage instructions must reach every provider, not just OpenAI.
    "include_plugin_usage_instructions": True,
    "include_apps_usage_instructions": True,
    "include_skills_usage_instructions": True,
    # `code_mode_only` routes every tool through a freeform custom tool, which
    # only OpenAI implements on the wire.
    "tool_mode": "code_mode_only" if (SUPPORTS_APPLY_PATCH and SUPPORTS_CUSTOM_TOOLS) else None,
    "multi_agent_version": None,
}


def _without_nulls(value):
    """Codex rejects null-valued catalog fields; omit them recursively."""
    if value is None:
        return None
    if isinstance(value, dict):
        return {k: clean for k, v in value.items()
                if (clean := _without_nulls(v)) is not None}
    if isinstance(value, list):
        return [clean for item in value
                if (clean := _without_nulls(item)) is not None]
    return value


def models_response():
    entries = []
    for i, slug in enumerate(MODELS, start=50):
        e = dict(ENTRY_TEMPLATE)
        e["slug"] = slug
        real = upstream_model(slug)
        # The slug is what Codex checks; the display name still names the
        # provider and model that really answer.
        e["display_name"] = f"{DISPLAY} · {slug}" if real == slug else f"{slug} · {DISPLAY}"
        e["description"] = f"{DISPLAY} model {real}."
        e["priority"] = i
        entries.append(_without_nulls(e))
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


def managed_credential():
    """Private credential the app holds for this provider, if any. It is the
    single source of truth: the panel writes it, the proxy applies it."""
    return os.environ.get("AI_PROVIDER_SWITCHER_PROXY_API_KEY", "").strip()


def managed_headers(headers):
    """Relay headers carrying the managed credential. When the app has one it
    replaces any Authorization the client still sends (a stale env_key, for
    instance), so changing the key in the panel is enough."""
    credential = managed_credential()
    if not credential:
        return dict(headers)
    out = {k: v for k, v in headers.items() if k.lower() != "authorization"}
    out["Authorization"] = "Bearer " + credential
    return out


def codex_config_env():
    """ANTHROPIC_* variables Codex itself is told to export
    (`~/.codex/config.toml`, `[shell_environment_policy.set]`).

    Claude Code can be pointed at a compatible gateway (Z.ai, etc.) through
    these variables; the adapter must follow the same contract, otherwise the
    provider works in Claude Code and fails here.
    """
    try:
        with open(os.path.expanduser("~/.codex/config.toml")) as f:
            text = f.read()
    except Exception:
        return {}
    env = {}
    in_section = False
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("["):
            in_section = line.replace(" ", "") == "[shell_environment_policy.set]"
            continue
        if not in_section:
            continue
        match = re.match(r'^([A-Za-z0-9_]+)\s*=\s*"(.*)"\s*$', line)
        if match:
            value = match.group(2).replace('\\"', '"').replace("\\\\", "\\")
            env[match.group(1)] = value
    return env


def _anthropic_sources():
    """(base_url, headers) candidates, most authoritative first.

    One provider, one authentication path: the switcher-managed credential,
    then Claude Code's own keychain OAuth, then the ANTHROPIC_* environment
    (%s or ~/.codex/config.toml) that Claude Code itself follows.
    """ % ("~/.claude/settings.json")
    managed = managed_credential()
    if managed:
        yield UPSTREAM, {"x-api-key": managed, "anthropic-version": "2023-06-01"}
    oauth = _anthropic_oauth_token()
    if oauth:
        yield UPSTREAM, {
            "Authorization": "Bearer " + oauth,
            "anthropic-version": "2023-06-01",
            "anthropic-beta": "oauth-2025-04-20",
        }
    for env in (claude_settings_env(), codex_config_env()):
        token = (env.get("ANTHROPIC_AUTH_TOKEN")
                 or env.get("ANTHROPIC_API_KEY")
                 or "").strip()
        base = (env.get("ANTHROPIC_BASE_URL") or "").strip().rstrip("/")
        if token and base:
            yield base, {
                "Authorization": "Bearer " + token,
                "anthropic-version": "2023-06-01",
            }


def anthropic_credentials(request_authorization=""):
    """Resolve `(base_url, headers)` for the Anthropic adapter. Headers are
    None when nothing can authenticate: the caller reports it instead of
    sending an empty x-api-key upstream."""
    for base, headers in _anthropic_sources():
        return base, headers
    key = (request_authorization or "").replace("Bearer ", "").strip()
    if key:
        return UPSTREAM, {"x-api-key": key, "anthropic-version": "2023-06-01"}
    return UPSTREAM, None


def anthropic_base_url():
    return anthropic_credentials()[0]


def anthropic_messages_url():
    base = anthropic_base_url()
    if base.endswith("/v1"):
        return base + "/messages"
    return base + "/v1/messages"


def anthropic_headers(request_authorization):
    return anthropic_credentials(request_authorization)[1] or {}


# ---------------------------------------------------------------------------
# OpenCode Zen / Go: OpenAI-compatible gateways. Auth follows OpenCode's own
# credentials, so a stored credential does not have to be typed again:
#   1. a key supplied by the request (a paid key relayed by Codex);
#   2. the matching `opencode` / `opencode-go` entry in
#      ~/.local/share/opencode/auth.json;
#   3. the documented public key (Zen free tier only).
# ---------------------------------------------------------------------------

OPENCODE_PUBLIC_KEY = "public"
OPENCODE_AUTH_PATH = "~/.local/share/opencode/auth.json"


def opencode_stored_key(provider_id="opencode"):
    try:
        with open(os.path.expanduser(OPENCODE_AUTH_PATH)) as f:
            entry = json.load(f).get(provider_id) or {}
    except Exception:
        return None
    if isinstance(entry, str):
        return entry.strip() or None
    if isinstance(entry, dict):
        for field in ("key", "apiKey", "api_key", "token", "access"):
            value = entry.get(field)
            if isinstance(value, str) and value.strip():
                return value.strip()
    return None


def opencode_authorization(request_authorization=None, provider_id="opencode"):
    managed = managed_credential()
    if managed:
        return "Bearer " + managed
    supplied = (request_authorization or "").replace("Bearer ", "").strip()
    go_credential = opencode_stored_key(provider_id) if provider_id == "opencode-go" else None
    fallback = (go_credential
                or (opencode_stored_key("opencode") if provider_id == "opencode" else None)
                or (OPENCODE_PUBLIC_KEY if provider_id == "opencode" else ""))
    credential = supplied or fallback
    return ("Bearer " + credential) if credential else ""


def opencode_go_identity_headers(body_bytes):
    """Headers Go uses for routing and prompt-cache affinity.

    Codex does not expose a portable conversation ID on the Responses wire, so
    derive a stable one from its explicit IDs when present, or from the first
    user message otherwise. The request fingerprint changes with each turn,
    exactly like OpenCode's own per-message ID.
    """
    body = {}
    if body_bytes:
        try:
            body = json.loads(body_bytes)
        except Exception:
            body = {}
    conversation_source = (body.get("session_id")
                           or body.get("previous_response_id")
                           or "")
    if not conversation_source:
        items = body.get("input") if isinstance(body.get("input"), list) else []
        for item in items:
            if not isinstance(item, dict) or item.get("type") not in (None, "message"):
                continue
            content = item.get("content")
            if isinstance(content, str) and content.strip():
                conversation_source = content
                break
            if isinstance(content, list):
                text = "".join(part.get("text", "") for part in content
                               if isinstance(part, dict))
                if text.strip():
                    conversation_source = text
                    break
    session = hashlib.sha256(str(conversation_source).encode("utf-8")).hexdigest()[:32]
    request = hashlib.sha256(json.dumps(body, sort_keys=True, ensure_ascii=False,
                                        default=str).encode("utf-8")).hexdigest()[:32]
    return {
        "x-opencode-project": "ai-provider-switcher",
        "x-opencode-session": "aips-" + session,
        "x-opencode-request": "aips-" + request,
        "x-opencode-client": "ai-provider-switcher",
        "User-Agent": "AIProviderSwitcher/1.0",
    }


# ---------------------------------------------------------------------------
# Dynamic model discovery
#
# The declared model lists go stale as providers ship new models. This asks the
# provider what it really serves: the adapter is the only component that knows
# both the upstream URL and how to authenticate to it.
# ---------------------------------------------------------------------------

OPENCODE_CLI_PATHS = ["~/.opencode/bin/opencode", "/opt/homebrew/bin/opencode",
                      "/usr/local/bin/opencode", "~/.local/bin/opencode",
                      "/usr/bin/opencode"]


def _get_json(url, headers, timeout=20):
    request = urllib.request.Request(url, headers=headers, method="GET")
    with urllib.request.urlopen(request, context=ssl_context(), timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def _ids_from_models_payload(payload):
    """Accepts the OpenAI shape (`{"data": [{"id": …}]}`) and the Codex catalog
    shape (`{"models": [{"slug": …}]}`)."""
    items = []
    if isinstance(payload, dict):
        items = payload.get("data") or payload.get("models") or []
    elif isinstance(payload, list):
        items = payload
    ids = []
    for item in items:
        if isinstance(item, str):
            ids.append(item)
        elif isinstance(item, dict):
            value = item.get("id") or item.get("slug") or item.get("name")
            if isinstance(value, str):
                ids.append(value)
    # Deduplicate while keeping the provider's own ordering.
    seen = set()
    return [i for i in ids if not (i in seen or seen.add(i))]


def opencode_cli_models():
    """`opencode models opencode` lists the free tier the public key can reach,
    which the gateway's own /v1/models does not distinguish."""
    for path in OPENCODE_CLI_PATHS:
        binary = os.path.expanduser(path)
        if not os.access(binary, os.X_OK):
            continue
        try:
            out = subprocess.run([binary, "models", "opencode"],
                                 capture_output=True, text=True, timeout=30,
                                 cwd=os.path.expanduser("~"))
        except Exception:
            return []
        if out.returncode != 0:
            return []
        ids = []
        for line in (out.stdout or "").splitlines():
            line = line.strip()
            if not line or "/" not in line:
                continue
            provider_id, _, model = line.partition("/")
            if provider_id == "opencode" and model:
                ids.append(model)
        return ids
    return []


OPENCODE_GO_RESPONSE_MODELS = {
    "grok-4.6",
    "gpt-5.6-luna",
    "muse-spark-1.3-contributor",
    "muse-spark-1.2-contributor",
}


def upstream_models(request_authorization):
    """Model ids the provider really serves, with the source used."""
    if ADAPTER == "opencode":
        ids = opencode_cli_models()
        if ids:
            return ids, "opencode-cli"
        headers = {"Authorization": opencode_authorization(request_authorization)}
        return _ids_from_models_payload(_get_json(UPSTREAM + "/v1/models", headers)), "gateway"
    if ADAPTER == "opencode-go":
        headers = {"Authorization": opencode_authorization(
            request_authorization, provider_id="opencode-go")}
        headers.update(opencode_go_identity_headers(b""))
        ids = _ids_from_models_payload(_get_json(UPSTREAM + "/v1/models", headers))
        # Most Go models speak Chat Completions. The Responses-shaped endpoint
        # used by Codex is translated below; only these four currently answer
        # Responses directly and can skip that translation.
        return ids, "gateway"
    if ADAPTER == "anthropic":
        headers = anthropic_headers(request_authorization)
        base = anthropic_base_url()
        url = (base + "/models") if base.endswith("/v1") else (base + "/v1/models")
        return _ids_from_models_payload(_get_json(url, headers)), "anthropic"
    headers = {"Accept": "application/json"}
    if request_authorization:
        headers["Authorization"] = request_authorization
    # Bases differ: OpenAI-style ones end in /v1, others carry their own version
    # segment (z.ai: /api/paas/v4). Try both rather than guessing.
    last_error = None
    for path in ("/v1/models", "/models"):
        try:
            ids = _ids_from_models_payload(_get_json(UPSTREAM + path, headers))
        except Exception as error:
            last_error = error
            continue
        if ids:
            return ids, "upstream"
    if last_error is not None:
        raise last_error
    return [], "upstream"


def _input_to_text(part):
    t = part.get("type", "")
    if t in ("input_text", "output_text", "text"):
        return part.get("text", "")
    if t == "input_image":
        return "[image]"
    return ""


def _anthropic_image_block(part):
    """Translate a Responses `input_image` part into an Anthropic image block.

    Codex inlines screenshots and `view_image` results as data URLs; remote URLs
    are passed through as Anthropic's url source. Returns None when the part
    carries no usable image, so the caller can fall back to text.
    """
    url = part.get("image_url")
    if isinstance(url, dict):
        url = url.get("url")
    if not isinstance(url, str) or not url:
        return None
    if url.startswith("data:"):
        header, _, payload = url.partition(",")
        if not payload:
            return None
        media_type = header[5:].split(";")[0] or "image/png"
        return {"type": "image",
                "source": {"type": "base64", "media_type": media_type, "data": payload}}
    return {"type": "image", "source": {"type": "url", "url": url}}


def anthropic_server_tools(tools):
    """Anthropic runs web search itself, so Codex's hosted `web_search` tool has
    a real equivalent here instead of being dropped."""
    if not (SUPPORTS_WEB_SEARCH and SUPPORTS_TOOLS):
        return []
    for tool in (tools or []):
        if isinstance(tool, dict) and tool.get("type") in ("web_search", "web_search_preview"):
            return [{"type": "web_search_20250305", "name": "web_search", "max_uses": 8}]
    return []


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


# ---------------------------------------------------------------------------
# Tool bridge: Codex native tool flavors -> portable function tools
#
# Codex sends several tool flavors in one request:
#   - function tools: `shell`, `update_plan`, `view_image` and every MCP tool;
#   - freeform "custom" tools: `apply_patch`, `exec`, code-mode tools;
#   - the `local_shell` tool;
#   - hosted tools executed provider-side, such as `web_search`;
#   - namespaces: `{"type": "namespace", "name": "collaboration", "tools": [...]}`
#     (`spawn_agent`, `wait_agent`, `send_message`, ...).
# Only OpenAI implements the non-function flavors on the wire. Instead of
# dropping them (which leaves a third-party provider unable to edit files or
# run commands), the bridge rewrites them as function tools on the way out and
# restores the exact item shape Codex expects on the way back. Codex then
# executes them itself — shell, apply_patch, MCP servers, plugins — with any
# provider. Hosted tools stay out unless the provider really serves them.
#
# Namespaces are flattened one level deep: each nested tool becomes the flat
# function `<namespace>__<tool>`, and the round trip restores
# `{"type": "function_call", "namespace": ..., "name": ...}`. Codex expects the
# restored call to carry the namespace again, so the flat name is never used as
# the logical identity — the bridge entry is.
# ---------------------------------------------------------------------------

SAFE_TOOL_NAME = re.compile(r"^[A-Za-z0-9_-]{1,64}$")

# Codex wraps related tools in a namespace (`collaboration`, `functions`, ...).
# Providers only understand flat function tools, so nested tools are published
# as `<namespace>__<tool>`.
NAMESPACE_TOOL_TYPE = "namespace"
NAMESPACE_SEPARATOR = "__"

# Bumped whenever the flatten/restore contract changes, so recorded Multi-Agent
# validations can be re-observed instead of trusted (`stale` in the app).
BRIDGE_CAPABILITY_VERSION = 1

# Freeform custom tools carry one raw string payload; this is the JSON property
# used to transport it through a function tool.
FREEFORM_INPUT_KEY = "input"

LOCAL_SHELL_SCHEMA = {
    "type": "object",
    "properties": {
        "command": {"type": "array", "items": {"type": "string"},
                    "description": "Command and arguments to execute."},
        "workdir": {"type": "string", "description": "Working directory."},
        "timeout_ms": {"type": "integer", "description": "Timeout in milliseconds."},
    },
    "required": ["command"],
}

FREEFORM_TOOL_TYPES = ("custom", "apply_patch", "freeform")

# Tools the provider itself would have to execute. They cannot be bridged: the
# adapter only forwards them when the provider advertises the capability.
HOSTED_TOOL_TYPES = ("web_search", "web_search_preview", "file_search",
                     "image_generation", "computer_use_preview", "code_interpreter")

# Fields scoped to an OpenAI account. Third-party endpoints reject unknown
# parameters, so they are stripped instead of relayed.
OPENAI_ONLY_REQUEST_FIELDS = ("service_tier", "prompt_cache_key", "safety_identifier")

# Reasoning efforts every provider understands. Codex may ask for OpenAI-only
# levels (`xhigh`, `max`, `ultra`, `minimal`), which are clamped.
PORTABLE_REASONING_EFFORTS = {"low", "medium", "high"}

# ---------------------------------------------------------------------------
# Codex-only *input items*
#
# Codex multi-agent sessions send protocol items that no third-party Responses
# endpoint implements, and a strict gateway rejects the whole request over one
# item it cannot parse instead of ignoring it:
#
#   * `agent_message` — the envelope a parent thread hands to a child thread
#     (and the child's answer back). OpenCode Go answers `422`.
#   * a `reasoning` item carrying `encrypted_content` (or `content: null`) —
#     the blob is encrypted for the account that produced it. OpenCode Go
#     answers `400`, even for the blob it sent itself one turn earlier.
#
# Both are translated here rather than relayed. `reasoning` summaries are
# portable; `agent_message` becomes a plain user message, because that is what
# it is to the model that reads it.
# ---------------------------------------------------------------------------

# Item type carrying an inter-agent message.
CODEX_AGENT_MESSAGE_TYPE = "agent_message"

# Item types every Responses-compatible endpoint accepts on input. Anything
# else is Codex-only (or an OpenAI-side hosted-tool artifact), so it is dropped
# instead of taking the whole request down with it.
PORTABLE_INPUT_ITEM_TYPES = ("message", "reasoning", "function_call",
                             "function_call_output", "custom_tool_call",
                             "custom_tool_call_output", "local_shell_call",
                             "local_shell_call_output", "item_reference")

# Content parts that survive the trip to a third-party endpoint.
PORTABLE_CONTENT_PART_TYPES = ("input_text", "output_text", "text")

# `include` values scoped to an OpenAI account. The encrypted reasoning blob
# only makes sense for the backend that produced it: a third-party gateway
# rejects it on the way back (see `sanitize_input_items`), so it is neither
# requested nor forwarded.
OPENAI_ONLY_INCLUDE_VALUES = {"reasoning.encrypted_content"}


def _tool_name(tool):
    """Extract the provider-visible name from flat or nested tool shapes."""
    if not isinstance(tool, dict):
        return ""
    tool_type = tool.get("type")
    if tool_type == "function":
        function = tool.get("function")
        if isinstance(function, dict):
            return str(function.get("name") or "").strip()
    if tool_type in ("apply_patch", "local_shell") and not tool.get("name"):
        # These tools are identified by their type and carry no name; the type
        # is also the name Codex uses in the matching call item.
        return tool_type
    return str(tool.get("name") or "").strip()


def _safe_tool_name(name, taken):
    """Provider-safe tool name. MCP tools can carry dots or slashes, which
    Anthropic and several OpenAI-compatible endpoints reject."""
    if SAFE_TOOL_NAME.match(name) and name not in taken:
        return name
    cleaned = re.sub(r"[^A-Za-z0-9_-]", "_", name)[:64].strip("_") or "tool"
    candidate = cleaned
    suffix = 2
    while candidate in taken:
        candidate = "%s_%d" % (cleaned[:61], suffix)
        suffix += 1
    return candidate


def _freeform_schema(tool):
    fmt = tool.get("format") if isinstance(tool.get("format"), dict) else {}
    syntax = fmt.get("syntax") or fmt.get("type") or "text"
    return {
        "type": "object",
        "properties": {FREEFORM_INPUT_KEY: {
            "type": "string",
            "description": "Raw %s payload, passed to the tool verbatim." % syntax,
        }},
        "required": [FREEFORM_INPUT_KEY],
    }


def _namespace_tool_name(namespace, name):
    """Provider-visible name for a tool nested in a Codex namespace."""
    return "%s%s%s" % (namespace, NAMESPACE_SEPARATOR, name)


def _namespace_of(tool):
    """Namespace a Codex namespace tool declares.

    Current Codex sends `{"type": "namespace", "name": ..., "tools": [...]}`.
    The `namespace` key is accepted too: it is the field name this tool family
    uses elsewhere (dynamic tool specs), so a future revision may switch to it.
    """
    return str(tool.get("name") or tool.get("namespace") or "").strip()


def _bridge_namespace(tool, state):
    """Flatten one namespace into provider-visible function tools.

    Every nested tool is republished as `<namespace>__<tool>`. The bridge entry
    keeps the namespace and the original name, so a provider call can be
    restored to `{"type": "function_call", "namespace": ..., "name": ...}`
    without ever parsing the flat name back apart.
    """
    namespace = _namespace_of(tool)
    nested = tool.get("tools")
    if not namespace or not isinstance(nested, list):
        # Fail soft: an unknown future shape must never take the whole request
        # down, and the other tools must keep working.
        sys.stderr.write("[proxy %s] namespace non reconnu: %s\n"
                         % (DISPLAY, json.dumps(tool, default=str)[:200]))
        return
    for sub in nested:
        if not isinstance(sub, dict):
            continue
        sub_type = sub.get("type")
        name = str(sub.get("name") or "").strip()
        if not name:
            continue
        if sub_type not in (None, "function"):
            # A namespaced freeform/hosted tool has no portable wire form: the
            # Responses `custom_tool_call` item carries no namespace to restore.
            sys.stderr.write("[proxy %s] namespace %s: %s ignore (type %s)\n"
                             % (DISPLAY, namespace, name, sub_type))
            continue
        logical = "%s/%s" % (namespace, name)
        if logical.casefold() in state.seen_originals:
            continue
        state.seen_originals.add(logical.casefold())
        provider_name = _safe_tool_name(_namespace_tool_name(namespace, name), state.taken)
        state.taken.add(provider_name)
        state.bridge[provider_name] = {"kind": "namespace",
                                       "namespace": namespace,
                                       "name": name}
        state.upstream.append({
            "type": "function",
            "name": provider_name,
            "description": sub.get("description") or "",
            # Function sub-tools use `parameters`; the dynamic-tool spelling
            # `inputSchema` is accepted so both shapes bridge.
            "parameters": sub.get("parameters") or sub.get("inputSchema")
            or {"type": "object", "properties": {}},
        })
        sys.stderr.write("[proxy %s] namespace %s.%s -> %s\n"
                         % (DISPLAY, namespace, name, provider_name))


class _ToolBridgeState:
    """Provider-visible name bookkeeping for one request.

    Tool lists arrive from more than one place (the top-level `tools` array and
    `additional_tools` input items), so the mapping is built once per request
    and shared. Sharing it is what keeps `collaboration__spawn_agent` and a
    plain `spawn_agent` from colliding.
    """

    __slots__ = ("upstream", "bridge", "taken", "seen_originals")

    def __init__(self):
        self.upstream = []
        self.bridge = {}
        self.taken = set()
        self.seen_originals = set()

    def add(self, specs):
        for tool in (specs or []):
            if not isinstance(tool, dict):
                continue
            if tool.get("type") == NAMESPACE_TOOL_TYPE:
                _bridge_namespace(tool, self)
                continue
            self._add_tool(tool)

    def _add_tool(self, tool):
        tool_type = tool.get("type")
        original = _tool_name(tool)
        if tool_type == "function":
            function = tool.get("function") if isinstance(tool.get("function"), dict) else tool
            kind = "function"
            description = function.get("description", "")
            schema = function.get("parameters") or {"type": "object", "properties": {}}
        elif tool_type in FREEFORM_TOOL_TYPES:
            if not SUPPORTS_APPLY_PATCH and (tool_type == "apply_patch"
                                             or original == "apply_patch"):
                return
            if SUPPORTS_CUSTOM_TOOLS:
                # Native contract: forward the tool untouched, no restore needed.
                if original and original.casefold() not in self.seen_originals:
                    self.seen_originals.add(original.casefold())
                    self.upstream.append(tool)
                return
            kind = "custom"
            description = tool.get("description") or (
                "Freeform tool. Send the payload in the `%s` string." % FREEFORM_INPUT_KEY)
            schema = _freeform_schema(tool)
        elif tool_type == "local_shell":
            if SUPPORTS_CUSTOM_TOOLS:
                self.upstream.append(tool)
                return
            kind = "local_shell"
            description = tool.get("description") or "Run a command in the user's shell."
            schema = LOCAL_SHELL_SCHEMA
        elif tool_type in HOSTED_TOOL_TYPES:
            # Executed by the provider, never by Codex. The Anthropic adapter
            # maps web search to its own server tool; relay providers drop it.
            return
        else:
            return
        normalized = original.casefold()
        if not original or normalized in self.seen_originals:
            return
        self.seen_originals.add(normalized)
        name = _safe_tool_name(original, self.taken)
        self.taken.add(name)
        self.bridge[name] = {"kind": kind, "name": original}
        self.upstream.append({"type": "function", "name": name,
                              "description": description, "parameters": schema})


def bridge_tools(tools, state=None):
    """Translate Codex's tool list into tools this provider can actually call.

    Returns `(upstream_tools, bridge)`. `bridge` maps the name seen by the
    provider to `{"kind", "name"}` — plus `{"namespace", ...}` for namespaced
    tools — which `restore_output_items` uses to rebuild the original Responses
    item (`custom_tool_call`, `local_shell_call`, a namespaced `function_call`,
    or a renamed one).

    `state` lets a caller keep building the same mapping from another tool list.
    """
    if not SUPPORTS_TOOLS:
        return [], {}
    state = state or _ToolBridgeState()
    state.add(tools)
    return state.upstream, state.bridge


def bridge_additional_tools(input_items, state):
    """Consume the `additional_tools` items Codex carries in its input.

    Codex advertises the same tools in the top-level `tools` array (the path the
    Desktop app uses with a model catalog) or inside an `additional_tools`
    developer item (the fallback path). Both are bridged into the provider's
    `tools` array, and the envelope itself is dropped: no third-party endpoint
    implements that item type, and a strict one rejects the whole request over
    it. The tools it carried must survive, so they are bridged, never discarded.
    """
    if not isinstance(input_items, list):
        return input_items
    out = []
    for item in input_items:
        if not (isinstance(item, dict) and item.get("type") == "additional_tools"
                and isinstance(item.get("tools"), list)):
            out.append(item)
            continue
        # Namespaces flatten to `<namespace>__<tool>`, the remaining tools bridge
        # exactly as if they had arrived in the top-level array; duplicates
        # already advertised there are not repeated.
        state.add(item["tools"])
    return out


# ---------------------------------------------------------------------------
# Passive Multi-Agent compatibility observations
#
# Whether a routed provider+model can really run a Multi-Agent V2 workflow is
# learned from real traffic only. The proxy appends one structured line per
# meaningful protocol step to a sidecar JSONL the app reads; the app owns the
# persisted status. Nothing here ever calls a model on its own, and a line
# carries technical metadata only — never a prompt, a tool argument, a tool
# result, or a credential.
# ---------------------------------------------------------------------------

EVENTS_FILE_NAME = "multi-agent-events.jsonl"

# Threads can serve concurrent requests; the observation state must not race.
_OBSERVATION_LOCK = threading.Lock()
# call_id -> {namespace, tool} for calls the provider made and we restored.
_RESTORED_CALLS = {}
# Calls whose `function_call_output` already came back: Codex executed them.
_COMPLETED_CALLS = {}
# Thread ids that already produced a real child thread.
_CHILD_THREADS = set()
# Last bridged tool signature, so a long session writes one line, not thousands.
_BRIDGED_SIGNATURE = None


def provider_identifier():
    """Stable provider id, set by the app; `DISPLAY` is the readable fallback."""
    return (os.environ.get("AI_PROVIDER_SWITCHER_PROVIDER_ID") or DISPLAY).strip()


def state_directory():
    """Directory the app owns (its side-car home), shared with the Swift side."""
    override = os.environ.get("AI_PROVIDER_SWITCHER_STATE_DIR")
    if override:
        return override
    return os.path.join(os.path.expanduser("~"),
                        "Library", "Application Support",
                        "AI Provider Switcher")


def events_path():
    return os.path.join(state_directory(), EVENTS_FILE_NAME)


def record_multi_agent_event(event, **fields):
    """Append one observation. Failures are swallowed: observations must never
    break a conversation."""
    payload = {"event": event,
               "provider": provider_identifier(),
               "bridge_version": BRIDGE_CAPABILITY_VERSION,
               "observed_at": time.time()}
    payload.update(fields)
    try:
        line = (json.dumps(payload, ensure_ascii=False) + "\n").encode("utf-8")
        directory = state_directory()
        if directory:
            os.makedirs(directory, exist_ok=True)
        descriptor = os.open(events_path(),
                             os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        try:
            os.write(descriptor, line)
        finally:
            os.close(descriptor)
    except Exception:
        pass


def _turn_metadata(headers):
    """Codex's own per-turn metadata, decoded when present."""
    raw = ""
    if headers is not None:
        for key, value in headers.items():
            if key.lower() == "x-codex-turn-metadata":
                raw = value or ""
                break
    if not raw:
        return {}
    try:
        parsed = json.loads(raw)
    except Exception:
        return {}
    return parsed if isinstance(parsed, dict) else {}


def request_thread_context(headers, body=None):
    """Identify the thread a request belongs to, and whether it is a sub-agent.

    A real child thread is the strongest proof a `spawn_agent` call was executed
    rather than merely answered: Codex starts it itself and stamps the parent
    thread id on its requests.
    """
    metadata = _turn_metadata(headers)
    client = (body or {}).get("client_metadata")
    client = client if isinstance(client, dict) else {}
    thread_id = (metadata.get("thread_id") or client.get("thread_id")
                 or client.get("session_id") or "")
    parent_thread_id = (metadata.get("parent_thread_id")
                        or client.get("x-codex-parent-thread-id")
                        or (_header(headers, "x-codex-parent-thread-id")) or "")
    source = metadata.get("thread_source") or ""
    subagent = bool(parent_thread_id) or source == "subagent" \
        or bool(metadata.get("subagent_kind"))
    return {"thread_id": str(thread_id), "parent_thread_id": str(parent_thread_id),
            "is_subagent": subagent}


def _header(headers, name):
    if headers is None:
        return ""
    for key, value in headers.items():
        if key.lower() == name:
            return value or ""
    return ""


def observe_bridged_tools(bridge, model, slug):
    """Record that Codex's namespaced tools really reached this provider."""
    global _BRIDGED_SIGNATURE
    namespaced = sorted(
        "%s.%s" % (entry.get("namespace", ""), entry.get("name", ""))
        for entry in (bridge or {}).values()
        if isinstance(entry, dict) and entry.get("kind") == "namespace")
    if not namespaced:
        return
    signature = (model, tuple(namespaced))
    with _OBSERVATION_LOCK:
        if signature == _BRIDGED_SIGNATURE:
            return
        _BRIDGED_SIGNATURE = signature
    record_multi_agent_event(
        "multi_agent_tools_bridged", model=model, slug=slug,
        namespaces=sorted({name.split(".", 1)[0] for name in namespaced}),
        tools=namespaced)


def observe_restored_call(item, context):
    """Record a namespaced call restored into the shape Codex executes."""
    entry = (context or {}).get("bridge", {}).get(item.get("name") or "")
    if not isinstance(entry, dict) or entry.get("kind") != "namespace":
        return
    call_id = item.get("call_id") or ""
    thread = (context or {}).get("thread") or {}
    with _OBSERVATION_LOCK:
        if call_id:
            _RESTORED_CALLS[call_id] = {"namespace": entry.get("namespace", ""),
                                        "tool": entry.get("name", ""),
                                        "thread_id": thread.get("thread_id", "")}
            if len(_RESTORED_CALLS) > 200:
                _RESTORED_CALLS.pop(next(iter(_RESTORED_CALLS)))
    record_multi_agent_event(
        "multi_agent_tool_restored",
        model=(context or {}).get("model"), slug=(context or {}).get("slug"),
        namespace=entry.get("namespace", ""), tool=entry.get("name", ""),
        call_id=call_id)


def observe_request_history(input_items, context):
    """Record what Codex sent back: tool results, and real child threads."""
    thread = (context or {}).get("thread") or {}
    parent = thread.get("parent_thread_id") or ""
    results = []
    with _OBSERVATION_LOCK:
        for item in (input_items if isinstance(input_items, list) else []):
            if not isinstance(item, dict) or item.get("type") != "function_call_output":
                continue
            call_id = item.get("call_id") or ""
            known = _RESTORED_CALLS.get(call_id)
            if known and call_id not in _COMPLETED_CALLS:
                _COMPLETED_CALLS[call_id] = known
                results.append((call_id, known))
        # A brand-new child thread is the strongest proof available here: Codex
        # created it itself, and stamps the parent thread on every request.
        seen_child = bool(thread.get("is_subagent") and parent
                          and parent not in _CHILD_THREADS)
        if seen_child:
            _CHILD_THREADS.add(parent)
    for call_id, known in results:
        record_multi_agent_event(
            "multi_agent_tool_result",
            model=(context or {}).get("model"), slug=(context or {}).get("slug"),
            namespace=known.get("namespace", ""), tool=known.get("tool", ""),
            call_id=call_id)
    if seen_child:
        # A child thread exists under a parent we restored a call for: the full
        # cycle really happened. Remember which tool started it.
        with _OBSERVATION_LOCK:
            started = [entry for entry in _COMPLETED_CALLS.values()
                       if entry.get("thread_id") == parent]
        record_multi_agent_event(
            "multi_agent_child_thread",
            model=(context or {}).get("model"), slug=(context or {}).get("slug"),
            parent_thread_id=parent,
            tools=sorted({"%s.%s" % (e.get("namespace", ""), e.get("tool", ""))
                          for e in started}))


INCONCLUSIVE_REASONS = {
    400: "invalid_request",
    401: "authentication_required",
    402: "insufficient_balance",
    403: "forbidden",
    404: "endpoint_not_found",
    408: "timeout",
    422: "unsupported_request",
    429: "rate_limited",
}


def classify_upstream_error(status):
    """Map a transport failure to a Multi-Agent verdict.

    A quota, auth, network or provider outage says nothing about whether the
    model is *able* to run a Multi-Agent workflow, so those never count as
    incompatibility.
    """
    try:
        status = int(status)
    except (TypeError, ValueError):
        return "inconclusive", "network"
    if status in INCONCLUSIVE_REASONS:
        return "inconclusive", INCONCLUSIVE_REASONS[status]
    if status >= 500:
        return "inconclusive", "provider_error"
    return "inconclusive", "http_%d" % status


def observe_upstream_error(status, model=None, slug=None, detail=None):
    """Record a refused turn. The provider's own message is kept, truncated,
    so a 400/422 can be classified without exposing a request payload."""
    verdict, reason = classify_upstream_error(status)
    if detail:
        detail = str(detail).strip().replace("\n", " ")[:200]
    record_multi_agent_event("multi_agent_upstream_error", verdict=verdict,
                             reason=reason, http_status=status,
                             model=model, slug=slug, detail=detail or None)


def upstream_error_detail(body):
    """The provider's own error message, when the body carries one.

    Providers that answer with an opaque `Upstream request failed` are left
    as they are: the proxy never invents a reason it cannot prove.
    """
    try:
        payload = json.loads(body.decode("utf-8") if isinstance(body, bytes) else body)
    except Exception:
        return ""
    error = payload.get("error") if isinstance(payload, dict) else None
    if isinstance(error, dict):
        return str(error.get("message") or "")
    if isinstance(error, str):
        return error
    return ""


def bridge_needs_restore(bridge):
    """True when a response must be rewritten before Codex can read it."""
    return any(entry["kind"] != "function" or entry["name"] != name
               for name, entry in (bridge or {}).items())


def bridge_input_items(raw, bridge):
    """Rewrite Codex tool-call history into the shapes the provider understands.

    Without this, a conversation dies right after the first bridged tool call:
    the upstream receives a `custom_tool_call` item it has never emitted, or a
    namespaced `function_call` under a name it was never offered.
    """
    if not isinstance(raw, list):
        return raw
    upstream_names, namespaced = _reverse_bridge_names(bridge)
    out = []
    for item in raw:
        if not isinstance(item, dict):
            out.append(item)
            continue
        item_type = item.get("type")
        if item_type == "custom_tool_call":
            out.append({
                "type": "function_call",
                "call_id": item.get("call_id", ""),
                "name": upstream_names.get(item.get("name", ""), item.get("name", "")),
                "arguments": json.dumps({FREEFORM_INPUT_KEY: item.get("input", "")}),
            })
        elif item_type == "local_shell_call":
            action = item.get("action") if isinstance(item.get("action"), dict) else {}
            arguments = {k: v for k, v in action.items() if k != "type"}
            out.append({
                "type": "function_call",
                "call_id": item.get("call_id", ""),
                "name": upstream_names.get("local_shell", "local_shell"),
                "arguments": json.dumps(arguments),
            })
        elif item_type in ("custom_tool_call_output", "local_shell_call_output"):
            out.append({
                "type": "function_call_output",
                "call_id": item.get("call_id", ""),
                "output": item.get("output", ""),
            })
        elif item_type == "function_call":
            namespace = item.get("namespace")
            if namespace:
                # Codex replays the call with its namespace and short name; the
                # provider only ever saw the flat name. Drop the wrapper key it
                # has no schema for.
                flattened = namespaced.get((namespace, item.get("name", "")))
                replayed = {k: v for k, v in item.items() if k != "namespace"}
                if flattened:
                    replayed["name"] = flattened
                # When the bridge no longer maps the namespace (a restarted
                # proxy, a rebuilt bridge), the call is still forwarded under
                # its original name: no provider tool is ever declared with a
                # `namespace` key, and a strict gateway rejects the whole
                # request over one field it does not know.
                out.append(replayed)
                continue
            renamed = upstream_names.get(item.get("name", ""))
            out.append(dict(item, name=renamed) if renamed and renamed != item.get("name") else item)
        elif item_type == "message" and item.get("role") == "developer":
            # Several third-party Responses implementations expose a Chat-like
            # role enum and reject `developer`; `system` carries the same intent.
            out.append(dict(item, role="system"))
        else:
            out.append(item)
    return out


def _reverse_bridge_names(bridge):
    """Split the bridge into its two lookup tables.

    Namespaced entries are keyed by `(namespace, tool)` because the flat name is
    only a provider convenience: `collaboration.spawn_agent` and a hypothetical
    top-level `collaboration__spawn_agent` must never be confused.
    """
    by_name = {}
    namespaced = {}
    for provider_name, entry in (bridge or {}).items():
        if not isinstance(entry, dict):
            continue
        if entry.get("kind") == "namespace":
            namespaced[(entry.get("namespace", ""), entry.get("name", ""))] = provider_name
        else:
            by_name[entry.get("name", "")] = provider_name
    return by_name, namespaced


def _restore_context(req, slug, headers):
    """What the observation layer needs to attribute a restored call."""
    return {"model": (req or {}).get("model"), "slug": slug,
            "thread": request_thread_context(headers, req)}


def restore_output_items(output, bridge, context=None):
    """Rebuild the Responses items Codex expects from the provider's function
    calls: freeform custom tools, local_shell, namespaced tools, and renamed
    function tools."""
    if not output or not bridge:
        return output
    restored = []
    for item in output:
        entry = bridge.get(item.get("name") or "") if isinstance(item, dict) else None
        if not entry or item.get("type") != "function_call":
            restored.append(item)
            continue
        kind, original = entry["kind"], entry["name"]
        if kind == "function":
            restored.append(dict(item, name=original) if original != item.get("name") else item)
            continue
        if kind == "namespace":
            # Codex executes the call through its tool router, which reads the
            # namespace back from this item. Keep `id`, `status`, `call_id` and
            # the provider's arguments byte for byte.
            namespace = entry.get("namespace", "")
            sys.stderr.write("[proxy %s] restore %s -> %s.%s\n"
                             % (DISPLAY, item.get("name"), namespace, original))
            observe_restored_call(item, dict(context or {}, bridge=bridge))
            restored.append(dict(item, namespace=namespace, name=original))
            continue
        try:
            arguments = json.loads(item.get("arguments") or "{}")
        except Exception:
            arguments = {}
        if not isinstance(arguments, dict):
            arguments = {}
        if kind == "custom":
            payload = arguments.get(FREEFORM_INPUT_KEY)
            if not isinstance(payload, str):
                # The model ignored the wrapper: pass its raw arguments through
                # rather than losing the call.
                payload = item.get("arguments") or ""
            restored.append({
                "type": "custom_tool_call",
                "id": item.get("id") or f"ctc_{uuid.uuid4().hex[:24]}",
                "call_id": item.get("call_id", ""),
                "name": original,
                "input": payload,
                "status": item.get("status", "completed"),
            })
        elif kind == "local_shell":
            command = arguments.get("command") or []
            if isinstance(command, str):
                command = ["bash", "-lc", command]
            action = {"type": "exec", "command": command}
            for key in ("workdir", "timeout_ms"):
                if arguments.get(key):
                    action[key] = arguments[key]
            restored.append({
                "type": "local_shell_call",
                "id": item.get("id") or f"lsh_{uuid.uuid4().hex[:24]}",
                "call_id": item.get("call_id", ""),
                "status": item.get("status", "completed"),
                "action": action,
            })
    return restored


def sanitize_upstream_request(req):
    """Strip OpenAI-account-scoped fields and clamp reasoning to portable
    values, so a third-party endpoint does not reject the whole request."""
    for field in OPENAI_ONLY_REQUEST_FIELDS:
        req.pop(field, None)
    include = req.get("include")
    if isinstance(include, list) and OPENAI_ONLY_INCLUDE_VALUES & set(include):
        # Codex asks for the encrypted reasoning blob so a `store = false`
        # session can replay it. A third-party endpoint cannot use that blob:
        # the adapter strips it from the next request because strict gateways
        # reject it (`400` on OpenCode Go). Asking for it would only produce a
        # payload that is discarded, so the request stops asking.
        req["include"] = [value for value in include
                          if value not in OPENAI_ONLY_INCLUDE_VALUES]
    reasoning = req.get("reasoning")
    if isinstance(reasoning, dict):
        effort = reasoning.get("effort")
        if isinstance(effort, str) and effort not in PORTABLE_REASONING_EFFORTS:
            reasoning["effort"] = "low" if effort == "minimal" else "high"
    if IS_OPENROUTER:
        try:
            requested = int(req.get("max_output_tokens") or 0)
        except (TypeError, ValueError):
            requested = 0
        req["max_output_tokens"] = min(
            requested or OPENROUTER_MAX_OUTPUT_TOKENS,
            OPENROUTER_MAX_OUTPUT_TOKENS)
    return req


def prepare_upstream_request(req, extra_tools=0, headers=None):
    """Bridge tools + history and sanitize a Responses request in one pass.

    `extra_tools` counts tools the adapter adds itself (Anthropic's server-side
    web search), so the "no tools available" note is not injected when the model
    can still act. Returns `(req, bridge, bridged_tools_count, slug)`, where
    `slug` is the model name Codex used and expects to read back.
    """
    slug = req.get("model")
    req["model"] = upstream_model(slug)
    state = _ToolBridgeState()
    tools, bridge = bridge_tools(req.get("tools"), state)
    req["tools"] = tools
    # Codex may advertise the same namespaces inside `additional_tools` items.
    # Both paths share one mapping, so a tool name never resolves to two things.
    req["input"] = bridge_additional_tools(req.get("input"), state)
    req["input"] = bridge_input_items(req.get("input"), bridge)
    # Codex-only items (`agent_message`, encrypted reasoning) are translated
    # last, once the tool history is already in the provider's shape.
    req["input"] = sanitize_input_items(req.get("input"))
    req = apply_no_tools_note(req, len(tools) + extra_tools)
    observe_bridged_tools(bridge, req["model"], slug)
    observe_request_history(req.get("input"), {
        "model": req["model"], "slug": slug,
        "thread": request_thread_context(headers, req),
    })
    rewritten = []
    for name, entry in bridge.items():
        if entry["kind"] == "namespace":
            rewritten.append("%s.%s->%s" % (entry.get("namespace", ""),
                                            entry["name"], name))
        elif entry["kind"] != "function" or entry["name"] != name:
            rewritten.append("%s->%s:%s" % (entry["name"], name, entry["kind"]))
    if rewritten:
        sys.stderr.write("[proxy %s] bridge: %s\n" % (DISPLAY, ", ".join(rewritten)))
    if slug != req["model"]:
        sys.stderr.write("[proxy %s] modele: %s -> %s\n" % (DISPLAY, slug, req["model"]))
    return sanitize_upstream_request(req), bridge, len(tools), slug


def apply_no_tools_note(req, tools_count):
    if tools_count > 0:
        return req
    raw = req.get("input")
    note_item = {
        "type": "message",
        # This note is generated by the proxy, so use the portable role that
        # both Responses and Chat-compatible upstreams accept.
        "role": "system",
        "content": [{"type": "input_text", "text": NO_TOOLS_NOTE}],
    }
    if isinstance(raw, list):
        req["input"] = raw + [note_item]
    elif isinstance(raw, str):
        req["input"] = [{"type": "message", "role": "user", "content": raw}, note_item]
    else:
        req["input"] = [note_item]
    return req


def _portable_content_parts(content):
    """Content parts a third-party endpoint understands, in order.

    `input_text` / `output_text` are portable as they are. Codex carries an
    inter-agent message payload in an `encrypted_content` part (the field name
    is Codex's own; the value is the text the other agent must read), so its
    text is re-emitted as `input_text` instead of being lost — dropping it
    would hand the child thread an empty task.
    """
    parts = []
    for part in (content if isinstance(content, list) else []):
        if not isinstance(part, dict):
            continue
        kind = part.get("type")
        if kind in PORTABLE_CONTENT_PART_TYPES:
            text = part.get("text")
        elif kind == "encrypted_content":
            text = part.get("encrypted_content")
        else:
            continue
        if isinstance(text, str) and text:
            parts.append({"type": "input_text", "text": text})
    return parts


def sanitize_input_items(input_items):
    """Translate away the input items only Codex sends.

    A provider that does not implement Codex's multi-agent protocol rejects the
    entire request over one unknown item, so each Codex-only shape is either
    translated into an equivalent portable one or dropped:

    * `agent_message` -> `{"type": "message", "role": "user"}` (OpenCode Go
      answers `422` otherwise). It is an input the model must read, hence the
      `user` role, and its text is kept verbatim.
    * `reasoning` -> the account-scoped `encrypted_content` blob and a null
      `content` slot are removed, keeping the portable `summary`
      (OpenCode Go answers `400` otherwise).
    * anything else unknown is dropped, because relaying one would fail the
      whole request instead of the single item.
    """
    if not isinstance(input_items, list):
        return input_items
    out = []
    for item in input_items:
        if not isinstance(item, dict):
            out.append(item)
            continue
        kind = item.get("type")
        if kind == CODEX_AGENT_MESSAGE_TYPE:
            content = _portable_content_parts(item.get("content"))
            if not content:
                sys.stderr.write("[proxy %s] agent_message vide ignore\n" % DISPLAY)
                continue
            sys.stderr.write("[proxy %s] agent_message -> message user\n" % DISPLAY)
            out.append({"type": "message", "role": "user", "content": content})
            continue
        if kind == "reasoning":
            cleaned = {key: value for key, value in item.items()
                       if key != "encrypted_content"}
            content = cleaned.get("content")
            if not isinstance(content, list) or not content:
                # `content: null` is rejected too; the summary is the portable
                # half of a reasoning item.
                cleaned.pop("content", None)
            if "encrypted_content" in item:
                sys.stderr.write("[proxy %s] reasoning: encrypted_content retire\n"
                                 % DISPLAY)
            out.append(cleaned)
            continue
        if kind in PORTABLE_INPUT_ITEM_TYPES:
            out.append(item)
            continue
        sys.stderr.write("[proxy %s] item d'entree Codex-only ignore: %s\n"
                         % (DISPLAY, kind))
    return out


TOOL_CALL_ITEM_TYPES = ("function_call", "custom_tool_call", "local_shell_call")


def has_function_calls(response):
    return any(i.get("type") in TOOL_CALL_ITEM_TYPES
               for i in (response or {}).get("output", []))


def append_synthetic_tool_results(req, response):
    """Answer every pending tool call with 'tool unavailable' so the model can
    finish with a plain-text answer."""
    history = req.get("input")
    if not isinstance(history, list):
        history = [{"type": "message", "role": "user", "content": history}]
    new_input = history + (response.get("output") or [])
    for item in (response.get("output") or []):
        if item.get("type") in TOOL_CALL_ITEM_TYPES:
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
        if itype == "reasoning":
            for si, part in enumerate(item.get("summary") or []):
                events.append({"type": "response.reasoning_summary_part.added", "item_id": item.get("id"),
                               "output_index": idx, "summary_index": si, "part": part})
                events.append({"type": "response.reasoning_summary_text.delta", "item_id": item.get("id"),
                               "output_index": idx, "summary_index": si, "delta": part.get("text", "")})
                events.append({"type": "response.reasoning_summary_text.done", "item_id": item.get("id"),
                               "output_index": idx, "summary_index": si, "text": part.get("text", "")})
                events.append({"type": "response.reasoning_summary_part.done", "item_id": item.get("id"),
                               "output_index": idx, "summary_index": si, "part": part})
        if itype == "message":
            for ci, part in enumerate(item.get("content") or []):
                events.append({"type": "response.content_part.added", "item_id": item.get("id"),
                               "output_index": idx, "content_index": ci, "part": part})
                events.append({"type": "response.output_text.delta", "item_id": item.get("id"),
                               "output_index": idx, "content_index": ci, "delta": part.get("text", "")})
                events.append({"type": "response.output_text.done", "item_id": item.get("id"),
                               "output_index": idx, "content_index": ci, "text": part.get("text", "")})
                events.append({"type": "response.content_part.done", "item_id": item.get("id"),
                               "output_index": idx, "content_index": ci, "part": part})
        elif itype == "function_call":
            arguments = item.get("arguments") or ""
            events.append({"type": "response.function_call_arguments.delta",
                           "item_id": item.get("id"), "output_index": idx, "delta": arguments})
            events.append({"type": "response.function_call_arguments.done",
                           "item_id": item.get("id"), "output_index": idx, "arguments": arguments})
        elif itype == "custom_tool_call":
            payload = item.get("input") or ""
            events.append({"type": "response.custom_tool_call_input.delta",
                           "item_id": item.get("id"), "output_index": idx, "delta": payload})
            events.append({"type": "response.custom_tool_call_input.done",
                           "item_id": item.get("id"), "output_index": idx, "input": payload})
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


def _responses_parts_to_chat(content):
    """Responses message content -> OpenAI Chat content."""
    if isinstance(content, str):
        return content
    parts = []
    for part in content or []:
        if not isinstance(part, dict):
            continue
        if part.get("type") in ("input_text", "output_text", "text"):
            text = part.get("text", "")
            if parts and isinstance(parts[-1], str):
                parts[-1] += text
            else:
                parts.append(text)
        elif part.get("type") == "input_image" and SUPPORTS_IMAGES:
            url = part.get("image_url")
            if isinstance(url, dict):
                url = url.get("url")
            if isinstance(url, str) and url:
                parts.append({"type": "image_url", "image_url": {"url": url}})
    if not parts:
        return ""
    if len(parts) == 1 and isinstance(parts[0], str):
        return parts[0]
    return [{"type": "text", "text": item} if isinstance(item, str) else item
             for item in parts]


def _normalize_chat_content(content):
    """Remove Responses-only image parts from an already Chat-shaped body."""
    if not isinstance(content, list):
        return content
    normalized = []
    for part in content:
        if not isinstance(part, dict) or part.get("type") != "input_image":
            normalized.append(part)
            continue
        url = part.get("image_url")
        if isinstance(url, dict):
            url = url.get("url")
        if isinstance(url, str) and url:
            normalized.append({"type": "image_url", "image_url": {"url": url}})
    return normalized


def normalize_chat_request(body):
    """Ensure direct Chat requests use the provider's portable image shape."""
    if not isinstance(body, dict) or not isinstance(body.get("messages"), list):
        return body
    messages = []
    for message in body["messages"]:
        if isinstance(message, dict):
            messages.append(dict(message, content=_normalize_chat_content(message.get("content"))))
        else:
            messages.append(message)
    return dict(body, messages=messages)


def responses_to_chat(body):
    """Translate a prepared Responses request to Chat Completions.

    The tool bridge has already normalized Codex's native tool flavors into
    flat Responses function tools. This pass converts those tools and the
    conversation history to the Chat wire shape.
    """
    system = []
    if isinstance(body.get("instructions"), str) and body["instructions"].strip():
        system.append(body["instructions"].strip())
    messages = []

    def append_message(role, content, tool_calls=None):
        # Chat-compatible gateways (including OpenCode Go) do not accept the
        # Responses API's `developer` role. Preserve its instruction semantics
        # by folding it into the system prompt.
        if role in ("system", "developer"):
            if isinstance(content, str) and content.strip():
                system.append(content.strip())
            return
        if role == "assistant" and messages and messages[-1]["role"] == "assistant":
            target = messages[-1]
            if isinstance(content, str) and content:
                target["content"] = ((target.get("content") or "") + content).strip()
            target.setdefault("tool_calls", []).extend(tool_calls or [])
            return
        item = {"role": role, "content": content}
        if tool_calls:
            item["tool_calls"] = tool_calls
        messages.append(item)

    raw = body.get("input")
    if isinstance(raw, str):
        append_message("user", raw)
    elif isinstance(raw, list):
        pending_tool_calls = []
        for item in raw:
            if not isinstance(item, dict):
                continue
            item_type = item.get("type")
            if item_type == "message":
                if pending_tool_calls:
                    append_message("assistant", "", pending_tool_calls)
                    pending_tool_calls = []
                role = item.get("role") or "user"
                content = _responses_parts_to_chat(item.get("content"))
                append_message("assistant" if role == "assistant" else role, content)
            elif item_type == "function_call":
                pending_tool_calls.append({
                    "id": item.get("call_id") or item.get("id") or f"call_{uuid.uuid4().hex[:24]}",
                    "type": "function",
                    "function": {
                        "name": item.get("name", ""),
                        "arguments": item.get("arguments") or "{}",
                    },
                })
            elif item_type == "function_call_output":
                if pending_tool_calls:
                    append_message("assistant", "", pending_tool_calls)
                    pending_tool_calls = []
                messages.append({
                    "role": "tool",
                    "tool_call_id": item.get("call_id", ""),
                    "content": item.get("output") or "",
                })
        if pending_tool_calls:
            append_message("assistant", "", pending_tool_calls)

    if system:
        messages.insert(0, {"role": "system", "content": "\n\n".join(system)})
    if not messages:
        messages.append({"role": "user", "content": ""})

    chat = {
        "model": body.get("model") or MODELS[0],
        "messages": messages,
        "stream": False,
    }
    tools = []
    for tool in body.get("tools") or []:
        if not isinstance(tool, dict) or tool.get("type") != "function":
            continue
        tools.append({
            "type": "function",
            "function": {
                "name": tool.get("name", ""),
                "description": tool.get("description", ""),
                "parameters": tool.get("parameters") or {"type": "object", "properties": {}},
            },
        })
    if tools:
        chat["tools"] = tools
        if body.get("tool_choice") is not None:
            chat["tool_choice"] = body["tool_choice"]
        if body.get("parallel_tool_calls") is not None:
            chat["parallel_tool_calls"] = body["parallel_tool_calls"]

    if body.get("max_output_tokens") is not None:
        chat["max_tokens"] = body["max_output_tokens"]
    for field in ("temperature", "top_p"):
        if body.get(field) is not None:
            chat[field] = body[field]
    reasoning = body.get("reasoning")
    if isinstance(reasoning, dict) and reasoning.get("effort"):
        chat["reasoning_effort"] = reasoning["effort"]
    return normalize_chat_request(chat)


def chat_to_responses(body, slug):
    """Translate a non-streaming Chat completion to a Responses object."""
    choice = ((body.get("choices") or [{}])[0] or {})
    message = choice.get("message") or {}
    output = []
    content = message.get("content")
    if isinstance(content, str) and content:
        output.append({
            "id": "msg_" + uuid.uuid4().hex[:24],
            "type": "message",
            "role": "assistant",
            "status": "completed",
            "content": [{"type": "output_text", "text": content, "annotations": []}],
        })
    elif isinstance(content, list):
        text = "".join(part.get("text", "") for part in content
                       if isinstance(part, dict) and part.get("type") == "text")
        if text:
            output.append({
                "id": "msg_" + uuid.uuid4().hex[:24],
                "type": "message",
                "role": "assistant",
                "status": "completed",
                "content": [{"type": "output_text", "text": text, "annotations": []}],
            })
    for call in message.get("tool_calls") or []:
        function = call.get("function") or {}
        output.append({
            "id": call.get("id") or "fc_" + uuid.uuid4().hex[:24],
            "type": "function_call",
            "status": "completed",
            "call_id": call.get("id") or "",
            "name": function.get("name", ""),
            "arguments": function.get("arguments") or "{}",
        })
    usage = body.get("usage") or {}
    return {
        "id": body.get("id") or "resp_" + uuid.uuid4().hex[:24],
        "object": "response",
        "created_at": body.get("created") or int(time.time()),
        "model": slug,
        "status": "completed",
        "output": output,
        "parallel_tool_calls": body.get("parallel_tool_calls", False),
        "usage": {
            "input_tokens": usage.get("prompt_tokens", 0),
            "output_tokens": usage.get("completion_tokens", 0),
            "total_tokens": usage.get("total_tokens", 0),
        },
    }


def responses_to_anthropic(body):
    """Translate a Responses API request body to an Anthropic Messages body."""
    model = body.get("model") or MODELS[0]
    # Anthropic requires max_tokens. 4096 truncates patches and long file
    # rewrites, so default to a budget every current Claude model accepts.
    max_tokens = body.get("max_output_tokens") or 16384
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
                        elif pt == "input_image":
                            # Real image input: screenshots and view_image
                            # results reach Claude instead of a "[image]" stub.
                            image = _anthropic_image_block(part) if SUPPORTS_IMAGES else None
                            blocks.append(image or {"type": "text", "text": "[image]"})
                        elif pt == "function_call_output":
                            blocks.append({
                                "type": "tool_result",
                                "tool_use_id": part.get("call_id", ""),
                                "content": part.get("output", ""),
                            })
                if blocks:
                    messages.append({"role": role, "content": blocks})
            elif t == "function_call_output":
                # Responses API places tool results as top-level input items.
                # Anthropic expects them in a user message after the assistant
                # tool_use block.
                messages.append({"role": "user", "content": [{
                    "type": "tool_result",
                    "tool_use_id": item.get("call_id", ""),
                    "content": item.get("output", ""),
                }]})
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
    seen_names = set()
    for t in body.get("tools") or []:
        if t.get("type") != "function":
            # Anthropic's Messages API has no portable representation for
            # Codex native custom tools. They are filtered before this point;
            # keep this guard for callers that invoke the translator directly.
            continue
        # Responses tools are flat (`name`, `description`, `parameters`),
        # while Chat Completions nests them under `function`. Accept both so
        # Codex and other OpenAI-compatible clients use the same adapter.
        fn = t.get("function") or t
        name = str(fn.get("name") or "").strip()
        # Anthropic requires unique, non-empty tool names. Keep the first
        # definition because Codex may repeat the same tool in a stale request
        # or after merging session and provider tool lists. Treat names
        # case-insensitively because upstream validation does the same.
        normalized_name = name.casefold()
        if not name or normalized_name in seen_names:
            continue
        seen_names.add(normalized_name)
        tools.append({
            "name": name,
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
    # Extended thinking: Z.ai (and Anthropic with thinking enabled) answers with
    # `thinking` blocks. Dropping them yields an empty response, so they are
    # surfaced as `reasoning` items — the shape Codex displays.
    for block in content:
        if block.get("type") in ("thinking", "redacted_thinking"):
            text = (block.get("thinking") or "").strip()
            if text:
                output.append({
                    "type": "reasoning",
                    "id": f"rs_{uuid.uuid4().hex[:24]}",
                    "summary": [{"type": "summary_text", "text": text}],
                })
    # Anthropic's own web search runs server-side; report it the way Codex
    # reports OpenAI's hosted search so the UI shows the query.
    for block in content:
        if block.get("type") == "server_tool_use" and block.get("name") == "web_search":
            output.append({
                "type": "web_search_call",
                "id": block.get("id") or f"ws_{uuid.uuid4().hex[:24]}",
                "status": "completed",
                "action": {"type": "search",
                           "query": (block.get("input") or {}).get("query", "")},
            })
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
        self.thinking_item_id = None
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
            if block.get("type") in ("thinking", "redacted_thinking"):
                self.thinking_item_id = f"rs_{uuid.uuid4().hex[:24]}"
                self.response["output"].append({
                    "type": "reasoning", "id": self.thinking_item_id,
                    "summary": [{"type": "summary_text", "text": ""}],
                })
                chunks.append(sse({
                    "type": "response.output_item.added",
                    "output_index": len(self.response["output"]) - 1,
                    "item": dict(self.response["output"][-1]),
                }))
                chunks.append(sse({
                    "type": "response.reasoning_summary_part.added",
                    "item_id": self.thinking_item_id,
                    "output_index": len(self.response["output"]) - 1,
                    "summary_index": 0,
                    "part": {"type": "summary_text", "text": ""},
                }))
            elif block.get("type") == "text":
                self.text_item_id = f"msg_{uuid.uuid4().hex[:24]}"
                self.response["output"].append({
                    "type": "message", "id": self.text_item_id, "status": "in_progress",
                    "role": "assistant", "content": [{"type": "output_text", "text": ""}],
                })
                chunks.append(sse({
                    "type": "response.output_item.added",
                    "output_index": len(self.response["output"]) - 1,
                    "item": dict(self.response["output"][-1]),
                }))
                chunks.append(sse({
                    "type": "response.content_part.added",
                    "item_id": self.text_item_id,
                    "output_index": len(self.response["output"]) - 1,
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
                self.response["output"].append(self.current_tool)
                chunks.append(sse({
                    "type": "response.output_item.added",
                    "output_index": len(self.response["output"]) - 1,
                    "item": dict(self.current_tool),
                }))
        elif etype == "content_block_delta":
            delta = event.get("delta", {})
            if delta.get("type") == "thinking_delta":
                text = delta.get("thinking", "")
                head = self.response["output"][-1] if self.response["output"] else None
                if head is not None and head.get("id") == self.thinking_item_id:
                    summary = head.setdefault("summary", [])
                    if not summary:
                        summary.append({"type": "summary_text", "text": ""})
                    summary[0]["text"] = summary[0].get("text", "") + text
                chunks.append(sse({
                    "type": "response.reasoning_summary_text.delta",
                    "item_id": self.thinking_item_id,
                    "output_index": len(self.response["output"]) - 1,
                    "summary_index": 0,
                    "delta": text,
                }))
            elif delta.get("type") == "text_delta":
                text = delta.get("text", "")
                if self.response["output"] and self.response["output"][-1].get("id") == self.text_item_id:
                    self.response["output"][-1]["content"][0]["text"] += text
                chunks.append(sse({"type": "response.output_text.delta",
                                   "item_id": self.text_item_id,
                                   "output_index": len(self.response["output"]) - 1,
                                   "content_index": 0,
                                   "delta": text}))
            elif delta.get("type") == "input_json_delta" and self.current_tool:
                partial = delta.get("partial_json", "")
                self.current_tool["arguments"] += partial
                chunks.append(sse({
                    "type": "response.function_call_arguments.delta",
                    "item_id": self.current_tool["id"],
                    "output_index": len(self.response["output"]) - 1,
                    "delta": partial,
                }))
        elif etype == "content_block_stop":
            if self.thinking_item_id is not None:
                item = self.response["output"][-1]
                text = "".join(p.get("text", "") for p in (item.get("summary") or []))
                chunks.append(sse({
                    "type": "response.reasoning_summary_text.done",
                    "item_id": self.thinking_item_id,
                    "output_index": len(self.response["output"]) - 1,
                    "summary_index": 0,
                    "text": text,
                }))
                chunks.append(sse({
                    "type": "response.reasoning_summary_part.done",
                    "item_id": self.thinking_item_id,
                    "output_index": len(self.response["output"]) - 1,
                    "summary_index": 0,
                    "part": {"type": "summary_text", "text": text},
                }))
                chunks.append(sse({
                    "type": "response.output_item.done",
                    "output_index": len(self.response["output"]) - 1,
                    "item": dict(item),
                }))
                self.thinking_item_id = None
            elif self.current_tool is not None:
                self.current_tool["status"] = "completed"
                chunks.append(sse({
                    "type": "response.function_call_arguments.done",
                    "item_id": self.current_tool["id"],
                    "output_index": len(self.response["output"]) - 1,
                    "arguments": self.current_tool["arguments"],
                }))
                chunks.append(sse({
                    "type": "response.output_item.done",
                    "output_index": len(self.response["output"]) - 1,
                    "item": dict(self.current_tool),
                }))
                self.current_tool = None
            elif self.text_item_id is not None:
                chunks.append(sse({
                    "type": "response.content_part.done",
                    "item_id": self.text_item_id,
                    "output_index": len(self.response["output"]) - 1,
                    "content_index": 0,
                    "part": dict(self.response["output"][-1]["content"][0]),
                }))
                chunks.append(sse({
                    "type": "response.output_item.done",
                    "output_index": len(self.response["output"]) - 1,
                    "item": dict(self.response["output"][-1]),
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


def _post_anthropic(anth, hdrs, server_tools):
    """POST to Anthropic. Retries once without the server-side tools when the
    account or model rejects them: hosted web search is a bonus, never a reason
    to fail the whole turn. Returns `(response, (code, body))`."""
    def send(payload):
        request = urllib.request.Request(
            anthropic_messages_url(), data=json.dumps(payload).encode(),
            headers=hdrs, method="POST")
        return urllib.request.urlopen(request, context=ssl_context(), timeout=180)

    try:
        return send(anth), None
    except urllib.error.HTTPError as error:
        body = error.read()
        if error.code != 400 or not server_tools:
            return None, (error.code, body)
        sys.stderr.write("[proxy %s] web_search refusé (400) : nouvel essai sans outil serveur\n"
                         % DISPLAY)
        retry = dict(anth)
        remaining = [tool for tool in (retry.get("tools") or []) if tool not in server_tools]
        if remaining:
            retry["tools"] = remaining
        else:
            retry.pop("tools", None)
        try:
            return send(retry), None
        except urllib.error.HTTPError as retry_error:
            return None, (retry_error.code, retry_error.read() or body)


def do_anthropic_request(body_bytes, headers, stream):
    """POST /v1/responses translated to the Anthropic-compatible /v1/messages."""
    req = json.loads(body_bytes.decode("utf-8"))
    # Codex's hosted web_search has a real equivalent here; every other tool
    # flavor (freeform apply_patch, local_shell, MCP function tools) is bridged
    # to an Anthropic tool and restored on the way back.
    server_tools = anthropic_server_tools(req.get("tools"))
    req, bridge, bridged_count, slug = prepare_upstream_request(
        req, extra_tools=len(server_tools), headers=headers)
    tools_count = bridged_count + len(server_tools)
    restore_needed = bridge_needs_restore(bridge)
    anth = responses_to_anthropic(req)
    if server_tools:
        anth["tools"] = (anth.get("tools") or []) + server_tools
    if stream:
        anth["stream"] = True
    hdrs = anthropic_headers(headers.get("Authorization", ""))
    if not hdrs:
        message = ("Aucune authentification Claude Code trouvée. Connectez-vous avec "
                   "`claude` (Trousseau) ou renseignez ANTHROPIC_AUTH_TOKEN.")
        sys.stderr.write("[proxy %s] %s\n" % (DISPLAY, message))
        return 401, json.dumps({"error": {"type": "authentication_error",
                                          "message": message}}).encode(), "application/json"
    hdrs["Content-Type"] = "application/json"
    resp, error = _post_anthropic(anth, hdrs, server_tools)
    if error:
        observe_upstream_error(error[0], model=req.get("model"), slug=slug,
                               detail=upstream_error_detail(error[1]))
        return error[0], error[1], "application/json"
    # Responses always carry the slug Codex asked for, never the real model.
    if stream and tools_count > 0 and not restore_needed:
        return 200, _stream(resp, slug), "text/event-stream"
    if stream:
        # Bridged tool calls (and Desktop's tools=0 sessions) need the complete
        # response before it can be rewritten, so the stream is buffered.
        translator = AnthropicStreamTranslator(slug)
        for raw in resp:
            for line in raw.decode("utf-8", "replace").split("\n"):
                translator.feed(line)
        final = translator.response
        if tools_count == 0 and has_function_calls(final):
            final = complete_tool_calls_anthropic(req, hdrs, final)
        final["id"] = final.get("id") or f"resp_{uuid.uuid4().hex[:24]}"
        final["status"] = "completed"
        final["output"] = restore_output_items(final.get("output"), bridge,
                                               _restore_context(req, slug, headers))
        return 200, emit_stream_from_response(final), "text/event-stream"
    body = json.loads(resp.read().decode("utf-8"))
    out = anthropic_to_responses(body, slug)
    # When the client supplied tools, return the calls to that client so Codex
    # can execute them. Synthetic "tool unavailable" completion is only for
    # Desktop requests that explicitly supplied no tools.
    if tools_count == 0 and has_function_calls(out):
        out = complete_tool_calls_anthropic(req, hdrs, out)
    out["output"] = restore_output_items(out.get("output"), bridge,
                                         _restore_context(req, slug, headers))
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
        if self.path.startswith("/_switcher/upstream-models"):
            # Private route, used by the app to refresh the declared model list.
            # Never exposed to Codex: it returns the provider's real model ids.
            try:
                ids, source = upstream_models(self.headers.get("Authorization"))
                body = json.dumps({"models": ids, "source": source}).encode()
                status = 200
            except urllib.error.HTTPError as error:
                body = json.dumps({"models": [], "error": "http %d" % error.code}).encode()
                status = 200
            except Exception as error:
                body = json.dumps({"models": [], "error": str(error)}).encode()
                status = 200
            sys.stderr.write("[proxy %s] upstream-models: %s\n" % (DISPLAY, body[:200].decode()))
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
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
        if ADAPTER == "opencode-go" and self.path.startswith("/v1/responses") and data:
            try:
                req, bridge, _, slug = prepare_upstream_request(
                    json.loads(data), headers=self.headers)
                if req.get("model") not in OPENCODE_GO_RESPONSE_MODELS:
                    self.relay_opencode_chat(req, bridge, slug)
                    return
            except Exception:
                # malformed JSON and native Responses models continue through
                # the normal relay path, which has the original error handling.
                pass
        self.relay(body_bytes=data)

    def do_DELETE(self):
        self.relay()

    def relay_opencode_chat(self, req, bridge, slug):
        """Serve a Responses request by translating it to Chat Completions."""
        supplied = self.headers.get("Authorization")
        authorization = opencode_authorization(supplied, provider_id="opencode-go")
        if not authorization:
            self.send_response(401)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"error": {
                "type": "opencode_auth",
                "message": "Clé OpenCode Go manquante.",
            }}).encode())
            return

        should_stream = bool(req.get("stream")) or "text/event-stream" in (
            self.headers.get("Accept") or "")
        headers = {
            "Authorization": authorization,
            "Content-Type": "application/json",
            "Accept": "application/json",
        }
        headers.update(opencode_go_identity_headers(json.dumps(req).encode()))
        chat = responses_to_chat(req)
        try:
            request = urllib.request.Request(
                UPSTREAM + "/v1/chat/completions",
                data=json.dumps(chat).encode(),
                headers=headers,
                method="POST",
            )
            with urllib.request.urlopen(request, context=ssl_context(), timeout=180) as response:
                upstream = json.loads(response.read().decode("utf-8"))
            final = chat_to_responses(upstream, slug)
            if bridge_needs_restore(bridge):
                final["output"] = restore_output_items(
                    final.get("output"), bridge,
                    _restore_context(req, slug, self.headers))
            payload = emit_stream_from_response(final) if should_stream else json.dumps(final).encode()
            self.send_response(200)
            self.send_header("Content-Type",
                             "text/event-stream" if should_stream else "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
        except urllib.error.HTTPError as error:
            body = error.read()
            observe_upstream_error(error.code, model=req.get("model"), slug=slug,
                                   detail=upstream_error_detail(body))
            if error.code in (401, 402, 403, 500, 502, 503):
                try:
                    detail = (json.loads(body.decode("utf-8")).get("error") or {}).get("message", "")
                except Exception:
                    detail = ""
                body = json.dumps({"error": {
                    "type": "opencode_auth",
                    "message": ("OpenCode Go a renvoyé une erreur%s. Vérifiez votre abonnement Go "
                                "ou la clé saisie dans le panneau."
                                % (" (%s)" % detail if detail else "")),
                }}).encode()
            self.send_response(error.code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except Exception as error:
            observe_upstream_error(None, model=req.get("model"), slug=slug,
                                   detail=str(error))
            body = json.dumps({"error": {"type": "proxy_error", "message": str(error)}}).encode()
            self.send_response(502)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    def relay(self, body_bytes=None):
        url = UPSTREAM + self.path
        if body_bytes is None:
            length = int(self.headers.get("Content-Length") or 0)
            body_bytes = self.rfile.read(length) if length else None
        tools_count = 0
        req = None
        bridge = {}
        restore_needed = False
        slug = None
        if body_bytes and self.path.startswith("/v1/chat/completions"):
            try:
                body_bytes = json.dumps(normalize_chat_request(json.loads(body_bytes))).encode()
            except Exception:
                pass
        if body_bytes and self.path.startswith("/v1/responses"):
            try:
                req, bridge, tools_count, slug = prepare_upstream_request(
                    json.loads(body_bytes), headers=self.headers)
                restore_needed = bridge_needs_restore(bridge)
                body_bytes = json.dumps(req).encode()
            except Exception:
                req = None
        headers = {k: v for k, v in self.headers.items()
                   if k.lower() not in ("host", "accept-encoding", "content-length", "transfer-encoding")}
        if ADAPTER == "relay":
            # One credential path per mode. Relay providers use the credential
            # the app holds; it replaces any stale header the client carries.
            headers = managed_headers(headers)
        elif ADAPTER in ("opencode", "opencode-go"):
            # Codex sends no Authorization for a keyless provider; OpenCode Zen
            # needs one, so it is resolved from the managed key, OpenCode's own
            # credentials, then the public key (free tier only). Header names
            # keep the client's casing, hence the case-insensitive sweep.
            supplied = next((v for k, v in headers.items() if k.lower() == "authorization"), None)
            for key in [k for k in headers if k.lower() == "authorization"]:
                del headers[key]
            provider_id = "opencode-go" if ADAPTER == "opencode-go" else "opencode"
            headers["Authorization"] = opencode_authorization(supplied, provider_id=provider_id)
            if not headers["Authorization"]:
                # Go has no public-key fallback: let upstream say the key is
                # missing instead of sending a malformed empty Bearer header.
                del headers["Authorization"]
            if ADAPTER == "opencode-go":
                # Go validates client identity and benefits from stable routing
                # affinity. Replace any client values with this adapter's own.
                for key in [k for k in headers
                            if k.lower().startswith(("x-opencode-", "user-agent"))]:
                    del headers[key]
                headers.update(opencode_go_identity_headers(body_bytes))
        try:
            with urllib.request.urlopen(
                    urllib.request.Request(url, data=body_bytes, headers=headers, method=self.command),
                    context=ssl_context(), timeout=180) as resp:
                ctype = resp.headers.get("Content-Type", "")
                if "event-stream" in ctype and tools_count > 0 and not restore_needed:
                    # CLI sessions: live streaming, untouched.
                    self.send_response(resp.status)
                    for k, v in resp.headers.items():
                        # Never relay Content-Length here: the body is a stream,
                        # and rewriting the model name changes its length.
                        if k.lower() in ("content-type", "connection"):
                            self.send_header(k, v)
                    self.end_headers()
                    # Read line by line so the model name is never split across
                    # two chunks: every SSE event ends with a newline.
                    rewrite = None
                    if req and slug and slug != req.get("model"):
                        rewrite = (json.dumps(req.get("model"))[1:-1].encode(),
                                   json.dumps(slug)[1:-1].encode())
                    for line in resp:
                        if rewrite:
                            line = line.replace(rewrite[0], rewrite[1])
                        self.wfile.write(line)
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
                # Preserve real tool calls whenever the client supplied tools;
                # only Desktop's tools=0 fallback may synthesize tool results.
                if tools_count == 0 and req and has_function_calls(final):
                    final = complete_tool_calls_relay(UPSTREAM, req, headers, final)
                    final["id"] = final.get("id") or f"resp_{uuid.uuid4().hex[:24]}"
                    final["object"] = "response"
                    final["status"] = "completed"
                if restore_needed and isinstance(final, dict):
                    # Rebuild apply_patch / local_shell / renamed MCP calls in
                    # the shape Codex executes natively.
                    final["output"] = restore_output_items(
                        final.get("output"), bridge,
                        _restore_context(req, slug, self.headers))
                if slug and isinstance(final, dict) and final.get("model"):
                    # Codex must read back the slug it asked for, not the
                    # provider model that answered.
                    final["model"] = slug
                payload = (emit_stream_from_response(final)
                           if "event-stream" in ctype else json.dumps(final).encode())
                self.send_response(200)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
        except urllib.error.HTTPError as e:
            body = e.read()
            observe_upstream_error(e.code, model=(req or {}).get("model"), slug=slug,
                                   detail=upstream_error_detail(body))
            if ADAPTER in ("opencode", "opencode-go") and e.code in (401, 402, 403, 500, 502, 503):
                detail = ""
                try:
                    detail = (json.loads(body.decode("utf-8")).get("error") or {}).get("message", "")
                except Exception:
                    pass
                if ADAPTER == "opencode-go":
                    message = ("OpenCode Go a renvoyé une erreur%s. Vérifiez votre abonnement Go, "
                               "reliez la clé via OpenCode (`/connect` → OpenCode Go) ou saisissez-la "
                               "dans le panneau." % (" (%s)" % detail if detail else ""))
                else:
                    message = ("OpenCode Zen a renvoyé une erreur%s. Si le palier gratuit ne "
                               "répond plus, exécutez `opencode auth login` ou saisissez une clé "
                               "Zen dans le panneau." % (" (%s)" % detail if detail else ""))
                body = json.dumps({"error": {"type": "opencode_auth", "message": message}}).encode()
            self.send_response(e.code)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(body)
        except Exception as e:
            observe_upstream_error(None, model=(req or {}).get("model"), slug=slug,
                                   detail=str(e))
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
