# frozen_string_literal: true

require 'legion/extensions/llm'
require 'legion/logging/helper'
require 'legion/extensions/llm/anthropic/prompt_caching'

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

          CONTEXT_WINDOWS = {
            'claude-opus-4'   => 200_000,
            'claude-sonnet-4' => 200_000,
            'claude-haiku-4'  => 200_000,
            'claude-3-5'      => 200_000,
            'claude-3-opus'   => 200_000,
            'claude-3-sonnet' => 200_000,
            'claude-3-haiku'  => 200_000
          }.freeze

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

            payload = {
              model:         model.to_s,
              messages:      format_messages(chat_messages),
              stream:        stream,
              max_tokens:    default_max_tokens,
              system:        system_content(system_messages),
              thinking:      thinking_payload(thinking),
              temperature:   params&.temperature,
              tools:         format_tools(tools),
              tool_choice:   tool_choice(tool_prefs),
              output_config: output_config(schema)
            }.compact
            Legion::Extensions::Llm::Anthropic::PromptCaching.apply(
              payload: payload, cache_tools: caching, cache_system: caching, message_prefix_count: cacheable_count
            )
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
              "rendering Anthropic #{stream ? 'stream' : 'chat'} payload for #{model} " \
                "with #{messages.size} message(s), #{tools.size} tool(s), schema=#{!schema.nil?}"
            end
          end

          def system_content(messages)
            content = messages.flat_map do |message|
              Legion::Extensions::Llm::Anthropic::PromptCaching.project_message_control(
                blocks: content_blocks(message.content), control: message.cache_control
              )
            end
            content.empty? ? nil : content
          end

          def format_messages(messages)
            messages.map do |message|
              wire = if message_tool_call?(message)
                       format_tool_call_message(message)
                     elsif message_tool_result?(message)
                       format_tool_result_message(message)
                     else
                       { role: anthropic_role(message.role), content: content_blocks(message.content) }
                     end
              Legion::Extensions::Llm::Anthropic::PromptCaching.project_message_control(
                blocks: wire[:content], control: message.cache_control
              )
              wire
            end
          end

          def anthropic_role(role)
            role == :assistant ? 'assistant' : 'user'
          end

          # Canonical content only (R4): String | ContentBlock |
          # Array<ContentBlock> | nil. Thinking is a content block on the
          # canonical message — it maps through the same path, with the
          # signature (provider dialect) read from the block metadata.
          def content_blocks(content)
            case content
            when nil then []
            when String
              return [] if content.empty?

              [text_block(content)]
            when Legion::Extensions::Llm::Canonical::ContentBlock
              wire = content_block_to_wire(content)
              wire ? [wire] : []
            when Array
              content.filter_map { |block| content_block_to_wire(block) }
            end
          end

          # One canonical block to one Anthropic wire block; nil when the block
          # renders nothing (an empty text block would 400 on the API).
          def content_block_to_wire(block)
            wire = case block.type
                   when :text
                     return nil if block.text.to_s.empty?

                     text_block(block.text)
                   when :thinking
                     thinking_block(block)
                   when :image
                     translator.render_image_block(block:)
                   else
                     raise ArgumentError,
                           "anthropic provider cannot render content block type #{block.type.inspect} — " \
                           'only text, thinking, and image blocks cross this wire'
                   end
            wire[:cache_control] = block.cache_control if block.cache_control
            wire
          end

          def text_block(text)
            { type: 'text', text: text }
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

          def format_tool_call_message(message)
            blocks = content_blocks(message.content)
            # Canonical::Message#tool_calls is Array<Canonical::ToolCall> —
            # the name-keyed Hash shape is gone (04 L2).
            Array(message.tool_calls).each { |tool_call| blocks << tool_use_block(tool_call) }
            { role: 'assistant', content: blocks }
          end

          def tool_use_block(tool_call)
            {
              type:  'tool_use',
              id:    tool_call.id,
              name:  tool_call.name,
              input: tool_call.arguments
            }
          end

          def format_tool_result_message(message)
            {
              role:    'user',
              content: [
                {
                  type:        'tool_result',
                  tool_use_id: message.tool_call_id,
                  content:     content_blocks(message.content)
                }
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

          def format_tools(tools)
            return nil if tools.empty?

            tools.values.map { |tool| translator.render_tool(tool: tool) }
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
