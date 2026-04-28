# Changelog

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
