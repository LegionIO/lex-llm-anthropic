# Changelog

## [0.3.3] - 2026-08-17

### Changed
- **SSOT v3 fail-forward instance identity** — `DiscoveryRefresh` now publishes the operator's
  config NAME as the `InstanceKey` `instance_id` (the key the router resolves `instances.<name>`
  settings by); the derived `host:port` / `host:port/ak:<8-char credential digest>` rides along as
  the secondary `physical_id` for dedup and diagnostics only (excluded from InstanceKey
  equality/hash). Two config names on the same endpoint + credential stay distinct instances
  (no collapse). Reserved config names (`default` — the synthetic settings bucket) are skipped at
  the claim boundary with a log instead of raising `ValidationError` every tick.
- **Embedding models publish authoritative operation evidence** — Models served as the embedding
  class (catalog `type: 'embedding'` or `embed` in the model id) publish `chat: :unsupported`
  (all chat operations unsupported) and `embed: :supported` with `:provider_catalog` source, so a
  plain chat request can never misroute to them; their capability evidence is
  `embedding: :supported` and nothing else (no completion/tools/etc.). Non-embedding models are
  unchanged.
- **lex-llm floor raised to 0.7.1** — Requires the SSOT v3 inventory foundation with config-name
  `instance_id` + secondary `physical_id` support on `InstanceKey` and the publisher API.

### Fixed
- **Single actor registration** — The provider module no longer extends Core at file level, so the
  boot-time submodule walk skips it and the gem's own top-level extension load is the sole actor
  registration (eliminates the double-claim / `FencedPublisherError`).
- **Synthetic-default skip warn now fires once per boot** — The `synthetic_default` skip warning
  (unmodified `instances.default` template) is throttled to once per actor lifetime instead of
  every discovery tick (was permanent WARN noise — an unconfigured provider is the normal state).

## [0.3.2] - 2026-08-13

### Fixed
- **§1 settings guards removed (R2 pass)** — Eliminated remaining `||` fallbacks on registered
  settings in `Provider#render_payload` (`|| 4096` on `settings[:default_max_tokens]`) and
  `Translator#settings_default_max_tokens` / `#default_thinking_budget` / `#prompt_caching_settings`.
  Registered `default_thinking_budget: 1024` as a canonical default in `Anthropic.default_settings`.
  Replaced `Legion::Settings.dig(...)` + `|| {}` in `Translator#prompt_caching_settings` with direct
  access via the registered default — `Translator#initialize` now seeds `@config` from the
  registered instance defaults so all settings keys are always present without a Settings fallback.
- **§2 dead second publication engine removed** — Deleted `attr_writer :registry_publisher` and the
  `registry_publisher` class method from `Provider`. The artifact was non-functional (no callers)
  but violated the single-publication-path invariant by keeping the old `RegistryPublisher`
  reachable from the class interface.

## [0.3.1] - 2026-08-13

### Fixed
- **§8 health firewall** — Removed the connection_failure → :instance_unavailable promotion from
  `AnthropicSsotHarness#apply_anthropic_escalation`. Connection failures, timeouts, 529
  `overloaded_error`, and generic 5xx are all request-local and must never mutate global instance
  availability. Added `AnthropicExplicitUnavailableError` as the explicit service-unavailable signal
  for conformance harness testing; rewrote the firewall assertion to prove `Faraday::ConnectionFailed`
  stays `:connection_failure`, never `:instance_unavailable`.
- **§9 default model injection removed** — `Translator#render_request` no longer injects
  `'claude-sonnet-4'` when the canonical request carries no model. An omitted model is an empty
  constraint, never a default; the Anthropic API will reject the request if required fields are absent.
- **§2/§5 second publication engine removed** — `Provider#discover_offerings` no longer calls
  `registry_publisher.publish_models_async`. The SSOT v3 `DiscoveryRefresh` actor is now the only
  publication path. Removed the now-unused `discovery_registry_readiness` private method.
- **§1 swallowed rescue removed** — Replaced `coordinator&.finish_probe rescue nil` with
  explicit `begin/rescue` that calls `handle_exception` so finish_probe errors are logged and never
  silently swallowed. Removed `# rubocop:disable Style/RescueModifier` inline annotations.
- **§1 settings guards removed** — Eliminated `||` fallbacks and `.dig` guards on registered
  settings in `DiscoveryRefresh`. Added `discovery_interval: 3600` as a registered default in
  `Anthropic.default_settings`; all settings are now read through the standards-defined access path.

## [0.3.0] - 2026-08-13

