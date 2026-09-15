#!/usr/bin/env python3
import http.server
import importlib.util
import json
import os
import pathlib
import shutil
import sys
import tempfile
import threading
import unittest
import urllib.request
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]
PROXY = ROOT / "Resources" / "provider-proxy.py"


class ProxyFixture:
    """Loads `provider-proxy.py` once with a third-party fixture configuration."""

    @classmethod
    def setUpClass(cls):
        # No test may ever write into the state directory the app owns: a stray
        # observation line would land in the user's `model-capabilities.json` as
        # a provider literally named "Test". Every fixture in this module runs
        # against a throwaway directory instead, and the observation tests
        # narrow it further per test.
        cls.fixtureStateDir = tempfile.mkdtemp(prefix="proxy-fixture-")
        cls.addClassCleanup(shutil.rmtree, cls.fixtureStateDir, True)
        cls.fixtureStatePatch = mock.patch.dict(os.environ, {
            "AI_PROVIDER_SWITCHER_STATE_DIR": cls.fixtureStateDir,
            "AI_PROVIDER_SWITCHER_PROVIDER_ID": "test-fixture",
        })
        cls.fixtureStatePatch.start()
        cls.addClassCleanup(cls.fixtureStatePatch.stop)
        spec = importlib.util.spec_from_file_location("provider_proxy", PROXY)
        cls.proxy = importlib.util.module_from_spec(spec)
        old_argv = sys.argv
        try:
            # Third-party fixture: full tool set (tools, apply_patch, images,
            # parallel calls) but no native custom-tool wire format, so every
            # Codex tool flavor must be bridged to function tools. The provider
            # also masquerades: Codex sees gpt-5.6-sol / gpt-5.5, the provider
            # answers as real-model-pro / real-model-lite.
            sys.argv = [str(PROXY), "18888", "https://example.test/v1", "Test",
                        "gpt-5.6-sol,gpt-5.5",
                        "relay", "1", "1", "1", "0", "1", "0",
                        "real-model-pro,real-model-lite"]
            spec.loader.exec_module(cls.proxy)
        finally:
            sys.argv = old_argv


