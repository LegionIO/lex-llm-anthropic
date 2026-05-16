# Changelog

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
