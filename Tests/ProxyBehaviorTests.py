#!/usr/bin/env python3
import importlib.util
import json
import pathlib
import sys
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
PROXY = ROOT / "Resources" / "provider-proxy.py"


class ProxyBehaviorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("provider_proxy", PROXY)
        cls.proxy = importlib.util.module_from_spec(spec)
        old_argv = sys.argv
        try:
            sys.argv = [str(PROXY), "18888", "https://example.test/v1", "Test", "model", "relay", "1", "1", "0", "1"]
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

    def test_model_catalog_uses_declared_capabilities(self):
        model = json.loads(self.proxy.models_response())["models"][0]
        self.assertEqual(model["apply_patch_tool_type"], "freeform")
        self.assertTrue(model["supports_parallel_tool_calls"])
        self.assertFalse(model["supports_search_tool"])
        self.assertEqual(model["input_modalities"], ["text", "image"])

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