class ProxyBehaviorTests(ProxyFixture, unittest.TestCase):
    def test_flat_responses_tool_is_translated(self):
        body = {
            "model": "model",
            "input": [{"type": "message", "role": "user", "content": "hello"}],
            "tools": [{
                "type": "function",
                "name": "read_file",
                "description": "Read a file",
                "parameters": {"type": "object", "properties": {"path": {"type": "string"}}},
            }],
        }
        anthropic = self.proxy.responses_to_anthropic(body)
        self.assertEqual(anthropic["tools"][0]["name"], "read_file")
        self.assertEqual(anthropic["tools"][0]["input_schema"]["properties"]["path"]["type"], "string")

    def test_tools_result_at_root_is_preserved(self):
        body = {
            "model": "model",
            "input": [
                {"type": "function_call", "call_id": "call-1", "name": "read_file", "arguments": "{}"},
                {"type": "function_call_output", "call_id": "call-1", "output": "contents"},
            ],
        }
        anthropic = self.proxy.responses_to_anthropic(body)
        self.assertEqual(anthropic["messages"][0]["content"][0]["type"], "tool_use")
        self.assertEqual(anthropic["messages"][1]["content"][0]["type"], "tool_result")
        self.assertEqual(anthropic["messages"][1]["content"][0]["content"], "contents")

    def test_model_catalog_omits_null_fields(self):
        model = json.loads(self.proxy.models_response())["models"][0]
        self.assertNotIn("upgrade", model)
        self.assertNotIn("context_window", model)
        self.assertNotIn("web_search_tool_type", model)

    def test_model_catalog_uses_declared_capabilities(self):
        model = json.loads(self.proxy.models_response())["models"][0]
        # `code_mode_only` would replace the classic tool set (shell,
        # apply_patch, MCP function tools) with a single freeform code tool.
        self.assertNotIn("tool_mode", model)
        self.assertTrue(model["supports_parallel_tool_calls"])
        self.assertFalse(model["supports_search_tool"])
        self.assertEqual(model["input_modalities"], ["text", "image"])
        self.assertTrue(model["include_plugin_usage_instructions"])

    def test_every_codex_tool_flavor_is_bridged_to_a_function_tool(self):
        tools = [
            {"type": "function", "name": "shell", "parameters": {"type": "object"}},
            {"type": "custom", "name": "exec", "format": {"type": "grammar"}},
            {"type": "custom", "name": "apply_patch", "format": {"type": "text"}},
            {"type": "local_shell"},
            {"type": "web_search"},
        ]
        bridged, bridge = self.proxy.bridge_tools(tools)
        self.assertEqual([tool["type"] for tool in bridged], ["function"] * 4)
        self.assertEqual([tool["name"] for tool in bridged],
                         ["shell", "exec", "apply_patch", "local_shell"])
        self.assertEqual(bridge["exec"], {"kind": "custom", "name": "exec"})
        self.assertEqual(bridge["local_shell"], {"kind": "local_shell", "name": "local_shell"})
        # Freeform tools travel through a single string property.
        exec_tool = next(t for t in bridged if t["name"] == "exec")
        self.assertEqual(exec_tool["parameters"]["required"], ["input"])
        self.assertTrue(self.proxy.bridge_needs_restore(bridge))

    def test_hosted_web_search_is_dropped_when_the_provider_cannot_run_it(self):
        bridged, bridge = self.proxy.bridge_tools([{"type": "web_search"}])
        self.assertEqual(bridged, [])
        self.assertEqual(bridge, {})

    def test_native_tool_flavors_are_forwarded_untouched_for_openai(self):
        original = self.proxy.SUPPORTS_CUSTOM_TOOLS
        try:
            self.proxy.SUPPORTS_CUSTOM_TOOLS = True
            tools = [{"type": "custom", "name": "apply_patch", "format": {"type": "text"}},
                     {"type": "local_shell"}]
            bridged, bridge = self.proxy.bridge_tools(tools)
            self.assertEqual(bridged, tools)
            self.assertEqual(bridge, {})
            self.assertFalse(self.proxy.bridge_needs_restore(bridge))
        finally:
            self.proxy.SUPPORTS_CUSTOM_TOOLS = original

    def test_mcp_tool_names_are_sanitized_and_restored(self):
        tools = [{"type": "function", "name": "mcp.node_repl/run",
                  "parameters": {"type": "object"}}]
        bridged, bridge = self.proxy.bridge_tools(tools)
        upstream_name = bridged[0]["name"]
        self.assertEqual(upstream_name, "mcp_node_repl_run")
        self.assertTrue(self.proxy.bridge_needs_restore(bridge))
        restored = self.proxy.restore_output_items(
            [{"type": "function_call", "call_id": "c1", "name": upstream_name,
              "arguments": "{}"}], bridge)
        self.assertEqual(restored[0]["name"], "mcp.node_repl/run")

    def test_bridged_calls_are_restored_to_codex_item_shapes(self):
        bridge = {"apply_patch": {"kind": "custom", "name": "apply_patch"},
                  "local_shell": {"kind": "local_shell", "name": "local_shell"}}
        output = [
            {"type": "function_call", "id": "fc1", "call_id": "c1", "name": "apply_patch",
             "arguments": json.dumps({"input": "*** Begin Patch"})},
            {"type": "function_call", "id": "fc2", "call_id": "c2", "name": "local_shell",
             "arguments": json.dumps({"command": ["ls", "-l"], "workdir": "/tmp"})},
        ]
        patch_call, shell_call = self.proxy.restore_output_items(output, bridge)
        self.assertEqual(patch_call["type"], "custom_tool_call")
        self.assertEqual(patch_call["input"], "*** Begin Patch")
        self.assertEqual(patch_call["call_id"], "c1")
        self.assertEqual(shell_call["type"], "local_shell_call")
        self.assertEqual(shell_call["action"],
                         {"type": "exec", "command": ["ls", "-l"], "workdir": "/tmp"})

    def test_raw_arguments_survive_when_the_model_ignores_the_wrapper(self):
        bridge = {"apply_patch": {"kind": "custom", "name": "apply_patch"}}
        restored = self.proxy.restore_output_items(
            [{"type": "function_call", "call_id": "c1", "name": "apply_patch",
              "arguments": "*** Begin Patch"}], bridge)
        self.assertEqual(restored[0]["input"], "*** Begin Patch")

    def test_bridged_history_is_rewritten_for_the_provider(self):
        bridge = {"apply_patch": {"kind": "custom", "name": "apply_patch"},
                  "local_shell": {"kind": "local_shell", "name": "local_shell"}}
        history = [
            {"type": "custom_tool_call", "call_id": "c1", "name": "apply_patch",
             "input": "*** Begin Patch"},
            {"type": "custom_tool_call_output", "call_id": "c1", "output": "ok"},
            {"type": "local_shell_call", "call_id": "c2",
             "action": {"type": "exec", "command": ["ls"]}},
            {"type": "local_shell_call_output", "call_id": "c2", "output": "README.md"},
        ]
        rewritten = self.proxy.bridge_input_items(history, bridge)
        self.assertEqual([item["type"] for item in rewritten],
                         ["function_call", "function_call_output",
                          "function_call", "function_call_output"])
        self.assertEqual(json.loads(rewritten[0]["arguments"]), {"input": "*** Begin Patch"})
        self.assertEqual(json.loads(rewritten[2]["arguments"]), {"command": ["ls"]})

    def test_masquerade_swaps_the_model_name_on_the_wire(self):
        req, _, _, slug = self.proxy.prepare_upstream_request(
            {"model": "gpt-5.6-sol", "input": "hi"})
        # The fixture exposes gpt-5.6-sol as the provider's real model.
        self.assertEqual(slug, "gpt-5.6-sol")
        self.assertEqual(req["model"], "real-model-pro")
        # A real model name (compatibility probe) is left untouched.
        self.assertEqual(self.proxy.upstream_model("real-model-pro"), "real-model-pro")
        # Unknown slugs are not invented away either.
        self.assertEqual(self.proxy.upstream_model("gpt-9"), "gpt-9")

    def test_no_tools_note_uses_a_portable_role(self):
        req, _, _, _ = self.proxy.prepare_upstream_request({
            "model": "model",
            "input": [{"type": "message", "role": "user", "content": "hi"}],
        })
        self.assertEqual(req["input"][-1]["role"], "system")
        chat = self.proxy.responses_to_chat(req)
        self.assertEqual([message["role"] for message in chat["messages"]],
                         ["system", "user"])
        self.assertNotIn("developer", json.dumps(chat))

    def test_developer_history_is_folded_into_system_for_chat_upstreams(self):
        chat = self.proxy.responses_to_chat({
            "model": "model",
            "input": [{
                "type": "message",
                "role": "developer",
                "content": [{"type": "input_text", "text": "follow this"}],
            }, {
                "type": "message",
                "role": "user",
                "content": [{"type": "input_text", "text": "hello"}],
            }],
        })
        self.assertEqual(chat["messages"][0], {
            "role": "system",
            "content": "follow this",
        })
        self.assertEqual(chat["messages"][1]["role"], "user")

    def test_developer_history_is_normalized_before_responses_relay(self):
        req, _, _, _ = self.proxy.prepare_upstream_request({
            "model": "model",
            "input": [{
                "type": "message",
                "role": "developer",
                "content": [{"type": "input_text", "text": "follow this"}],
            }],
            "tools": [{"type": "function", "name": "read_file"}],
        })
        self.assertEqual(req["input"][0]["role"], "system")

    def test_masquerade_catalog_uses_native_slugs_and_flavor(self):
        models = json.loads(self.proxy.models_response())["models"]
        self.assertEqual([m["slug"] for m in models], ["gpt-5.6-sol", "gpt-5.5"])
        # Native apply_patch flavor: the bridge restores the custom_tool_call.
        self.assertEqual(models[0]["apply_patch_tool_type"], "freeform")
        # The display name still says which provider really answers.
        self.assertEqual(models[0]["display_name"], "gpt-5.6-sol · Test")
        self.assertIn("real-model-pro", models[0]["description"])

    def test_response_reports_the_slug_codex_asked_for(self):
        body = json.dumps({"model": "gpt-5.6-sol",
                           "input": [{"type": "message", "role": "user", "content": "hi"}]}).encode()

        class FakeResponse:
            def read(self):
                return json.dumps({"content": [{"type": "text", "text": "ok"}],
                                   "model": "real-model-pro", "usage": {}}).encode()

        captured = {}
        def fake_urlopen(request, **kwargs):
            captured["body"] = json.loads(request.data.decode())
            return FakeResponse()

        with mock.patch.object(self.proxy, "_anthropic_oauth_token", return_value=None), \
             mock.patch.object(self.proxy.urllib.request, "urlopen", side_effect=fake_urlopen):
            code, payload, _ = self.proxy.do_anthropic_request(
                body, {"Authorization": "Bearer test"}, stream=False)

        self.assertEqual(code, 200)
        self.assertEqual(captured["body"]["model"], "real-model-pro")
        self.assertEqual(json.loads(payload)["model"], "gpt-5.6-sol")

    def test_opencode_auth_falls_back_to_the_public_free_tier_key(self):
        # Codex sends no Authorization for a keyless provider.
        with mock.patch.object(self.proxy, "opencode_stored_key", return_value=None):
            self.assertEqual(self.proxy.opencode_authorization(None), "Bearer public")
            self.assertEqual(self.proxy.opencode_authorization(""), "Bearer public")

    def test_opencode_prefers_its_own_stored_credential(self):
        with mock.patch.object(self.proxy, "opencode_stored_key", return_value="zen-key"):
            self.assertEqual(self.proxy.opencode_authorization(None), "Bearer zen-key")
        # A key supplied by the request still wins over both.
        with mock.patch.object(self.proxy, "opencode_stored_key", return_value="zen-key"):
            self.assertEqual(self.proxy.opencode_authorization("Bearer paid"), "Bearer paid")

    def test_relay_managed_credential_is_the_single_source_of_truth(self):
        with mock.patch.dict(self.proxy.os.environ,
                             {"AI_PROVIDER_SWITCHER_PROXY_API_KEY": "managed-key"}):
            # The managed key wins: a stale env_key must never shadow the key
            # the user just saved in the panel.
            self.assertEqual(
                self.proxy.managed_headers({})["Authorization"], "Bearer managed-key")
            self.assertEqual(
                self.proxy.managed_headers({"Authorization": "Bearer stale"})["Authorization"],
                "Bearer managed-key")
        # Without a managed key the client keeps its own (direct API tests).
        self.assertIsNone(self.proxy.managed_headers({}).get("Authorization"))
        self.assertEqual(
            self.proxy.managed_headers({"Authorization": "Bearer client-key"})["Authorization"],
            "Bearer client-key")

    def test_opencode_managed_credential_takes_priority(self):
        with mock.patch.dict(self.proxy.os.environ,
                             {"AI_PROVIDER_SWITCHER_PROXY_API_KEY": "zen-managed"}):
            self.assertEqual(self.proxy.opencode_authorization(None), "Bearer zen-managed")
            self.assertEqual(self.proxy.opencode_authorization("Bearer client"), "Bearer zen-managed")

    def test_opencode_go_uses_its_own_credential_without_free_fallback(self):
        with mock.patch.object(self.proxy, "managed_credential", return_value=None):
            with mock.patch.object(self.proxy, "opencode_stored_key",
                                   side_effect=lambda provider_id: "go-key"
                                   if provider_id == "opencode-go" else None):
                self.assertEqual(
                    self.proxy.opencode_authorization(None, provider_id="opencode-go"),
                    "Bearer go-key")
                self.assertEqual(
                    self.proxy.opencode_authorization("Bearer client", provider_id="opencode-go"),
                    "Bearer client")
                with mock.patch.object(self.proxy, "opencode_stored_key",
                                       return_value=None):
                    self.assertEqual(
                        self.proxy.opencode_authorization(None, provider_id="opencode-go"), "")

    def test_opencode_go_identity_headers_are_stable_per_conversation(self):
        body = json.dumps({
            "model": "grok-4.6",
            "input": [{"type": "message",
                       "content": [{"type": "input_text", "text": "hello"}]}],
        }).encode()
        first = self.proxy.opencode_go_identity_headers(body)
        second = self.proxy.opencode_go_identity_headers(body)
        self.assertEqual(first["x-opencode-session"], second["x-opencode-session"])
        self.assertTrue(first["x-opencode-session"].startswith("aips-"))
        self.assertNotEqual(first["x-opencode-session"], first["x-opencode-request"])
        self.assertEqual(first["x-opencode-client"], "ai-provider-switcher")
        self.assertIn("AIProviderSwitcher", first["User-Agent"])

    def test_anthropic_credentials_follow_claude_code_env_from_codex_config(self):
        import tempfile
        toml = """
model = "gpt-5.6"

[shell_environment_policy.set]
ANTHROPIC_AUTH_TOKEN = "zai-id.secret"
ANTHROPIC_BASE_URL = "https://api.z.ai/api/anthropic"

[projects."/tmp"]
trust_level = "trusted"
"""
        with tempfile.NamedTemporaryFile("w", suffix=".toml", delete=False) as handle:
            handle.write(toml)
            path = handle.name
        try:
            with mock.patch.object(self.proxy, "_anthropic_oauth_token", return_value=None), \
                 mock.patch.object(self.proxy.os.path, "expanduser", side_effect=lambda p: path):
                base, headers = self.proxy.anthropic_credentials("")
        finally:
            import os as _os
            _os.unlink(path)
        # A token issued for a gateway must stay on that gateway: never send a
        # Z.ai token to api.anthropic.com.
        self.assertEqual(base, "https://api.z.ai/api/anthropic")
        self.assertEqual(headers["Authorization"], "Bearer zai-id.secret")

    def test_thinking_blocks_are_exposed_as_reasoning_items(self):
        response = {
            "content": [
                {"type": "thinking", "thinking": "je reflechis"},
                {"type": "text", "text": "OK"},
            ],
            "usage": {},
        }
        out = self.proxy.anthropic_to_responses(response, "gpt-5.6-sol")
        types = [item["type"] for item in out["output"]]
        self.assertIn("reasoning", types)
        reasoning = next(i for i in out["output"] if i["type"] == "reasoning")
        self.assertEqual(reasoning["summary"][0]["text"], "je reflechis")
        # A response with only thinking must not be empty anymore.
        only_thinking = self.proxy.anthropic_to_responses(
            {"content": [{"type": "thinking", "thinking": "seul"}], "usage": {}}, "slug")
        self.assertEqual([i["type"] for i in only_thinking["output"]], ["reasoning"])

    def test_thinking_stream_emits_reasoning_sse_events(self):
        translator = self.proxy.AnthropicStreamTranslator("gpt-5.6-sol")
        lines = [
            'data: {"type":"message_start","message":{"usage":{"input_tokens":3}}}',
            'data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}',
            'data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"abc"}}',
            'data: {"type":"content_block_stop","index":0}',
            'data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}',
            'data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"OK"}}',
            'data: {"type":"content_block_stop","index":1}',
            'data: {"type":"message_stop"}',
        ]
        blob = b"".join(translator.feed(line) for line in lines).decode()
        self.assertIn("reasoning_summary_text.delta", blob)
        self.assertIn("output_text.delta", blob)
        self.assertEqual(translator.response["output"][0]["type"], "reasoning")
        self.assertEqual(translator.response["output"][0]["summary"][0]["text"], "abc")
        self.assertEqual(translator.response["output"][1]["content"][0]["text"], "OK")

    def test_opencode_stored_key_reads_the_cli_auth_file(self):
        import tempfile, pathlib
        for payload, expected in [({"opencode": {"key": "k1"}}, "k1"),
                                  ({"opencode": {"apiKey": "k2"}}, "k2"),
                                  ({"opencode": "k3"}, "k3"),
                                  ({"deepseek": {"key": "other"}}, None),
                                  ({}, None)]:
            with tempfile.TemporaryDirectory() as tmp:
                path = pathlib.Path(tmp) / "auth.json"
                path.write_text(json.dumps(payload))
                with mock.patch.object(self.proxy, "OPENCODE_AUTH_PATH", str(path)):
                    self.assertEqual(self.proxy.opencode_stored_key(), expected, payload)

    def test_model_ids_are_read_from_every_shape_providers_use(self):
        cases = [
            ({"data": [{"id": "a"}, {"id": "b"}]}, ["a", "b"]),
            ({"models": [{"slug": "a"}]}, ["a"]),
            ({"data": [{"id": "b"}, {"id": "a"}, {"id": "b"}]}, ["b", "a"]),
            (["a", "b"], ["a", "b"]),
            ({"error": "nope"}, []),
        ]
        for payload, expected in cases:
            self.assertEqual(self.proxy._ids_from_models_payload(payload), expected, payload)

    def test_opencode_models_come_from_the_cli_listing(self):
        listing = ("opencode/big-pickle\nopencode/hy3-free\n"
                   "deepseek/deepseek-v4-pro\n\nollama/qwen3:4b\n")

        class FakeRun:
            returncode = 0
            stdout = listing

        with mock.patch.object(self.proxy.os.path, "expanduser", side_effect=lambda p: p), \
             mock.patch.object(self.proxy.os, "access", return_value=True), \
             mock.patch.object(self.proxy.subprocess, "run", return_value=FakeRun()):
            # Only the free tier of the opencode provider is kept.
            self.assertEqual(self.proxy.opencode_cli_models(), ["big-pickle", "hy3-free"])

    def test_opencode_go_upstream_models_exposes_the_whole_gateway_catalog(self):
        """Discovery reports what the gateway really serves.

        This test used to assert the opposite (`gateway-responses`, Responses
        models only) because the adapter could not serve anything else: a
        Chat-only model had no wire contract. The adapter now translates a
        Responses request into Chat Completions (`relay_opencode_chat`), so
        hiding a model the gateway offers would remove a usable option instead
        of protecting the user. Discovery therefore reports the gateway list
        as it is (`gateway`), and the Multi-Agent capability store keeps the
        per-model verdict separate (see `ProxyOpenCodeGoRoutingTests` for the
        routing proof).
        """
        payload = {"data": [{"id": model} for model in [
            "grok-4.6", "kimi-k3", "gpt-5.6-luna", "qwen3.8-max"]]}
        with mock.patch.object(self.proxy, "ADAPTER", "opencode-go"), \
             mock.patch.object(self.proxy, "_get_json", return_value=payload), \
             mock.patch.object(self.proxy, "opencode_authorization",
                               return_value="Bearer go"):
            ids, source = self.proxy.upstream_models("")
        self.assertEqual(source, "gateway")
        self.assertEqual(ids, ["grok-4.6", "kimi-k3", "gpt-5.6-luna", "qwen3.8-max"])

    def test_opencode_go_model_families_are_split_by_their_wire_contract(self):
        # The two families the adapter serves; everything else the gateway
        # serves (37 ids at the time of writing) is Chat-only and translated.
        self.assertIn("grok-4.6", self.proxy.OPENCODE_GO_RESPONSE_MODELS)
        self.assertIn("gpt-5.6-luna", self.proxy.OPENCODE_GO_RESPONSE_MODELS)
        self.assertNotIn("kimi-k3", self.proxy.OPENCODE_GO_RESPONSE_MODELS)
        self.assertNotIn("qwen3.8-max", self.proxy.OPENCODE_GO_RESPONSE_MODELS)

    def test_discovery_tries_both_model_paths(self):
        # Some upstreams only serve /models (z.ai's legacy /api/paas/v4 base);
        # discovery falls back when /v1/models is missing.
        calls = []

        def fake_get(url, headers, timeout=20):
            calls.append(url)
            if url.endswith("/v1/models"):
                raise urllib.error.HTTPError(url, 404, "not found", {}, None)
            return {"data": [{"id": "glm-5.2"}]}

        import urllib.error
        with mock.patch.object(self.proxy, "_get_json", side_effect=fake_get):
            ids, source = self.proxy.upstream_models("Bearer k")
        self.assertEqual(ids, ["glm-5.2"])
        self.assertEqual(source, "upstream")
        self.assertEqual(len(calls), 2)

    def test_openai_only_request_fields_are_stripped(self):
        req = self.proxy.sanitize_upstream_request({
            "model": "model", "service_tier": "priority", "prompt_cache_key": "abc",
            "reasoning": {"effort": "xhigh"},
        })
        self.assertNotIn("service_tier", req)
        self.assertNotIn("prompt_cache_key", req)
        self.assertEqual(req["reasoning"]["effort"], "high")

    def test_openrouter_completion_budget_is_capped(self):
        original = self.proxy.IS_OPENROUTER
        try:
            self.proxy.IS_OPENROUTER = True
            missing = self.proxy.sanitize_upstream_request({"model": "model"})
            explicit = self.proxy.sanitize_upstream_request(
                {"model": "model", "max_output_tokens": 65536})
        finally:
            self.proxy.IS_OPENROUTER = original
        self.assertEqual(missing["max_output_tokens"], self.proxy.OPENROUTER_MAX_OUTPUT_TOKENS)
        self.assertEqual(explicit["max_output_tokens"], self.proxy.OPENROUTER_MAX_OUTPUT_TOKENS)

    def test_tool_filter_deduplicates_flat_and_nested_function_names(self):
        tools = [
            {"type": "function", "name": "read_file", "parameters": {"type": "object"}},
            {"type": "function", "function": {"name": "read_file", "parameters": {"type": "object"}}},
            {"type": "function", "name": "write_file", "parameters": {"type": "object"}},
        ]
        filtered = self.proxy.bridge_tools(tools)[0]
        self.assertEqual(len(filtered), 2)
        self.assertEqual(self.proxy._tool_name(filtered[0]), "read_file")
        self.assertEqual(self.proxy._tool_name(filtered[1]), "write_file")

    def test_probe_shape_has_no_tools_but_real_requests_are_deduplicated(self):
        probe = {"model": "model", "input": "ping", "stream": False}
        self.assertNotIn("tools", probe)
        request = {
            "model": "model",
            "input": "ping",
            "stream": False,
            "tools": [
                {"type": "function", "name": "read_file", "parameters": {"type": "object"}},
                {"type": "function", "name": "read_file", "parameters": {"type": "object"}},
                {"type": "custom", "name": "exec"},
            ],
        }
        bridged = self.proxy.bridge_tools(request["tools"])[0]
        self.assertEqual([tool["name"] for tool in bridged], ["read_file", "exec"])

    def test_anthropic_request_sends_unique_bridged_tools(self):
        body = json.dumps({
            "model": "model",
            "input": [{"type": "message", "role": "user", "content": "hello"}],
            "tools": [
                {"type": "function", "name": "read_file", "parameters": {"type": "object"}},
                {"type": "function", "name": "read_file", "parameters": {"type": "object"}},
                {"type": "custom", "name": "exec", "format": {"type": "text"}},
            ],
        }).encode()

        class FakeResponse:
            def __enter__(self):
                return self
            def __exit__(self, *args):
                return False
            def read(self):
                return json.dumps({"content": [{"type": "text", "text": "ok"}], "usage": {}}).encode()

        captured = {}
        def fake_urlopen(request, **kwargs):
            captured["body"] = json.loads(request.data.decode())
            return FakeResponse()

        with mock.patch.object(self.proxy, "_anthropic_oauth_token", return_value=None), \
             mock.patch.object(self.proxy.urllib.request, "urlopen", side_effect=fake_urlopen):
            code, _, _ = self.proxy.do_anthropic_request(
                body, {"Authorization": "Bearer test"}, stream=False
            )

        self.assertEqual(code, 200)
        names = [tool["name"] for tool in captured["body"]["tools"]]
        self.assertEqual(names, ["read_file", "exec"])

    def test_anthropic_translation_deduplicates_tool_names(self):
        body = {
            "model": "model",
            "input": [{"type": "message", "role": "user", "content": "hello"}],
            "tools": [
                {"type": "function", "name": "read_file", "parameters": {"type": "object"}},
                {"type": "function", "function": {"name": "read_file", "parameters": {"type": "object"}}},
                {"type": "function", "name": "write_file", "parameters": {"type": "object"}},
            ],
        }
        anthropic = self.proxy.responses_to_anthropic(body)
        self.assertEqual([tool["name"] for tool in anthropic["tools"]], ["read_file", "write_file"])

    def test_native_apply_patch_tool_is_bridged_once(self):
        bridged, bridge = self.proxy.bridge_tools([{"type": "apply_patch"},
                                                   {"type": "apply_patch"}])
        self.assertEqual([tool["name"] for tool in bridged], ["apply_patch"])
        self.assertEqual(bridge["apply_patch"]["kind"], "custom")

    def test_apply_patch_is_dropped_when_the_provider_does_not_declare_it(self):
        original = self.proxy.SUPPORTS_APPLY_PATCH
        try:
            self.proxy.SUPPORTS_APPLY_PATCH = False
            tools = [{"type": "apply_patch"},
                     {"type": "custom", "name": "apply_patch", "format": {"type": "text"}},
                     {"type": "function", "name": "read_file"}]
            self.assertEqual([t["name"] for t in self.proxy.bridge_tools(tools)[0]],
                             ["read_file"])
        finally:
            self.proxy.SUPPORTS_APPLY_PATCH = original

    def test_tool_bridge_removes_every_tool_when_the_adapter_disables_them(self):
        original = self.proxy.SUPPORTS_TOOLS
        try:
            self.proxy.SUPPORTS_TOOLS = False
            tools = [{"type": "function", "name": "read_file"}, {"type": "custom", "name": "exec"}]
            self.assertEqual(self.proxy.bridge_tools(tools)[0], [])
        finally:
            self.proxy.SUPPORTS_TOOLS = original

    def test_images_reach_claude_as_image_blocks(self):
        body = {
            "model": "model",
            "input": [{"type": "message", "role": "user", "content": [
                {"type": "input_text", "text": "what is this?"},
                {"type": "input_image", "image_url": "data:image/png;base64,QUJD"},
            ]}],
        }
        blocks = self.proxy.responses_to_anthropic(body)["messages"][0]["content"]
        self.assertEqual(blocks[1], {"type": "image", "source": {
            "type": "base64", "media_type": "image/png", "data": "QUJD"}})

    def test_chat_upstreams_never_receive_responses_image_parts(self):
        body = {
            "model": "model",
            "input": [{"type": "message", "role": "user", "content": [
                {"type": "input_text", "text": "describe this"},
                {"type": "input_image", "image_url": "data:image/png;base64,QUJD"},
            ]}],
        }
        chat = self.proxy.responses_to_chat(body)
        self.assertEqual(chat["messages"][0]["content"][1], {
            "type": "image_url",
            "image_url": {"url": "data:image/png;base64,QUJD"},
        })
        direct = self.proxy.normalize_chat_request({
            "messages": [{"role": "user", "content": [
                {"type": "input_image", "image_url": "data:image/png;base64,QUJD"},
            ]}],
        })
        self.assertEqual(direct["messages"][0]["content"][0]["type"], "image_url")
        self.assertNotIn("input_image", json.dumps(chat))
        self.assertNotIn("input_image", json.dumps(direct))

    def test_rich_tool_results_reach_chat_upstreams_as_text(self):
        # Computer-use and vision tools answer a `function_call_output` with a
        # list of input content parts. Relayed as is, OpenCode Go rejected the
        # entire request: `messages[186]: unknown variant `input_text`,
        # expected one of `text`, `image_url`, `file``.
        output = [
            {"type": "input_text", "text": "Wall time: 0.07 seconds\nOutput:"},
            {"type": "input_text", "text": "{\"application\":\"Veil\"}"},
        ]
        chat = self.proxy.responses_to_chat({
            "model": "model",
            "input": [
                {"type": "function_call", "call_id": "call-1",
                 "name": "list_windows", "arguments": "{}"},
                {"type": "function_call_output", "call_id": "call-1",
                 "output": output},
            ],
        })
        tool = [message for message in chat["messages"] if message["role"] == "tool"][0]
        self.assertEqual(tool["tool_call_id"], "call-1")
        self.assertEqual(tool["content"],
                         "Wall time: 0.07 seconds\nOutput:{\"application\":\"Veil\"}")
        self.assertNotIn("input_text", json.dumps(chat))

    def test_unknown_tool_result_parts_are_relayed_as_json_text(self):
        output = [{"type": "a_future_part_type", "value": 1}]
        chat = self.proxy.responses_to_chat({
            "model": "model",
            "input": [
                {"type": "function_call", "call_id": "call-1",
                 "name": "list_windows", "arguments": "{}"},
                {"type": "function_call_output", "call_id": "call-1",
                 "output": output},
            ],
        })
        tool = [message for message in chat["messages"] if message["role"] == "tool"][0]
        self.assertEqual(tool["content"], json.dumps(output))

    def test_text_only_tool_results_are_relayed_as_strings(self):
        # The string form is the one shape every Responses endpoint accepts,
        # including the gateways that implement Responses over Chat internally.
        req, _, _, _ = self.proxy.prepare_upstream_request({
            "model": "model",
            "input": [{
                "type": "function_call_output", "call_id": "call-1",
                "output": [{"type": "input_text", "text": "windows"},
                           {"type": "input_text", "text": ": none"}],
            }],
            "tools": [{"type": "function", "name": "list_windows"}],
        })
        self.assertEqual(req["input"][0]["output"], "windows: none")

    def test_tool_results_carrying_images_keep_their_parts(self):
        output = [{"type": "input_text", "text": "screenshot"},
                  {"type": "input_image", "image_url": "data:image/png;base64,QUJD"}]
        req, _, _, _ = self.proxy.prepare_upstream_request({
            "model": "model",
            "input": [{"type": "function_call_output", "call_id": "call-1",
                       "output": output}],
            "tools": [{"type": "function", "name": "view_image"}],
        })
        self.assertEqual(req["input"][0]["output"], output)

    def test_chat_requests_never_carry_responses_text_parts(self):
        direct = self.proxy.normalize_chat_request({
            "messages": [
                {"role": "tool", "tool_call_id": "call-1",
                 "content": [{"type": "input_text", "text": "ok"}]},
                {"role": "user", "content": [{"type": "output_text", "text": "hi"}]},
            ],
        })
        self.assertEqual(direct["messages"][0]["content"], [{"type": "text", "text": "ok"}])
        self.assertNotIn("input_text", json.dumps(direct))
        self.assertNotIn("output_text", json.dumps(direct))

    def test_anthropic_tool_results_use_text_content(self):
        body = {
            "model": "model",
            "input": [
                {"type": "function_call", "call_id": "call-1",
                 "name": "list_windows", "arguments": "{}"},
                {"type": "function_call_output", "call_id": "call-1", "output": [
                    {"type": "input_text", "text": "windows"},
                    {"type": "input_text", "text": "[]"},
                ]},
            ],
        }
        anthropic = self.proxy.responses_to_anthropic(body)
        result = anthropic["messages"][1]["content"][0]
        self.assertEqual(result["type"], "tool_result")
        self.assertEqual(result["content"], "windows[]")
        self.assertNotIn("input_text", json.dumps(anthropic))

    def test_web_search_maps_to_the_anthropic_server_tool(self):
        original = self.proxy.SUPPORTS_WEB_SEARCH
        try:
            self.proxy.SUPPORTS_WEB_SEARCH = True
            tools = self.proxy.anthropic_server_tools([{"type": "web_search"}])
            self.assertEqual(tools[0]["type"], "web_search_20250305")
            out = self.proxy.anthropic_to_responses({"content": [
                {"type": "server_tool_use", "id": "srv1", "name": "web_search",
                 "input": {"query": "codex mcp"}},
                {"type": "text", "text": "found it"},
            ], "usage": {}}, "model")
            self.assertEqual(out["output"][0]["type"], "web_search_call")
            self.assertEqual(out["output"][0]["action"]["query"], "codex mcp")
        finally:
            self.proxy.SUPPORTS_WEB_SEARCH = original

    def test_bridged_apply_patch_comes_back_as_a_custom_tool_call(self):
        body = json.dumps({
            "model": "model",
            "input": [{"type": "message", "role": "user", "content": "fix the typo"}],
            "tools": [{"type": "custom", "name": "apply_patch", "format": {"type": "text"}}],
        }).encode()

        class FakeResponse:
            def read(self):
                return json.dumps({"content": [{
                    "type": "tool_use", "id": "toolu_1", "name": "apply_patch",
                    "input": {"input": "*** Begin Patch"},
                }], "usage": {}}).encode()

        calls = []
        def fake_urlopen(request, **kwargs):
            calls.append(json.loads(request.data.decode()))
            return FakeResponse()

        with mock.patch.object(self.proxy, "_anthropic_oauth_token", return_value=None), \
             mock.patch.object(self.proxy.urllib.request, "urlopen", side_effect=fake_urlopen):
            code, payload, _ = self.proxy.do_anthropic_request(
                body, {"Authorization": "Bearer test"}, stream=False
            )

        self.assertEqual(code, 200)
        out = json.loads(payload)
        self.assertEqual(out["output"][0]["type"], "custom_tool_call")
        self.assertEqual(out["output"][0]["input"], "*** Begin Patch")
        self.assertEqual(out["output"][0]["call_id"], "toolu_1")
        # The client sent tools, so the call is returned to Codex instead of
        # being answered with a synthetic "tool unavailable" round trip.
        self.assertEqual(len(calls), 1)

    def test_anthropic_stream_exposes_function_call_arguments(self):
        translator = self.proxy.AnthropicStreamTranslator("model")
        events = b"".join([
            translator.feed('data: {"type":"content_block_start","content_block":{"type":"tool_use","id":"call-1","name":"read_file"}}\n'),
            translator.feed('data: {"type":"content_block_delta","delta":{"type":"input_json_delta","partial_json":"{\\"path\\":\\"README.md\\"}"}}\n'),
            translator.feed('data: {"type":"content_block_stop"}\n'),
        ]).decode()
        self.assertIn("response.function_call_arguments.delta", events)
        self.assertIn("response.function_call_arguments.done", events)
        self.assertIn("README.md", events)
        self.assertEqual(translator.response["output"][0]["arguments"], '{"path":"README.md"}')


