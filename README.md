# lex-llm-anthropic

LegionIO LLM provider extension for Anthropic.

This gem lives under `Legion::Extensions::Llm::Anthropic` and depends on `lex-llm >= 0.4.3` for shared provider contracts, response normalization, fleet responder helpers, and schema primitives. It does not require `legion-llm` at runtime.

Load it with `require 'legion/extensions/llm/anthropic'`.

## Installation

```ruby
gem 'lex-llm-anthropic', '~> 0.2'
```

Anthropic credentials are discovered from `ANTHROPIC_API_KEY`, Claude config, configured provider instances, or an identity broker when one is available.

## Provider

`Legion::Extensions::Llm::Anthropic::Provider` registers with `Legion::Extensions::Llm::Provider` as `:anthropic` and uses Anthropic's Messages API:

- chat and streaming: `/v1/messages`
- model discovery: `/v1/models`
- authentication headers: `x-api-key` and `anthropic-version`
- tools: Anthropic `tools` and `tool_choice` payload fields
- extended thinking: Anthropic `thinking` request field and returned thinking blocks

Anthropic embeddings are intentionally not exposed by this provider.

## Configuration

```ruby
Legion::Extensions::Llm.configure do |config|
  config.anthropic_api_key = ENV.fetch('ANTHROPIC_API_KEY')
  config.anthropic_version = '2023-06-01'
end
```

`anthropic_api_base` can override the default `https://api.anthropic.com` endpoint for tests or compatible Anthropic gateways.

Named instances can use generic provider keys such as `api_key`, `endpoint`, and `version`; the extension normalizes them to Anthropic-specific provider options during discovery.

## Fleet Responder

Provider instances can opt in to consuming Legion LLM fleet requests. The provider-owned fleet actor only starts when at least one configured instance enables `respond_to_requests`.

```yaml
extensions:
  llm:
    anthropic:
      instances:
        local:
          fleet:
            enabled: true
            respond_to_requests: true
            capabilities:
              - chat
              - stream_chat
```

Fleet execution is delegated to `Legion::Extensions::Llm::Fleet::ProviderResponder` from `lex-llm`. The responder owns provider invocation for this gem; routing and fleet request publication remain outside this provider extension.
