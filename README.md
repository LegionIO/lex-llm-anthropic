# lex-llm-anthropic

LegionIO LLM provider extension for **Anthropic Claude** models.

This gem provides the `:anthropic` provider family for LegionIO's LLM routing layer, connecting to the [Anthropic Messages API](https://docs.anthropic.com/en/docs/api/messages). It handles chat completions, streaming, tool use, extended thinking, model discovery, and fleet request consumption.

**Namespace:** `Legion::Extensions::Llm::Anthropic`
**Provider family:** `:anthropic`
**Default model:** `claude-sonnet-4-6`
**Dependency:** `lex-llm >= 0.4.3` (shared provider contracts, response normalization, fleet responders)

```ruby
require 'legion/extensions/llm/anthropic'
```

---

## File Index

| File | Role |
|------|------|
| `anthropic.rb` | Entry point; namespace, `PROVIDER_FAMILY`, default settings, instance discovery |
| `anthropic/provider.rb` | `Provider` class — chat, stream, list_models, format/parse payloads |
| `anthropic/registry_event_builder.rb` | Builds registry event envelopes for model availability |
| `anthropic/registry_publisher.rb` | Publishes model events to `llm.registry` exchange (async, best-effort) |
| `anthropic/version.rb` | `VERSION` constant |
| `anthropic/actors/discovery_refresh.rb` | Periodic actor that refreshes Anthropic model list |
| `anthropic/actors/fleet_worker.rb` | Subscription actor for fleet request consumption |
| `anthropic/runners/fleet_worker.rb` | Runner entrypoint for fleet request execution |
| `anthropic/transport/exchanges/llm_registry.rb` | Topic exchange definition for `llm.registry` |
| `anthropic/transport/messages/registry_event.rb` | Transport message wrapper for registry events |

---

## Installation

```ruby
gem 'lex-llm-anthropic', '~> 0.2'
```

---

## Architecture

### Provider (`Provider`)

The `Provider` class extends the `lex-llm` base provider contract and implements:

| Method | Description |
|--------|-------------|
| `chat(**kwargs)` | Synchronous chat completion via `/v1/messages` |
| `stream_chat(**kwargs)` | Streaming chat via `/v1/messages?stream=true` |
| `list_models` | Fetches available models from `/v1/models` |
| `format_payload(**)` | Builds Anthropic Messages API request body |
| `parse_response(response)` | Normalizes API response to Legion envelope |
| `parse_stream(response)` | Parses SSE stream into chunk events |
| `build_chunk(event, state)` | Accumulates streaming state (content, tool calls, thinking) |

**Supported capabilities:** `:completion`, `:streaming`, `:vision`, `:tools`

**API endpoints:**
- Chat & streaming: `POST /v1/messages`
- Model discovery: `GET /v1/models`

**Authentication headers:** `x-api-key`, `anthropic-version`

### Instance Discovery (`discover_instances`)

The extension discovers and normalizes Anthropic credentials from four sources, in priority order:

1. **Environment** — `ANTHROPIC_API_KEY`
2. **Claude config** — `~/.claude/settings.json` under `anthropicApiKey`
3. **Extension settings** — `Legion::Settings` at `extensions.llm.anthropic`
4. **Identity broker** — `Legion::Identity::Broker.credential_for(:anthropic)`

Named instances are supported under `extensions.llm.anthropic.instances.<name>`. Generic keys (`api_key`, `endpoint`, `version`) are normalized to Anthropic-specific keys (`anthropic_api_key`, `anthropic_api_base`, `anthropic_version`). Duplicate credentials are deduplicated by fingerprint.

### Default Settings

```ruby
{
  default_model: 'claude-sonnet-4-6',
  endpoint: 'https://api.anthropic.com',
  api_version: '2023-10-16',
  default_max_tokens: 4096,
  tier: :frontier,
  transport: :http,
  credentials: { api_key: 'env://ANTHROPIC_API_KEY' },
  usage: { inference: true, embedding: false, image: false },
  limits: { concurrency: 4 },
  fleet: {
    enabled: false,
    respond_to_requests: false,
    capabilities: %i[chat stream_chat],
    lanes: [],
    concurrency: 4,
    queue_suffix: nil
  }
}
```

### Registry Events (Availability Publishing)

After model discovery, discovered models are published to the `llm.registry` topic exchange so other LegionIO nodes can discover Anthropic availability.