### Changed
- **SSOT v3 provider migration** — Replaced the ScopedRefresher-based `DiscoveryRefresh` actor with a
  full SSOT v3 actor backed by `Legion::Extensions::Llm::Inventory::Publisher`. The actor claims instances,
  discovers models via safe `GET /v1/models` (no inference), runs readiness probing, and publishes complete
  `OfferingDraft` snapshots atomically. Supports tick-based refresh and coalesced reactive probes via
  `ProbeCoordinator` after dispatch-triggered `instance_unavailable` transitions.
- **`AnthropicCallable`** — New callable wrapper implementing `disconnect` and
  `normalize_dispatch_error(error:)`. Anthropic 529 `overloaded_error` is always `:overloaded`, never
  `:instance_unavailable`. Only transport-layer `ConnectionFailed` maps to `:connection_failure` (which
  the actor harness may escalate). 429 → `:rate_limited`, timeouts → `:timeout`.
- **Instance identity** — Derived from normalized endpoint host:port + SHA256 8-char credential fingerprint
  (`host:port/ak:XXXXXXXX`). Stable across restarts; deterministic from inputs.
- **Operations** — chat/stream_chat: supported; embed/image/transcribe/translate/speak/moderate: unsupported;
  count_tokens: unknown. Source evidence: `:provider_implementation` for supported/unsupported,
  `:default_false` for unknown.
- **Capabilities** — completion/streaming/tools/vision: supported (`:provider_implementation`); thinking:
  unknown (`:default_false` unless model metadata indicates reasoning); embedding: unsupported.
- **Removed** `DEFAULT_MODEL` constant, `resolve_default_model` method, and `default_model` injection
  from `discover_instances`. No default model or provider in SSOT v3.
- **Removed** `RegistryEventBuilder` — replaced by the common `Inventory::Publisher`.
- **Fleet worker** — Added `registry: Legion::Extensions::Llm::Inventory::Registry` kwarg to
  `ProviderResponder.call`.
- **Gemspec** — Raised `lex-llm` floor to `>= 0.7.0`.
- **Conformance spec** — Added `spec/legion/extensions/llm/anthropic_ssot_v3_conformance_spec.rb` with
  `AnthropicSsotHarness` and `it_behaves_like 'an SSOT v3 provider adapter'` plus provider-specific
  assertions (identity, 529-always-overloaded, two-instance lane isolation, ProbeCoordinator coalescing,
  no DEFAULT_MODEL, no Legion::LLM reverse dependency).

## [0.2.28] - 2026-08-04

### Changed
- Align release metadata for the current Anthropic provider package.

## [0.2.27] - 2026-07-09

### Fixed
- **Claude models now advertise the `:thinking` capability.** `resolve_model_capabilities` passed `provider_catalog: {}` to `CapabilityPolicy.resolve`, so per-model capabilities from the shared lex-llm catalog (which correctly tags Claude 3.7 / 4+ models `reasoning` → `:thinking`, and vision) were ignored — Claude models reported only completion/streaming/tools, so the router's thinking filter could not route thinking requests correctly. It now consults the shared catalog via `catalog_capabilities(model_id)`; unknown models fall back to the provider envelope (no `:thinking`). No hardcoded capability list — the shared catalog (refreshed from provider APIs + models.dev) is the source of truth.

## [0.2.26] - 2026-06-20

### Fixed
- Stub shared registry publishing through `RegistryPublisher#schedule` in specs so async availability-event coverage stays stable after the shared publisher moved off raw `Thread.new`.

## [0.2.25] - 2026-06-20

### Fixed
- Stop bulk-publishing Anthropic model availability from `list_models`; discovery now emits one registry event per seen model from the shared `lex-llm` policy-filter path so blocked models stay observable without duplicate publishes.

## [0.2.24] - 2026-06-20

### Fixed
- Route Anthropic capability overrides through the shared `lex-llm` provider contract so provider, instance, and model settings all resolve through the same canonical capability vocabulary.

## [0.2.23] - 2026-06-19

### Changed
- Adopt `Legion::Extensions::Llm::Inventory::ScopedRefresher` mixin (lex-llm 0.6.0). Discovery
  refresh actors now write directly to the live `Inventory` catalog via `Inventory.write_lane`.
- Pin `lex-llm >= 0.6.0` and `legion-llm >= 0.14.0` in gemspec.
- Standard `weight: 100` default added to provider instance settings schema.

## 0.2.21 - 2026-06-17

### Changed
- **Policy-aware default model** — `default_model` is no longer a hardcoded literal forced via `||=`. The `claude-sonnet-4-6` fallback is now a named `DEFAULT_MODEL` constant applied through `Provider.policy_safe_default_model`, so a configured `model_whitelist`/`model_blacklist` is never overridden: if neither the configured default nor the fallback is permitted, `default_model` is left unset and routing resolves an allowed discovered model instead. (Fixes the case where a haiku-only whitelist still surfaced a sonnet default.) Requires lex-llm >= 0.5.4.

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
