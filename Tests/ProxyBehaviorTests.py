#!/usr/bin/env python3
import importlib.util
import json
import pathlib
import sys
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]
PROXY = ROOT / "Resources" / "provider-proxy.py"


class ProxyBehaviorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
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

    def test_opencode_go_upstream_models_keeps_response_capable_models_only(self):
        payload = {"data": [{"id": model} for model in [
            "grok-4.6", "kimi-k3", "gpt-5.6-luna", "qwen3.8-max"]]}
        with mock.patch.object(self.proxy, "ADAPTER", "opencode-go"), \
             mock.patch.object(self.proxy, "_get_json", return_value=payload), \
             mock.patch.object(self.proxy, "opencode_authorization",
                               return_value="Bearer go"):
            ids, source = self.proxy.upstream_models("")
        self.assertEqual(source, "gateway-responses")
        self.assertEqual(ids, ["grok-4.6", "gpt-5.6-luna"])

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


if __name__ == "__main__":
    unittest.main()