| Class | Role |
|-------|------|
| `RegistryEventBuilder` | Builds the event envelope with model offering, health, and metadata |
| `RegistryPublisher` | Schedules async publish; checks transport readiness before sending |
| `Transport::Messages::RegistryEvent` | Message wrapper targeting the `llm.registry` exchange |
| `Transport::Exchanges::LlmRegistry` | Topic exchange definition (`llm.registry`) |

Publishing is **best-effort** and requires transport to be loaded. Failures are logged at `debug` level and silently absorbed.

### Fleet Responder

Provider instances can consume Legion LLM fleet requests. The fleet actor only starts when at least one configured instance enables `respond_to_requests`.

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

| Component | Role |
|-----------|------|
| `Actor::FleetWorker` | Subscription actor; checks if any instance enables fleet responding |
| `Runners::FleetWorker` | Runner entrypoint; delegates to `lex-llm` `ProviderResponder` |

Fleet execution is delegated to `Legion::Extensions::Llm::Fleet::ProviderResponder` from `lex-llm`. Routing and fleet request publication are handled outside this extension.

### Model Discovery Refresh

A periodic actor (`Actor::DiscoveryRefresh`) refreshes the Anthropic model list every 30 minutes (configurable via `extensions.llm.anthropic.discovery_interval`). It calls `Legion::LLM::Discovery.refresh_discovered_models!(provider: :anthropic)`.

---

## Configuration

```ruby
Legion::Extensions::Llm.configure do |config|
  config.anthropic_api_key = ENV.fetch('ANTHROPIC_API_KEY')
  config.anthropic_version = '2023-10-16'
end
```

**Configurable options:**

| Setting | Key | Description |
|---------|-----|-------------|
| API key | `anthropic_api_key` / `ANTHROPIC_API_KEY` | Required; API authentication |
| API version | `anthropic_version` | Defaults to `2023-10-16` |
| Endpoint | `anthropic_api_base` | Override `https://api.anthropic.com` |
| Max tokens | `default_max_tokens` | Defaults to `4096` |
| Discovery interval | `discovery_interval` (seconds) | Defaults to `1800` |

---

## Usage Examples

### Chat (synchronous)

```ruby
provider = Legion::Extensions::Llm::Anthropic::Provider.new(api_key: 'sk-ant-...')
response = provider.chat(model: 'claude-sonnet-4-6', messages: [{ role: 'user', content: 'Hello' }])
```

### Chat (streaming)

```ruby
provider.stream_chat(model: 'claude-sonnet-4-6', messages: [{ role: 'user', content: 'Hello' }]) do |chunk|
  print chunk[:content] if chunk[:content]
end
```

### With tools

```ruby
response = provider.chat(
  model: 'claude-sonnet-4-6',
  messages: [{ role: 'user', content: 'What is the weather in SF?' }],
  tools: [{ name: 'get_weather', description: '...', input_schema: { ... } }]
)
```

### Extended thinking

```ruby
response = provider.chat(
  model: 'claude-sonnet-4-6',
  messages: [{ role: 'user', content: 'Solve this math problem...' }],
  thinking: { budget_tokens: 4096, enabled: true }
)
```

---

## Dependencies

| Gem | Minimum version | Role |
|-----|-----------------|------|
| `lex-llm` | `>= 0.4.3` | Base provider contract, response normalization, fleet responder, auto-registration |
| `legion-logging` | (via lex-llm) | Logging helper for diagnostics |
| `legion-settings` | (via lex-llm) | Configuration access |
| `legion-transport` | (via lex-llm) | Message exchange for registry events |

---

## Testing

```bash
bundle exec rspec    # 28 examples
bundle exec rubocop  # 0 offenses
```

---

## Design Notes

- **No embeddings** — Anthropic embeddings are intentionally not exposed.
- **No `:claude` alias** — `provider_aliases` returns `[]`; only `:anthropic` is registered.
- **Prompt caching** — When `cache_enabled?` is true, system content and tool definitions are marked as cache breakpoints; early conversation turns are cacheable, the final message is never cached.
- **Thinking budget** — Supports `Integer`, `Hash` (with `:budget_tokens` or legacy `:budget`), and objects responding to `#budget`. Defaults to `1024`.
- **Context windows** — Static `CONTEXT_WINDOWS` map covers known Claude model families; `fetch_model_detail` and `infer_context_window` provide fallback inference.