def codex_collaboration_namespace():
    """The namespace Codex 0.154 really sends, captured from a live request.

    Tool specs are trimmed to the fields the bridge reads; the shape (a
    `namespace` tool whose `tools` are plain `function` tools) is verbatim.
    """
    return {
        "type": "namespace",
        "name": "collaboration",
        "description": "Tools for spawning and managing sub-agents.",
        "tools": [
            {"type": "function", "name": "followup_task", "description": "Follow up.",
             "parameters": {"type": "object", "properties": {}}, "strict": False},
            {"type": "function", "name": "list_agents", "description": "List agents.",
             "parameters": {"type": "object", "properties": {}}, "strict": False},
            {"type": "function", "name": "wait_agent",
             "description": "Wait for a mailbox update.",
             "parameters": {"type": "object",
                            "properties": {"timeout_ms": {"type": "number"}}},
             "strict": False},
            {"type": "function", "name": "spawn_agent",
             "description": "Spawn a sub-agent.",
             "parameters": {"type": "object",
                            "properties": {"task_name": {"type": "string"},
                                           "message": {"type": "string"}},
                            "required": ["task_name", "message"]},
             "strict": False},
        ],
    }


class ProxyNamespaceBridgeTests(ProxyFixture, unittest.TestCase):
    """Codex namespaces must reach routed providers as flat function tools."""

    def setUp(self):
        # Bridging emits observations; keep them out of the real side-car home.
        state_dir = tempfile.mkdtemp(prefix="proxy-bridge-events-")
        self.addCleanup(shutil.rmtree, state_dir, True)
        patcher = mock.patch.dict(self.proxy.os.environ, {
            "AI_PROVIDER_SWITCHER_STATE_DIR": state_dir,
            "AI_PROVIDER_SWITCHER_PROVIDER_ID": "test",
        })
        patcher.start()
        self.addCleanup(patcher.stop)
        self.proxy._BRIDGED_SIGNATURE = None

    def test_namespace_tools_are_flattened_to_provider_functions(self):
        bridged, bridge = self.proxy.bridge_tools([codex_collaboration_namespace()])
        self.assertEqual([tool["type"] for tool in bridged], ["function"] * 4)
        self.assertEqual([tool["name"] for tool in bridged],
                         ["collaboration__followup_task", "collaboration__list_agents",
                          "collaboration__wait_agent", "collaboration__spawn_agent"])
        self.assertEqual(
            bridge["collaboration__spawn_agent"],
            {"kind": "namespace", "namespace": "collaboration", "name": "spawn_agent"})
        # Schemas survive the flattening: the provider needs the real arguments.
        spawn = next(t for t in bridged if t["name"] == "collaboration__spawn_agent")
        self.assertEqual(spawn["parameters"]["required"], ["task_name", "message"])
        self.assertTrue(self.proxy.bridge_needs_restore(bridge))

    def test_namespaced_calls_are_restored_with_their_namespace(self):
        _, bridge = self.proxy.bridge_tools([codex_collaboration_namespace()])
        arguments = '{"task_name":"audit","message":"audit the repo"}'
        restored = self.proxy.restore_output_items([{
            "type": "function_call", "id": "fc_1", "call_id": "call_1",
            "name": "collaboration__spawn_agent", "arguments": arguments,
            "status": "completed",
        }], bridge)
        self.assertEqual(restored[0]["type"], "function_call")
        self.assertEqual(restored[0]["namespace"], "collaboration")
        self.assertEqual(restored[0]["name"], "spawn_agent")
        # Arguments, ids and status are preserved byte for byte.
        self.assertEqual(restored[0]["arguments"], arguments)
        self.assertEqual(restored[0]["id"], "fc_1")
        self.assertEqual(restored[0]["call_id"], "call_1")
        self.assertEqual(restored[0]["status"], "completed")
        self.assertNotIn("collaboration__spawn_agent", json.dumps(restored))

    def test_round_trip_returns_to_the_first_mapping(self):
        original_tools = [codex_collaboration_namespace()]
        state = self.proxy._ToolBridgeState()
        bridged, bridge = self.proxy.bridge_tools(original_tools, state)
        provider_call = {"type": "function_call", "call_id": "call_9",
                         "name": "collaboration__wait_agent",
                         "arguments": '{"timeout_ms": 30000}'}
        restored = self.proxy.restore_output_items([provider_call], bridge)
        # Codex executes the call, then replays it in the next turn's history.
        history = [restored[0], {"type": "function_call_output",
                                 "call_id": "call_9", "output": "agent finished"}]
        replayed = self.proxy.bridge_input_items(history, bridge)
        self.assertEqual(replayed[0]["type"], "function_call")
        self.assertEqual(replayed[0]["name"], provider_call["name"])
        self.assertNotIn("namespace", replayed[0])
        self.assertEqual(replayed[0]["arguments"], provider_call["arguments"])
        self.assertEqual(replayed[0]["call_id"], "call_9")
        # The correlation id survives, so the provider can match the result.
        self.assertEqual(replayed[1]["type"], "function_call_output")
        self.assertEqual(replayed[1]["call_id"], "call_9")
        self.assertEqual([t["name"] for t in bridged].count(provider_call["name"]), 1)

    def test_namespaced_history_without_a_mapping_still_loses_its_wrapper(self):
        # A restarted proxy forgets the bridge the call was made under. The
        # history Codex replays must still reach the provider: no tool is ever
        # declared with a `namespace` key, so forwarding one is a protocol
        # error the provider rejects for the whole request.
        history = [{"type": "function_call", "call_id": "call_old",
                    "namespace": "collaboration", "name": "spawn_agent",
                    "arguments": "{}"}]
        replayed = self.proxy.bridge_input_items(history, {})
        self.assertNotIn("namespace", replayed[0])
        self.assertEqual(replayed[0]["name"], "spawn_agent")
        self.assertEqual(replayed[0]["call_id"], "call_old")

    def test_flat_and_namespaced_tools_never_collide(self):
        tools = [
            {"type": "function", "name": "search", "parameters": {"type": "object"}},
            {"type": "namespace", "name": "alpha", "tools": [
                {"type": "function", "name": "search", "parameters": {"type": "object"}}]},
            {"type": "namespace", "name": "beta", "tools": [
                {"type": "function", "name": "search", "parameters": {"type": "object"}}]},
        ]
        bridged, bridge = self.proxy.bridge_tools(tools)
        names = [tool["name"] for tool in bridged]
        self.assertEqual(names, ["search", "alpha__search", "beta__search"])
        self.assertEqual(len(set(names)), len(names))
        # Two namespaces exposing the same tool stay independently addressable.
        self.assertEqual(bridge["alpha__search"]["namespace"], "alpha")
        self.assertEqual(bridge["beta__search"]["namespace"], "beta")
        restored = self.proxy.restore_output_items(
            [{"type": "function_call", "call_id": "c1", "name": "beta__search",
              "arguments": "{}"}], bridge)
        self.assertEqual((restored[0]["namespace"], restored[0]["name"]), ("beta", "search"))

    def test_namespace_sub_tool_colliding_with_a_flat_name_is_disambiguated(self):
        tools = [
            {"type": "function", "name": "collaboration__spawn_agent",
             "parameters": {"type": "object"}},
            codex_collaboration_namespace(),
        ]
        bridged, bridge = self.proxy.bridge_tools(tools)
        names = [tool["name"] for tool in bridged]
        self.assertIn("collaboration__spawn_agent", names)
        # The namespace tool is published under a distinct provider-safe name.
        self.assertIn("collaboration__spawn_agent_2", names)
        self.assertEqual(bridge["collaboration__spawn_agent"], {"kind": "function",
                       "name": "collaboration__spawn_agent"})
        self.assertEqual(bridge["collaboration__spawn_agent_2"],
                         {"kind": "namespace", "namespace": "collaboration",
                          "name": "spawn_agent"})

    def test_multiple_namespaces_are_supported_simultaneously(self):
        tools = [codex_collaboration_namespace(),
                 {"type": "namespace", "name": "plugin_management", "tools": [
                     {"type": "function", "name": "list_plugins",
                      "parameters": {"type": "object"}}]}]
        bridged, bridge = self.proxy.bridge_tools(tools)
        self.assertEqual([tool["name"] for tool in bridged],
                         ["collaboration__followup_task", "collaboration__list_agents",
                          "collaboration__wait_agent", "collaboration__spawn_agent",
                          "plugin_management__list_plugins"])
        self.assertEqual(bridge["plugin_management__list_plugins"]["namespace"],
                         "plugin_management")

    def test_unknown_namespace_shapes_fail_soft(self):
        tools = [
            {"type": "namespace", "tools": [{"type": "function", "name": "x"}]},
            {"type": "namespace", "name": "empty", "tools": "nope"},
            {"type": "namespace", "name": "weird", "tools": [
                {"type": "custom", "name": "exec", "format": {"type": "text"}},
                {"type": "function", "name": "kept", "parameters": {"type": "object"}},
                {"name": "typeless", "parameters": {"type": "object"}},
                "not-a-dict"]},
            {"type": "function", "name": "shell", "parameters": {"type": "object"}},
        ]
        bridged, bridge = self.proxy.bridge_tools(tools)
        # Unknown shapes are skipped; the rest of the request still bridges.
        self.assertEqual([tool["name"] for tool in bridged],
                         ["weird__kept", "weird__typeless", "shell"])
        self.assertEqual(bridge["weird__kept"]["kind"], "namespace")
        self.assertEqual(bridge["shell"], {"kind": "function", "name": "shell"})

    def test_namespaces_nested_in_additional_tools_are_bridged(self):
        # The fallback Codex path carries tools inside a developer item.
        # `additional_tools` is a Codex-only item type: no third-party endpoint
        # implements it, and a strict one rejects the whole request over it, so
        # the envelope is consumed and every tool it carried is bridged into
        # the provider's `tools` array (none of them is dropped).
        request = {
            "model": "model",
            "input": [
                {"type": "additional_tools", "id": "at_1", "role": "developer",
                 "tools": [{"type": "function", "name": "wait",
                            "parameters": {"type": "object"}},
                           codex_collaboration_namespace()]},
                {"type": "message", "role": "user", "content": "hi"},
            ],
        }
        req, bridge, _, _ = self.proxy.prepare_upstream_request(request)
        names = [tool["name"] for tool in req["tools"]]
        self.assertIn("collaboration__spawn_agent", names)
        self.assertIn("wait", names)
        self.assertEqual([i.get("type") for i in req["input"]], ["message"])
        self.assertEqual(bridge["collaboration__spawn_agent"]["kind"], "namespace")
        self.assertEqual(bridge["wait"], {"kind": "function", "name": "wait"})

    def test_existing_tool_flavors_are_untouched_by_the_namespace_support(self):
        tools = [
            {"type": "function", "name": "exec_command",
             "parameters": {"type": "object"}},
            {"type": "custom", "name": "apply_patch", "format": {"type": "text"}},
            {"type": "local_shell"},
            {"type": "web_search"},
            {"type": "function", "name": "mcp.node_repl/run",
             "parameters": {"type": "object"}},
            codex_collaboration_namespace(),
        ]
        bridged, bridge = self.proxy.bridge_tools(tools)
        self.assertEqual([tool["name"] for tool in bridged],
                         ["exec_command", "apply_patch", "local_shell",
                          "mcp_node_repl_run", "collaboration__followup_task",
                          "collaboration__list_agents", "collaboration__wait_agent",
                          "collaboration__spawn_agent"])
        self.assertEqual(bridge["apply_patch"], {"kind": "custom", "name": "apply_patch"})
        self.assertEqual(bridge["local_shell"], {"kind": "local_shell",
                                                 "name": "local_shell"})
        self.assertEqual(bridge["exec_command"], {"kind": "function",
                                                  "name": "exec_command"})
        # The hosted tool is still dropped rather than invented as a function.
        self.assertNotIn("web_search", [tool["name"] for tool in bridged])


