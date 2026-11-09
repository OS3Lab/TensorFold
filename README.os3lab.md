# OS3Lab TensorFold: Codex Responses compatibility

This branch preserves the deployed DeepSeek-V4.1-Flash-1017 serving source and adds Responses API compatibility for Codex clients. It is pinned to the qualified engine, rather than rebased onto the latest TensorFold release.

## Source lineage

- Engine: [bertholomus/TensorFold](https://github.com/bertholomus/TensorFold), commit `fbbc97132cd004237d9887b8d3185896efaedc5c`.
- Serving recipe: [MiaAI-Lab/DeepSeek-v4.1-Flash-1017-2x-DGX-Sparks](https://github.com/MiaAI-Lab/DeepSeek-v4.1-Flash-1017-2x-DGX-Sparks), commit `f424dfe3b14ac9f02fe12f5777c852dba967a79a`.
- The recipe's 34 serving patches are imported as individual commits with patch names, SHA256 hashes and original attribution notes. See [recipe credits](docs/os3lab/recipe-CREDITS.md) and [recipe notice](docs/os3lab/recipe-NOTICE.txt). These copies describe the source recipe, including components not bundled in this fork.
- The subsequent OS3Lab commit contains the Responses compatibility implementation and regression tests. No CUDA, model arithmetic, quantization or speculative-decoding settings are changed by that compatibility commit.

## Supported behavior

- Accept known Responses `include` selectors, including `reasoning.encrypted_content`, without fabricating encrypted content.
- Flatten namespaced function tools internally with collision checks, then restore their original names and namespaces in complete responses, SSE output items and stored/stateless history.
- Adapt custom/freeform tools through a required string input and return `custom_tool_call` items and corresponding SSE input events. Quoting, Unicode and newlines round-trip.
- Preserve the original tool inventory and tool choice in Responses metadata.

## Limits

Custom-tool grammar definitions are passed as model instructions, not enforced by a grammar-constrained sampler. Custom input SSE is emitted after the complete wrapped arguments have been parsed. Encrypted-only reasoning history is unsupported. Hosted tools such as `web_search` are explicitly rejected; for the tested Codex client, set the top-level `web_search = "disabled"` option. This does not add built-in browsing.

## Validation

Before publication, all 1,317 source files were compared byte-for-byte with the deployed source snapshot. All five compatibility-file SHA256 hashes also matched the deployment manifest. The publication adds documentation only beyond that source snapshot.

The identical compatibility source passed the following checks on two DGX Spark devices on 2026-11-09:

- 191 server unit tests and 30 HTTP/SSE contract cases.
- Six live GPU acceptance cases covering namespaced/custom tool calls, stored/stateless replay, streaming, Chat Completions and Anthropic Messages.
- Codex CLI 0.166 acceptance: local command tool execution and a real namespaced tool dispatch followed by another model turn.

These are deployment acceptance results, not a fresh build on the repository host and not a claim of compatibility with every future Codex client. Private requests, logs, credentials, model files and machine-specific deployment configuration are not included.

To run the server unit suite in a Linux environment with the pinned Zig version:

```sh
ZIG=/opt/zig/zig bash zig/tests/server/zig_test.sh
```

Use the upstream [packaging guide](packaging/README.md) for native build requirements. The recipe's separately pinned inputs tools, CUDA kernel kit and model preparation remain external dependencies; this repository alone is not a complete deployment bundle. No running deployment was changed during this publication.
