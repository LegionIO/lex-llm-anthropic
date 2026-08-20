# frozen_string_literal: true

require 'legion/extensions/llm'
require 'legion/logging/helper'

module Legion
  module Extensions
    module Llm
      module Anthropic
        # Anthropic Messages API provider implementation for the Legion::Extensions::Llm contract.
        class Provider < Legion::Extensions::Llm::Provider
          include Legion::Logging::Helper

          class << self
            def slug = 'anthropic'
            def configuration_options = %i[anthropic_api_key anthropic_api_base anthropic_version]
            def configuration_requirements = %i[anthropic_api_key]
            def capabilities = Capabilities
          end

          # Capability predicates for Anthropic chat model offerings.
          module Capabilities
            module_function

            def chat?(_model) = true
            def streaming?(_model) = true
            def vision?(_model) = true
            def functions?(_model) = true
            def embeddings?(_model) = false
          end

          def settings
            Anthropic.default_settings
          end

          def api_base
            config.anthropic_api_base || settings[:endpoint] || 'https://api.anthropic.com'
          end

          def headers
            identity_headers.merge({
              'x-api-key'         => config.anthropic_api_key,
              'anthropic-version' => config.anthropic_version || settings.dig(:instances, :default, :api_version)
            }.compact)
          end

          def completion_url = '/v1/messages'
          def stream_url = completion_url
          def models_url = '/v1/models'

          def translator
            @translator ||= Translator.new(config)
          end

          def embed(**_provider_options)
            raise NotImplementedError, 'Anthropic does not expose embeddings through this provider'
          end

          def list_models(**)
            log.debug { 'listing available Anthropic models' }
            super.tap do |models|
              log.debug { "discovered #{Array(models).size} Anthropic model(s)" }
            end
          end

          CONTEXT_WINDOWS = {
            'claude-opus-4'   => 200_000,
            'claude-sonnet-4' => 200_000,
            'claude-haiku-4'  => 200_000,
            'claude-3-5'      => 200_000,
            'claude-3-opus'   => 200_000,
            'claude-3-sonnet' => 200_000,
            'claude-3-haiku'  => 200_000
          }.freeze

          COMPLETION_BASE = [:completion].freeze

          private

          # The 0.8.0 render boundary (08 R1): messages arrive as
          # Canonical::Message (the base funnel enforces centrally — 08 F2),
          # params arrive as Canonical::Params (temperature lives only there —
          # 05 O4), thinking as Canonical::Thinking::Config. This method renders
          # the Anthropic wire payload FROM those canonical values.
          def render_payload(messages, tools:, model:, stream:, schema:, thinking:, params:, tool_prefs:)
            log_render_payload(messages:, tools:, model:, stream:, schema:)
            system_messages, chat_messages = messages.partition { |message| message.role == :system }

            caching = cache_enabled?
            exclude_count = caching ? [cache_control_prefix_tokens, 1].max : 0
            cacheable_count = caching ? [chat_messages.size - exclude_count, 0].max : 0

            {
              model:         model.id,
              messages:      format_messages(chat_messages, cacheable_count:),
              stream:        stream,
              max_tokens:    model.max_tokens || default_max_tokens,
              system:        system_content(system_messages, cache: caching),
              thinking:      thinking_payload(thinking),
              temperature:   params&.temperature,
              tools:         format_tools(tools, cache: caching),
              tool_choice:   tool_choice(tool_prefs),
              output_config: output_config(schema)
            }.compact
          end

          # The Messages API requires max_tokens on every request. /v1/models
          # metadata does not carry it, so models discovered live fall back to
          # the registered instance default (nested under instances.default,
          # mirroring the Translator read — the top-level key does not exist).
          def default_max_tokens
            settings.dig(:instances, :default, :default_max_tokens)
          end

          def log_render_payload(messages:, tools:, model:, stream:, schema:)
            log.debug do
              "rendering Anthropic #{stream ? 'stream' : 'chat'} payload for #{model.id} " \
                "with #{messages.size} message(s), #{tools.size} tool(s), schema=#{!schema.nil?}"
            end
          end

          def system_content(messages, cache: false)
            content = messages.flat_map do |message|
              content_blocks(message.content, cache:)
            end
            content.empty? ? nil : content
          end

          def format_messages(messages, cacheable_count: 0)
            messages.each_with_index.map do |message, index|
              cache = index < cacheable_count
              if message_tool_call?(message)
                format_tool_call_message(message, cache:)
              elsif message_tool_result?(message)
                format_tool_result_message(message, cache:)
              else
                {
                  role:    anthropic_role(message.role),
                  content: content_blocks(message.content, cache:)
                }
              end
            end
          end

          def anthropic_role(role)
            role == :assistant ? 'assistant' : 'user'
          end

          # Canonical content only (R4): String | ContentBlock |
          # Array<ContentBlock> | nil. Thinking is a content block on the
          # canonical message — it maps through the same path, with the
          # signature (provider dialect) read from the block metadata.
          def content_blocks(content, cache: false)
            case content
            when nil then []
            when String
              return [] if content.empty?

              [text_block(content, cache:)]
            when Legion::Extensions::Llm::Canonical::ContentBlock
              wire = content_block_to_wire(content, cache:)
              wire ? [wire] : []
            when Array
              content.filter_map { |block| content_block_to_wire(block, cache:) }
            end
          end

          # One canonical block to one Anthropic wire block; nil when the block
          # renders nothing (an empty text block would 400 on the API).
          def content_block_to_wire(block, cache: false)
            case block.type
            when :text
              return nil if block.text.to_s.empty?

              text_block(block.text, cache:)
            when :thinking
              thinking_block(block)
            when :image
              {
                type:   'image',
                source: {
                  type:       block.source_type || 'base64',
                  media_type: block.media_type,
                  data:       block.data
                }
              }
            else
              raise ArgumentError,
                    "anthropic provider cannot render content block type #{block.type.inspect} — " \
                    'only text, thinking, and image blocks cross this wire'
            end
          end

          def text_block(text, cache: false)
            { type: 'text', text: text }.tap do |block|
              block[:cache_control] = { type: 'ephemeral' } if cache
            end
          end

          def thinking_block(block)
            wire = { type: 'thinking', thinking: block.text.to_s }
            signature = block.metadata&.dig(:signature)
            wire[:signature] = signature if signature
            wire
          end

          def message_tool_call?(message)
            !message.tool_calls.nil? && !message.tool_calls.empty?
          end

          def message_tool_result?(message)
            !message.tool_call_id.nil? && !message.tool_call_id.to_s.empty?
          end

          def format_tool_call_message(message, cache:)
            blocks = content_blocks(message.content, cache:)
            # Canonical::Message#tool_calls is Array<Canonical::ToolCall> —
            # the name-keyed Hash shape is gone (04 L2).
            Array(message.tool_calls).each { |tool_call| blocks << tool_use_block(tool_call, cache:) }
            { role: 'assistant', content: blocks }
          end

          def tool_use_block(tool_call, cache: false)
            {
              type:          'tool_use',
              id:            tool_call.id,
              name:          tool_call.name,
              input:         tool_call.arguments,
              cache_control: { type: 'ephemeral' }
            }.tap do |block|
              block.delete(:cache_control) unless cache
            end
          end

          def format_tool_result_message(message, cache: false)
            {
              role:    'user',
              content: [
                {
                  type:          'tool_result',
                  tool_use_id:   message.tool_call_id,
                  content:       content_blocks(message.content, cache:),
                  cache_control: { type: 'ephemeral' }
                }.tap { |block| block.delete(:cache_control) unless cache }
              ]
            }
          end

          # Canonical::Thinking::Config at the render boundary: enabled? is the
          # law (04 §8), resolved_budget is the single effort<->budget source —
          # no fabricated default.
          def thinking_payload(thinking)
            return nil unless thinking&.enabled?

            { type: 'enabled', budget_tokens: thinking.resolved_budget }
          end

          def format_tools(tools, cache: false)
            return nil if tools.empty?

            tool_array = tools.values.map do |tool|
              # Tools can be ToolDefinition objects or plain Hashes from native_dispatch.
              tool_name = tool.respond_to?(:name) ? tool.name : (tool[:name] || tool['name'])
              tool_desc = tool.respond_to?(:description) ? tool.description : (tool[:description] || tool['description'] || '')
              {
                name:         tool_name,
                description:  tool_desc,
                input_schema: tool_schema(tool)
              }
            end

            tool_array.last[:cache_control] = { type: 'ephemeral' } if cache && tool_array.any?

            tool_array
          end

          def tool_schema(tool)
            return tool.params_schema if tool.respond_to?(:params_schema) && tool.params_schema

            raw = tool.respond_to?(:parameters) ? tool.parameters : (tool[:parameters] || tool['parameters'])
            Legion::Extensions::Llm::Canonical::ToolDefinition.normalize_parameters(raw)
          end

          def tool_choice(tool_prefs)
            return nil unless tool_prefs

            choice = tool_preference(tool_prefs, :choice) || :auto
            type = tool_choice_type(choice)

            { type: type }.tap do |payload|
              payload[:name] = choice.to_s if type == 'tool'
              payload[:disable_parallel_tool_use] = true if tool_preference(tool_prefs, :calls) == :one
            end
          end

          def tool_preference(tool_prefs, key)
            tool_prefs[key] || tool_prefs[key.to_s]
          end

          def tool_choice_type(choice)
            case choice
            when :auto, 'auto', :none, 'none'
              choice.to_s
            when :required, 'required'
              'any'
            else
              'tool'
            end
          end

          def output_config(schema)
            return nil unless schema

            normalized = schema.respond_to?(:to_h) ? schema.to_h : schema
            normalized = normalized[:schema] || normalized['schema'] || normalized
            normalized = normalized.dup
            normalized.delete(:strict)
            normalized.delete('strict')
            { format: { type: 'json', schema: normalized } }
          end

          # 0.8.0 parse boundary (08 R2): the sync parse returns the
          # Canonical::Response the translator produced — no re-canonicalizing
          # bridge, no legacy shape.
          def parse_completion_response(response)
            translator.parse_response(response.body)
          end

          # The streaming parse yields Canonical::Chunk objects (05 O5); the
          # base Streaming module accumulates them and terminates the sequence
          # with exactly one done (or error) chunk.
          def build_chunk(data)
            translator.parse_chunk(data)
          end

          def parse_list_models_response(response, provider, _capabilities)
            Array(response.body['data']).map do |model|
              model_id = model.fetch('id')
              detail = model_detail(model_id)
              ctx = detail&.dig(:context_window) || infer_context_window(model_id)
              resolved = resolve_model_capabilities(model_id)
              Legion::Extensions::Llm::Model::Info.new(
                id:             model_id,
                name:           model['display_name'] || model_id,
                provider:       provider,
                capabilities:   COMPLETION_BASE + resolved[:capabilities],
                context_length: ctx,
                metadata:       model.merge('created_at' => model['created_at']).compact
              )
            end
          end

          def resolve_model_capabilities(model_id)
            Legion::Extensions::Llm::CapabilityPolicy.resolve(
              real:              {},
              provider_catalog:  catalog_capabilities(model_id),
              probe:             {},
              provider_envelope: { streaming: true, tools: true },
              provider_config:   provider_capability_config,
              instance_config:   instance_capability_config,
              model_config:      model_capability_config(model_id)
            )
          end

          # Boolean capability hash for a model, read from the shared lex-llm
          # catalog (models.dev-sourced). This is where Claude extended-thinking
          # support (`reasoning` -> `:thinking`) is surfaced during discovery, so
          # thinking-capable Claude models advertise `:thinking` and the router's
          # thinking filter can route them. Unknown models return `{}`, falling
          # back to the provider envelope. The catalog is the single source of
          # truth for per-model capabilities across every provider.
          def catalog_capabilities(model_id)
            model = Legion::Extensions::Llm::Models.find(model_id, :anthropic)
            Array(model&.capabilities).each_with_object({}) do |capability, result|
              canonical = Legion::Extensions::Llm::Capabilities.canonical(capability)
              next unless Legion::Extensions::Llm::CapabilityPolicy::OPTIONAL_CAPABILITIES.include?(canonical)

              result[canonical] = true
            end
          rescue Legion::Extensions::Llm::ModelNotFoundError
            {}
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true,
                                operation: "#{slug}.catalog_capabilities", model: model_id)
            {}
          end

          def infer_context_window(model_id)
            CONTEXT_WINDOWS.find { |prefix, _| model_id.start_with?(prefix) }&.last
          end

          def fetch_model_detail(model_name)
            ctx = infer_context_window(model_name)
            ctx ? { context_window: ctx } : nil
          end
        end
      end
    end
  end
end