def codex_agent_message(payload, message_type="NEW_TASK",
                        recipient="/root/count_files"):
    """The envelope Codex stamps on an inter-agent message.

    Copied from a real child-thread request: the text the other agent must read
    sits in an `encrypted_content` part, which no third-party endpoint
    implements. OpenCode Go answered `422` while this shape was relayed as is.
    """
    return {
        "type": "agent_message",
        "id": "amsg_01a0a073-c37d-7ea3-afd2-a546d3b1562a",
        "author": "/root",
        "recipient": recipient,
        "content": [
            {"type": "input_text",
             "text": "Message Type: %s\nTask name: %s\nSender: /root\nPayload:\n"
                     % (message_type, recipient)},
            {"type": "encrypted_content", "encrypted_content": payload},
        ],
    }


def codex_child_request():
    """A child-thread request reduced to the shapes Codex really sends:
    a `developer` message, the `agent_message` task envelope, a namespaced
    tool, and the reasoning item a `store = false` session replays."""
    return {
        "model": "gpt-5.6-sol",
        "instructions": "You are Codex, an agent based on GPT-6.",
        "stream": True,
        "store": False,
        "parallel_tool_calls": True,
        "tool_choice": "auto",
        "reasoning": {"effort": "high"},
        "include": ["reasoning.encrypted_content"],
        "text": {"verbosity": "low"},
        "client_metadata": {"thread_id": "child-1",
                            "x-openai-subagent": "collab_spawn",
                            "x-codex-parent-thread-id": "root-1"},
        "tools": [
            codex_collaboration_namespace(),
            {"type": "function", "name": "exec_command",
             "parameters": {"type": "object"}},
        ],
        "input": [
            {"type": "message", "role": "developer",
             "content": [{"type": "input_text", "text": "Follow the task."}]},
            {"type": "reasoning", "id": "rs_1", "content": None,
             "summary": [{"type": "summary_text", "text": "planning"}],
             "encrypted_content": "EpKB8JXeS8lOZJGRswP4sp600IgOnwtM5/vhPik"},
            codex_agent_message("Count the files present in this folder."),
        ],
    }


