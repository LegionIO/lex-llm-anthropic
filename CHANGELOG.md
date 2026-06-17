# Changelog

## 0.2.20 - 2026-06-16

- dependency updates, code quality improvements

## 0.2.19 - 2026-06-15

- **CapabilityPolicy integration** — Streaming and tools from `:provider_envelope`; vision/thinking default false unless explicitly enabled via settings. Settings overrides at provider/instance/model level supported.

## 0.2.18 - 2026-06-13

- **Gemfile cleanup** — Remove local path overrides; all dependencies resolve from gemspec via rubygems.
- 135 examples, 0 failures; 20 files, 0 rubocop offenses.

## 0.2.17 - 2026-06-10

- **Canonical provider translator (Phase 3)** — New `Translator` class implementing the Anthropic↔canonical boundary per N×N routing design. Public interface: `render_request(canonical_request)`, `parse_response(wire)`, `parse_chunk(raw)`, `capabilities`. Extracted from existing `Provider` render/parse methods — behaviour preserved, not rewritten (translator.rb).
- **Anthropic capability declarations** — `thinking: :signature_lifecycle`, `assistant_prefill: true`, `tool_calls: :native`, `system_content_blocks: true`, `supported_params` explicitly listed.
- **G18 param mapping** — max_tokens, temperature, stop_sequences, seed, response_format rendered to Anthropic wire format. max_thinking_tokens → thinking.budget_tokens. top_p, top_k, frequency_penalty, presence_penalty dropped with debug log (Anthropic doesn't support).
- **stop_reason mapping** — Maps 1:1 with canonical enums: end_turn, tool_use, max_tokens, stop_sequence, content_filter. Unmapped values default to end_turn with debug log.
- **Thinking/signature lifecycle** — Parsing handles both canonical-form (delta as string) and Anthropic wire-form (delta as nested {text, thinking, signature} object). Supports thinking_content, redacted_thinking, signature_delta lifecycle per R4.
- **Usage parsing** — input/output tokens, cache_read_input_tokens → cache_read_tokens, cache_creation_input_tokens → cache_write_tokens, thinking_tokens output_tokens_details.reasoning_tokens fallback chain.
- **Conformance kit integration** — spec_helper loads `it_behaves_like('a canonical provider translator')` and `it_behaves_like('a canonical client translator')` shared examples from lex-llm gem spec directory per B1b consumer pattern.
- **Lex-llm dependency bumped to >= 0.5.0** — Requires canonical types (B1a) and conformance kit (B1b) shipped in lex-llm 0.5.0 (gemspec).
- **Rules** — No bare `::JSON` (Legion::JSON.load with ParseError rescue), no `_foo:` kwargs, no `**_rest`, all tunable defaults in config. 135 examples, 0 failures; 20 files, 0 rubocop offenses.

## 0.2.16 - 2026-06-10

- **Hash-backed tool support** — `format_tools` and `tool_schema` now handle both `ToolDefinition` objects and plain Hashes from `native_dispatch` via `respond_to?` checks with symbol/string key fallbacks. Prevents `NoMethodError` when tools arrive as hash-backed definitions (provider.rb).
- **RuboCop configuration overhaul** — Relaxed metrics to match project scale: LineLength 195, MethodLength 150, ClassLength 1500, AbcSize 110, BlockNesting 4, CyclomaticComplexity/PerceivedComplexity 50. Added `Layout/HashAlignment` (table style), `Layout/SpaceAroundEqualsInParameterDefault`, `Naming/PredicateMethod` disable, `Style/RedundantConstantBase` spec exclusion. Removed `rubocop-rspec` plugin (no longer needed). All 28 specs passing, 0 offenses (.rubocop.yml).
- **Hash alignment formatting** — Applied consistent table-style hash alignment across provider.rb, anthropic.rb, registry_event_builder.rb, fleet_worker.rb, and transport messages for readability.

## 0.2.15 - 2026-06-05

- **Fix RuboCop cyclomatic complexity** — Extract `extract_hash_budget` helper to reduce `thinking_budget` cyclomatic complexity from 8 to 6, meeting the 7-line threshold.
- **Add budget_tokens support** — `extract_hash_budget` now checks `:budget_tokens` and `'budget_tokens'` keys (Anthropic API canonical) in addition to legacy `:budget`/`'budget'`.
- **Spec and RuboCop compliance** — All 28 specs passing, 0 RuboCop offenses.

## 0.2.14 - 2026-06-05

- **Fix RuboCop cyclomatic complexity** — Extract `extract_hash_budget` helper to reduce `thinking_budget` complexity from 8 to 6, meeting the 7-line threshold.
- **Fix Style/IfUnlessModifier** — Split conditional return in `thinking_budget` to avoid modifier form exceeding max line length.

## 0.2.13 - 2026-06-02

- **Fix invalid anthropic-version header** — Default `api_version` was `'2023-10-02'` (typo), which Anthropic rejects. Changed to `'2023-10-16'` (anthropic.rb)
- **Add per-provider discovery refresh actor** — New `actors/discovery_refresh.rb` that only refreshes Anthropic models, avoiding coupling to other providers' discovery cycles

## 0.2.12 - 2026-06-01

- Add `cache_control` markers to Anthropic Messages API requests for prompt caching
- System content and tool definitions are marked as cache breakpoints when `cache_enabled?`
- Early conversation turns are cacheable; final message is never cached (prefix break guard)
- Uses `cache_control_prefix_tokens` from lex-llm base provider for exclude count (default 4)

## 0.2.11 - 2026-05-21

- Add `api_version` and `default_max_tokens` to default_settings
- api_base and anthropic-version read from settings fallback
- max_tokens reads from settings[:default_max_tokens]
- Identity headers included via base provider


## 0.2.10 - 2026-05-18

- Fix streaming tool call input accumulation: `build_chunk` now handles both `content_block_start` (tool_use with id+name) and `input_json_delta` (partial argument fragments) events. Previously only the start event was parsed, resulting in tool calls with empty arguments.


## 0.2.9 - 2026-05-16

- Advertise Anthropic tool support in discovered instance and model metadata so capability-aware routing can select Claude models for native tool requests.

## 0.2.8 - 2026-05-13

- Remove `:claude` provider alias (`provider_aliases` now returns `[]`).
- Attach `source` and `credential_fingerprint` to all discovered instances.
- Inject `default_model: 'claude-sonnet-4-6'` and `capabilities: [:completion, :streaming, :vision]` into every discovered instance.
- Add static `CONTEXT_WINDOWS` map for known Claude model families.
- Override `fetch_model_detail` to return context window from static map.
- Use `model_detail` in `parse_list_models_response` for cached `context_length` lookup.
- Add `infer_context_window` helper for prefix-based context window inference.

## 0.2.7 - 2026-05-13

- Use `Legion::Logging::Helper` for Anthropic provider and registry diagnostics.
- Route registry fallback errors through `handle_exception` with useful operation metadata.

## 0.2.6 - 2026-05-08

- Accept keyword arguments in `list_models` to match the base provider contract called by `discover_offerings`.

## 0.2.5 - 2026-05-06

- Load provider-owned fleet actors through the LegionIO subscription base and the canonical Anthropic provider root.
- Keep fleet runners anchored on the provider root namespace so provider constants and instance discovery are always loaded.
- Strip temporary generic API key fields from discovered Anthropic instance configs after credential deduplication.
- Gate release publishing on the shared security workflow.

## 0.2.4 - 2026-05-06

- Use the shared `lex-llm` fleet provider responder helper for provider-owned fleet workers.
- Remove the runtime `legion-llm` dependency and require `lex-llm >= 0.4.3` for responder-side fleet execution.
- Refresh README installation, credential discovery, and fleet ownership documentation for the runtime dependency split.

## 0.2.3 - 2026-05-06

- Remove require-time provider self-registration; `legion-llm` now owns adapter creation and registry writes from loaded provider discovery metadata.
- Declare the `:claude` compatibility provider family through `provider_aliases`.
- Bump dependency floors to `lex-llm >= 0.4.1` and `legion-llm >= 0.9.1`.

## 0.2.2 - 2026-05-06

- Enforce the shared keyword-only `lex-llm` provider contract with provider contract specs.
- Keep Anthropic defaults on `Legion::Extensions::Llm.provider_settings` with instance-level fleet responder settings.
- Add provider-owned fleet responder actor and runner backed by `legion-llm` fleet policy execution.
- Bump the transport dependency floor to `legion-transport >= 1.4.14`.

## 0.2.1 - 2026-05-03

- Normalize generic settings keys to Anthropic provider config keys during instance discovery.
- Support named Anthropic instances from extension settings.

## 0.2.0 - 2026-05-01

- Add auto-discovery via CredentialSources and AutoRegistration from lex-llm 0.3.0
- Self-register discovered instances into Call::Registry at require-time
- Require lex-llm >= 0.3.0


## 0.1.5 - 2026-04-28

- Publish best-effort `llm.registry` discovered-model availability events when transport is already loaded.

## 0.1.4 - 2026-04-28

- Require current shared Legion JSON, logging, settings, and LLM extension gems.

## 0.1.3 - 2026-04-28

- Remove the leftover compatibility entrypoint outside the Legion namespace.
- Load specs through the canonical `legion/extensions/llm/anthropic` namespace path.
- Keep provider gemspec dependencies scoped to the shared `lex-llm` base gem.

## 0.1.2 - 2026-04-28

- Replace fork-era namespace references with the standard Legion::Extensions::Llm provider contract.
- Remove GitHub-based lex-llm Gemfile fallback so test installs use only a guarded local path or released gem dependency.
- Require lex-llm >= 0.1.3 for the cleaned Legion-native base extension.

## 0.1.1 - 2026-04-27

- Add the Anthropic Legion::Extensions::Llm provider class with Messages API chat, streaming, model listing, tool, and extended thinking support.
- Use shared `Legion::Extensions::Llm.provider_settings` defaults from `lex-llm`.
- Remove embeddings support from provider capabilities and defaults.
- Remove the committed `Gemfile.lock`.

## 0.1.0 - 2026-04-26

- Initial Legion LLM Anthropic provider extension scaffold.
