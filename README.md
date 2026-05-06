# lex-llm-anthropic

LegionIO LLM provider extension for Anthropic.

This gem lives under `Legion::Extensions::Llm::Anthropic` and depends on `lex-llm >= 0.4.0` for shared provider-neutral routing, response normalization, fleet envelopes, and schema primitives.

Load it with `require 'legion/extensions/llm/anthropic'`.

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