class ProxyCodexOnlyItemTests(ProxyFixture, unittest.TestCase):
    """Codex-only input items must never reach a third-party endpoint.

    Measured against the real gateway: OpenCode Go answers `422` for an
    `agent_message` item and `400` for a `reasoning` item carrying the
    `encrypted_content` blob — including the blob it produced itself one turn
    earlier. Either one kills the whole child turn, so the rule is "relay only
    what the provider implements", never "special-case grok-4.6".
    """

    def test_agent_messages_become_portable_user_messages(self):
        req, _, _, _ = self.proxy.prepare_upstream_request({
            "model": "gpt-5.6-sol",
            "input": [{"type": "message", "role": "user", "content": "go"},
                      codex_agent_message("Count the files.")],
            "tools": [{"type": "function", "name": "exec_command",
                       "parameters": {"type": "object"}}],
        })
        self.assertEqual([item["type"] for item in req["input"]],
                         ["message", "message"])
        envelope = req["input"][-1]
        self.assertEqual(envelope["role"], "user")
        # The task text lives in an `encrypted_content` part: it must survive,
        # otherwise the child receives an empty task.
        self.assertEqual([part["type"] for part in envelope["content"]],
                         ["input_text", "input_text"])
        self.assertIn("NEW_TASK", envelope["content"][0]["text"])
        self.assertIn("Count the files.", envelope["content"][1]["text"])
        self.assertNotIn("agent_message", json.dumps(req))

    def test_empty_agent_messages_are_dropped(self):
        req, _, _, _ = self.proxy.prepare_upstream_request({
            "model": "gpt-5.6-sol",
            "input": [{"type": "agent_message", "id": "amsg_1",
                       "author": "/root", "recipient": "/root/x",
                       "content": []},
                      {"type": "message", "role": "user", "content": "hi"}],
            "tools": [{"type": "function", "name": "exec_command",
                       "parameters": {"type": "object"}}],
        })
        self.assertEqual([item["type"] for item in req["input"]], ["message"])

    def test_encrypted_reasoning_drops_the_blob_but_keeps_the_summary(self):
        req, _, _, _ = self.proxy.prepare_upstream_request({
            "model": "gpt-5.6-sol",
            "input": [{"type": "reasoning", "id": "rs_1", "content": None,
                       "summary": [{"type": "summary_text", "text": "thinking"}],
                       "encrypted_content": "EpKB8JXeS8lOZJGRswP4"}],
            "tools": [{"type": "function", "name": "exec_command",
                       "parameters": {"type": "object"}}],
        })
        item = req["input"][0]
        self.assertEqual(item["type"], "reasoning")
        self.assertEqual(item["summary"], [{"type": "summary_text", "text": "thinking"}])
        self.assertNotIn("encrypted_content", item)
        # `content: null` is rejected as well, so the slot is removed entirely.
        self.assertNotIn("content", item)

    def test_unknown_codex_only_items_are_dropped_rather_than_relayed(self):
        req, _, _, _ = self.proxy.prepare_upstream_request({
            "model": "gpt-5.6-sol",
            "input": [{"type": "future_codex_item", "value": 1},
                      {"type": "message", "role": "user", "content": "hi"}],
            "tools": [{"type": "function", "name": "exec_command",
                       "parameters": {"type": "object"}}],
        })
        self.assertEqual([item["type"] for item in req["input"]], ["message"])

    def test_child_request_is_provider_compatible(self):
        req, bridge, _, _ = self.proxy.prepare_upstream_request(codex_child_request())
        raw = json.dumps(req)
        for forbidden in ("agent_message", "additional_tools", "encrypted_content",
                          '"namespace"', '"content": null'):
            self.assertNotIn(forbidden, raw)
        self.assertEqual(req["input"][-1]["role"], "user")
        self.assertEqual(req["input"][0]["role"], "system")
        self.assertIn("collaboration__spawn_agent",
                      [tool["name"] for tool in req["tools"]])
        self.assertEqual(bridge["collaboration__spawn_agent"]["kind"], "namespace")

    def test_child_keeps_the_real_upstream_model(self):
        req, _, _, slug = self.proxy.prepare_upstream_request(codex_child_request())
        # Codex must read back the slug it asked for, the gateway the real id.
        self.assertEqual(slug, "gpt-5.6-sol")
        self.assertEqual(req["model"], "real-model-pro")
        self.assertNotIn("gpt-5.6-sol", json.dumps(req))

    def test_replayed_namespaced_call_drops_the_namespace_key(self):
        bridge = {"collaboration__spawn_agent": {
            "kind": "namespace", "namespace": "collaboration", "name": "spawn_agent"}}
        items = self.proxy.bridge_input_items([{
            "type": "function_call", "id": "fc_1", "call_id": "call_1",
            "namespace": "collaboration", "name": "spawn_agent",
            "arguments": '{"task_name":"count_files"}'}], bridge)
        self.assertEqual(items[0]["name"], "collaboration__spawn_agent")
        self.assertNotIn("namespace", items[0])
        # The provider's own `function_call_output` correlation is untouched.
        outputs = self.proxy.bridge_input_items([{
            "type": "function_call_output", "call_id": "call_1", "output": "ok"}],
            bridge)
        self.assertEqual(outputs[0], {"type": "function_call_output",
                                      "call_id": "call_1", "output": "ok"})


