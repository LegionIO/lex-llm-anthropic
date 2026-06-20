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
            attr_writer :registry_publisher

            def slug = 'anthropic'
            def configuration_options = %i[anthropic_api_key anthropic_api_base anthropic_version]
            def configuration_requirements = %i[anthropic_api_key]
            def capabilities = Capabilities

            def registry_publisher
              @registry_publisher ||= Legion::Extensions::Llm::RegistryPublisher.new(provider_family: :anthropic)
            end
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
              'anthropic-version' => config.anthropic_version || settings[:api_version] || '2023-06-01'
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

          def discover_offerings(live: false, raise_on_unreachable: false, **filters)
            return filter_cached_offerings(Array(@cached_offerings), filters) unless live

            provider_health = health(live:)
            readiness = discovery_registry_readiness(provider_health, live:)
            @cached_offerings = Array(list_models(live:, **filters)).filter_map do |model|
              self.class.registry_publisher.publish_models_async([model], readiness:)
              next unless model_matches_filters?(model, filters)
              next unless model_allowed?(model.id)

              log.debug("[#{slug}] instance=#{provider_instance_id} action=model_discovered model=#{model.id} family=#{model.family}")
              offering_from_model(model, health: provider_health)
            end
            log.info("[#{slug}] instance=#{provider_instance_id} action=discover_complete model_count=#{Array(@cached_offerings).size}")
            @cached_offerings
          rescue Faraday::ConnectionFailed, Faraday::TimeoutError => e
            log.warn("[#{slug}] instance=#{provider_instance_id} unreachable: #{e.message}")
            raise if raise_on_unreachable

            []
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

          def discovery_registry_readiness(provider_health, live:)
            {
              provider:   slug.to_sym,
              configured: configured?,
              ready:      provider_health[:ready] == true,
              live:       live,
              health:     provider_health
            }
          end

          def render_payload(messages, tools:, temperature:, model:, stream:, schema:, thinking:, tool_prefs:)
            log_render_payload(messages:, tools:, model:, stream:, schema:)
            system_messages, chat_messages = messages.partition { |message| message.role == :system }

            caching = cache_enabled?
            exclude_count = caching ? [cache_control_prefix_tokens, 1].max : 0
            cacheable_count = caching ? [chat_messages.size - exclude_count, 0].max : 0

            {
              model:         model.id,
              messages:      format_messages(chat_messages, thinking: thinking_enabled?(thinking), cacheable_count:),
              stream:        stream,
              max_tokens:    model.max_tokens || settings[:default_max_tokens] || 4096,
              system:        system_content(system_messages, cache: caching),
              thinking:      thinking_payload(thinking),
              temperature:   temperature,
              tools:         format_tools(tools, cache: caching),
              tool_choice:   tool_choice(tool_prefs),
              output_config: output_config(schema)
            }.compact
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

          def format_messages(messages, thinking:, cacheable_count: 0)
            messages.each_with_index.map do |message, index|
              cache = index < cacheable_count
              if message.tool_call?
                format_tool_call_message(message, thinking:, cache:)
              elsif message.tool_result?
                format_tool_result_message(message, cache:)
              else
                {
                  role:    anthropic_role(message.role),
                  content: content_blocks(message.content, thinking:, message:, cache:)
                }
              end
            end
          end

          def anthropic_role(role)
            role == :assistant ? 'assistant' : 'user'
          end

          def content_blocks(content, thinking: false, message: nil, cache: false)
            raw_blocks = raw_content(content)
            return with_thinking(raw_blocks, message, thinking) if raw_blocks

            blocks = []
            blocks << text_block(content_text(content), cache:) unless content_text(content).to_s.empty?
            blocks.concat(attachment_blocks(content)) if content.respond_to?(:attachments)
            with_thinking(blocks, message, thinking)
          end

          def raw_content(content)
            return nil unless content.is_a?(Legion::Extensions::Llm::Content::Raw)

            Array(content.format)
          end

          def content_text(content)
            return content.text if content.respond_to?(:text)

            content.to_s
          end

          def text_block(text, cache: false)
            { type: 'text', text: text }.tap do |block|
              block[:cache_control] = { type: 'ephemeral' } if cache
            end
          end

          def attachment_blocks(content)
            content.attachments.filter_map do |attachment|
              next unless attachment.image?

              {
                type:   'image',
                source: {
                  type:       'base64',
                  media_type: attachment.mime_type,
                  data:       attachment.encoded
                }
              }
            end
          end

          def with_thinking(blocks, message, enabled)
            return blocks unless enabled && message&.role == :assistant

            thinking_block = thinking_block(message.thinking)
            thinking_block ? [thinking_block, *blocks] : blocks
          end

          def format_tool_call_message(message, thinking:, cache:)
            blocks = content_blocks(message.content, thinking:, message:, cache:)
            # tool_calls is an Array of ToolCall since the adapter stopped
            # name-keying them (name-keyed hashes silently dropped parallel
            # same-name calls); tolerate the legacy Hash shape from old callers.
            calls = message.tool_calls.is_a?(Hash) ? message.tool_calls.values : Array(message.tool_calls)
            calls.each { |tool_call| blocks << tool_use_block(tool_call, cache:) }
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

          def thinking_payload(thinking)
            return nil unless thinking_enabled?(thinking)

            { type: 'enabled', budget_tokens: thinking_budget(thinking) }
          end

          def thinking_enabled?(thinking)
            return false if thinking.nil?
            return thinking.enabled? if thinking.respond_to?(:enabled?)

            !!thinking
          end

          def thinking_budget(thinking)
            return thinking if thinking.is_a?(Integer)
            return extract_hash_budget(thinking) if thinking.is_a?(Hash)
            return thinking.budget if thinking.respond_to?(:budget) && thinking.budget

            1024
          end

          # Anthropic API uses :budget_tokens, but legacy config may use :budget
          def extract_hash_budget(thinking)
            thinking[:budget_tokens] || thinking['budget_tokens'] || thinking[:budget] || thinking['budget']
          end

          def thinking_block(thinking)
            return nil unless thinking

            if thinking.text
              { type: 'thinking', thinking: thinking.text, signature: thinking.signature }.compact
            elsif thinking.signature
              { type: 'redacted_thinking', data: thinking.signature }
            end
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

          def parse_completion_response(response)
            body = response.body
            canonical = translator.parse_response(body)
            to_legacy_message(canonical, body)
          end

          def build_chunk(data)
            canonical_chunk = translator.parse_chunk(data)
            return nil if canonical_chunk.nil?

            to_legacy_chunk(canonical_chunk, data)
          end

          def to_legacy_message(canonical, raw_body)
            usage = canonical.usage
            Legion::Extensions::Llm::Message.new(
              role:                  :assistant,
              content:               canonical.text,
              model_id:              canonical.model,
              thinking:              if canonical.thinking
                                       Legion::Extensions::Llm::Thinking.build(
                                         text:      canonical.thinking.content,
                                         signature: canonical.thinking.signature
                                       )
                                     end,
              tool_calls:            legacy_tool_calls(canonical.tool_calls),
              input_tokens:          usage&.input_tokens,
              output_tokens:         usage&.output_tokens,
              cached_tokens:         usage&.cache_read_tokens,
              cache_creation_tokens: usage&.cache_write_tokens,
              thinking_tokens:       usage&.thinking_tokens,
              raw:                   raw_body
            )
          end

          def to_legacy_chunk(canonical_chunk, raw_data)
            Legion::Extensions::Llm::Chunk.new(
              role:          :assistant,
              content:       canonical_chunk.text_delta? ? canonical_chunk.delta : nil,
              model_id:      raw_data.dig('message', 'model'),
              thinking:      if canonical_chunk.thinking_delta?
                               Legion::Extensions::Llm::Thinking.build(
                                 text:      canonical_chunk.delta,
                                 signature: canonical_chunk.signature
                               )
                             end,
              input_tokens:  canonical_chunk.usage&.input_tokens,
              output_tokens: canonical_chunk.usage&.output_tokens,
              tool_calls:    legacy_streaming_tool_calls(canonical_chunk)
            )
          end

          def legacy_tool_calls(canonical_tool_calls)
            return nil if canonical_tool_calls.nil? || canonical_tool_calls.empty?

            canonical_tool_calls.to_h do |tc|
              [
                tc.id,
                Legion::Extensions::Llm::ToolCall.new(
                  id: tc.id, name: tc.name, arguments: tc.arguments || {}
                )
              ]
            end
          end

          def legacy_streaming_tool_calls(canonical_chunk)
            return nil unless canonical_chunk.tool_call_delta?

            tc = canonical_chunk.tool_call
            return nil unless tc

            { tc.id => Legion::Extensions::Llm::ToolCall.new(
              id: tc.id, name: tc.name, arguments: tc.arguments || ''
            ) }
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
              provider_catalog:  {},
              probe:             {},
              provider_envelope: { streaming: true, tools: true },
              provider_config:   provider_capability_config,
              instance_config:   instance_capability_config,
              model_config:      model_capability_config(model_id)
            )
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