class ProxyOpenCodeGoRoutingTests(ProxyFixture, unittest.TestCase):
    """Which wire contract each OpenCode Go model gets.

    The ids listed in `OPENCODE_GO_RESPONSE_MODELS` answer the Responses API
    directly; every other id the gateway serves is reached through the
    Responses -> Chat Completions translation. Both routes are exercised against
    a local stub, so this test needs no network, no key and no model.
    """

    def setUp(self):
        self.calls = []
        test = self

        class StubHandler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                length = int(self.headers.get("Content-Length") or 0)
                body = self.rfile.read(length) if length else b""
                test.calls.append((self.path, json.loads(body or b"{}")))
                if self.path.endswith("/chat/completions"):
                    payload = {"id": "chatcmpl-1", "object": "chat.completion",
                               "model": "chat-model",
                               "choices": [{"index": 0, "finish_reason": "stop",
                                            "message": {"role": "assistant",
                                                        "content": "ok"}}]}
                else:
                    payload = {"id": "resp_1", "object": "response",
                               "status": "completed", "model": "responses-model",
                               "output": [{"id": "msg_1", "type": "message",
                                           "role": "assistant", "status": "completed",
                                           "content": [{"type": "output_text",
                                                        "text": "ok"}]}]}
                data = json.dumps(payload).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, *args):
                pass

        self.upstream = http.server.ThreadingHTTPServer(("127.0.0.1", 0), StubHandler)
        threading.Thread(target=self.upstream.serve_forever, daemon=True).start()
        self.addCleanup(self.upstream.shutdown)

        self.state_dir = tempfile.mkdtemp(prefix="proxy-routing-")
        self.addCleanup(shutil.rmtree, self.state_dir, True)
        environment = mock.patch.dict(os.environ, {
            "AI_PROVIDER_SWITCHER_STATE_DIR": self.state_dir,
            "AI_PROVIDER_SWITCHER_PROVIDER_ID": "opencode-go",
            "AI_PROVIDER_SWITCHER_PROXY_API_KEY": "go-fixture-key",
        })
        environment.start()
        self.addCleanup(environment.stop)
        for attribute, value in (
                ("ADAPTER", "opencode-go"),
                ("UPSTREAM", "http://127.0.0.1:%d" % self.upstream.server_address[1])):
            patcher = mock.patch.object(self.proxy, attribute, value)
            patcher.start()
            self.addCleanup(patcher.stop)

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), self.proxy.Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.shutdown)
        self.port = self.server.server_address[1]

    def post(self, model):
        request = urllib.request.Request(
            "http://127.0.0.1:%d/v1/responses" % self.port,
            data=json.dumps({
                "model": model, "stream": False,
                "input": [{"type": "message", "role": "user",
                           "content": [{"type": "input_text", "text": "hi"}]}],
            }).encode(),
            headers={"Content-Type": "application/json"}, method="POST")
        with urllib.request.urlopen(request, timeout=60) as response:
            return response.status, json.loads(response.read().decode())

    def test_response_capable_model_is_relayed_to_the_responses_api(self):
        status, _ = self.post("grok-4.6")
        self.assertEqual(status, 200)
        self.assertEqual([path for path, _ in self.calls], ["/v1/responses"])
        self.assertEqual(self.calls[0][1]["model"], "grok-4.6")

    def test_chat_only_model_is_translated_to_chat_completions(self):
        status, _ = self.post("kimi-k3")
        self.assertEqual(status, 200)
        self.assertEqual([path for path, _ in self.calls], ["/v1/chat/completions"])
        self.assertEqual(self.calls[0][1]["model"], "kimi-k3")


class ProxyMultiAgentObservationTests(ProxyFixture, unittest.TestCase):
    """What the proxy records, and what it must never record."""

    def setUp(self):
        self.state_dir = tempfile.mkdtemp(prefix="proxy-events-")
        self.addCleanup(shutil.rmtree, self.state_dir, True)
        patcher = mock.patch.dict(self.proxy.os.environ, {
            "AI_PROVIDER_SWITCHER_STATE_DIR": self.state_dir,
            "AI_PROVIDER_SWITCHER_PROVIDER_ID": "glm",
        })
        patcher.start()
        self.addCleanup(patcher.stop)
        # Observation state is per process in production (one proxy per
        # provider); reset it so each test observes its own traffic.
        self.proxy._BRIDGED_SIGNATURE = None
        self.proxy._RESTORED_CALLS.clear()
        self.proxy._COMPLETED_CALLS.clear()
        self.proxy._CHILD_THREADS.clear()

    def events(self):
        path = os.path.join(self.state_dir, self.proxy.EVENTS_FILE_NAME)
        if not os.path.exists(path):
            return []
        with open(path) as handle:
            return [json.loads(line) for line in handle if line.strip()]

    def test_real_spawn_cycle_is_observed_end_to_end(self):
        request = {
            "model": "gpt-5.6-sol",
            "input": [{"type": "message", "role": "user", "content": "audit this repo"}],
            "tools": [codex_collaboration_namespace()],
        }
        headers = {"x-codex-turn-metadata": json.dumps(
            {"thread_id": "root-1", "thread_source": "user"})}
        req, bridge, _, slug = self.proxy.prepare_upstream_request(request, headers=headers)
        self.assertEqual(req["model"], "real-model-pro")
        bridged = self.events()
        self.assertEqual([e["event"] for e in bridged], ["multi_agent_tools_bridged"])
        self.assertEqual(bridged[0]["provider"], "glm")
        self.assertIn("collaboration.spawn_agent", bridged[0]["tools"])
        self.assertEqual(bridged[0]["bridge_version"], 1)

        restored = self.proxy.restore_output_items([{
            "type": "function_call", "id": "fc_1", "call_id": "call_1",
            "name": "collaboration__spawn_agent",
            "arguments": '{"task_name":"audit","message":"secret prompt"}',
        }], bridge, {"model": req["model"], "slug": slug,
                     "thread": {"thread_id": "root-1"}})
        self.assertEqual(restored[0]["namespace"], "collaboration")
        restored_events = self.events()
        self.assertEqual(restored_events[-1]["event"], "multi_agent_tool_restored")
        self.assertEqual(restored_events[-1]["tool"], "spawn_agent")
        self.assertEqual(restored_events[-1]["call_id"], "call_1")

        # Codex executed the call and replays it with its result next turn.
        self.proxy.prepare_upstream_request({
            "model": "gpt-5.6-sol",
            "input": [restored[0], {"type": "function_call_output",
                                    "call_id": "call_1", "output": "child says hi"}],
            "tools": [codex_collaboration_namespace()],
        }, headers=headers)
        self.assertIn("multi_agent_tool_result", [e["event"] for e in self.events()])

        # A real child thread asks for its first turn, stamped with its parent.
        self.proxy.prepare_upstream_request({
            "model": "gpt-5.6-sol",
            "input": [{"type": "message", "role": "user", "content": "reply ready"}],
            "tools": [codex_collaboration_namespace()],
        }, headers={"x-codex-turn-metadata": json.dumps(
            {"thread_id": "child-1", "parent_thread_id": "root-1",
             "thread_source": "subagent", "subagent_kind": "thread_spawn"}),
            "x-codex-parent-thread-id": "root-1"})
        child = [e for e in self.events() if e["event"] == "multi_agent_child_thread"]
        self.assertEqual(len(child), 1)
        self.assertEqual(child[0]["parent_thread_id"], "root-1")
        self.assertEqual(child[0]["tools"], ["collaboration.spawn_agent"])

    def test_observation_files_never_contain_user_content(self):
        request = {
            "model": "gpt-5.6-terra",
            "input": [{"type": "message", "role": "user",
                       "content": "PROMPT_MARKER_do_not_store"}],
            "tools": [codex_collaboration_namespace()],
        }
        headers = {"x-codex-turn-metadata": json.dumps({"thread_id": "root-1"})}
        req, bridge, _, slug = self.proxy.prepare_upstream_request(request, headers=headers)
        self.proxy.restore_output_items([{
            "type": "function_call", "call_id": "call_1",
            "name": "collaboration__spawn_agent",
            "arguments": '{"message":"ARGUMENT_MARKER_do_not_store"}',
        }], bridge, {"model": req["model"], "slug": slug,
                     "thread": {"thread_id": "root-1"}})
        self.proxy.prepare_upstream_request({
            "model": "gpt-5.6-terra",
            "input": [{"type": "function_call_output", "call_id": "call_1",
                       "output": "OUTPUT_MARKER_do_not_store"}],
            "tools": [codex_collaboration_namespace()],
        }, headers=headers)
        raw = open(os.path.join(self.state_dir, self.proxy.EVENTS_FILE_NAME)).read()
        for marker in ("PROMPT_MARKER", "ARGUMENT_MARKER", "OUTPUT_MARKER",
                       "authorization", "api_key", "token"):
            self.assertNotIn(marker, raw)
        self.assertTrue(self.events())

    def test_infrastructure_errors_are_inconclusive_never_incompatible(self):
        for status, reason in ((401, "authentication_required"),
                               (402, "insufficient_balance"),
                               (403, "forbidden"),
                               (429, "rate_limited"),
                               (500, "provider_error"),
                               (503, "provider_error")):
            verdict, classified = self.proxy.classify_upstream_error(status)
            self.assertEqual(verdict, "inconclusive")
            self.assertEqual(classified, reason)
        # DNS / timeout / network failures carry no HTTP status at all.
        self.assertEqual(self.proxy.classify_upstream_error(None),
                         ("inconclusive", "network"))
        self.proxy.observe_upstream_error(402, model="real-model-pro", slug="gpt-5.6-sol")
        event = self.events()[-1]
        self.assertEqual(event["event"], "multi_agent_upstream_error")
        self.assertEqual(event["verdict"], "inconclusive")
        self.assertEqual(event["reason"], "insufficient_balance")

    def test_provider_refusals_keep_a_reason_the_app_can_name(self):
        # A strict gateway refusing one item of a child request is not proof the
        # model cannot run a Multi-Agent workflow, so 400/422 stay inconclusive.
        # They still need a name of their own: `MultiAgentFailureReason` in
        # Sources/AIProviderSwitcherCore/MultiAgentCapability.swift declares
        # exactly these codes, otherwise the panel falls back to "Cause inconnue"
        # and the user learns nothing from a real protocol refusal.
        self.assertEqual(self.proxy.classify_upstream_error(400),
                         ("inconclusive", "invalid_request"))
        self.assertEqual(self.proxy.classify_upstream_error(422),
                         ("inconclusive", "unsupported_request"))
        for status in (400, 422, 409):
            verdict, _ = self.proxy.classify_upstream_error(status)
            self.assertEqual(verdict, "inconclusive", status)

    def test_tool_bridge_signature_is_recorded_once_per_change(self):
        request = {"model": "gpt-5.6-terra",
                   "input": [{"type": "message", "role": "user", "content": "hi"}],
                   "tools": [codex_collaboration_namespace()]}
        for _ in range(5):
            self.proxy.prepare_upstream_request(request, headers={})
        self.assertEqual([e["event"] for e in self.events()],
                         ["multi_agent_tools_bridged"])

    def test_requests_without_namespaces_are_not_observed(self):
        self.proxy.prepare_upstream_request({
            "model": "gpt-5.6-terra",
            "input": [{"type": "message", "role": "user", "content": "hi"}],
            "tools": [{"type": "function", "name": "shell",
                       "parameters": {"type": "object"}}],
        }, headers={})
        self.assertEqual(self.events(), [])


if __name__ == "__main__":
    unittest.main()
