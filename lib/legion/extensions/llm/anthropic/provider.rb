# frozen_string_literal: true

require 'legion/extensions/llm'

module Legion
  module Extensions
    module Llm
      module Anthropic
        # Anthropic Messages API provider implementation for the Legion::Extensions::Llm contract.
        class Provider < Legion::Extensions::Llm::Provider # rubocop:disable Metrics/ClassLength
          class << self
            attr_writer :registry_publisher

            def slug = 'anthropic'
            def configuration_options = %i[anthropic_api_key anthropic_api_base anthropic_version]
            def configuration_requirements = %i[anthropic_api_key]
            def capabilities = Capabilities

            def registry_publisher
              @registry_publisher ||= RegistryPublisher.new
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

          def api_base
            config.anthropic_api_base || 'https://api.anthropic.com'
          end

          def headers
            {
              'x-api-key' => config.anthropic_api_key,
              'anthropic-version' => config.anthropic_version || '2023-06-01'
            }.compact
          end

          def completion_url = '/v1/messages'
          def stream_url = completion_url
          def models_url = '/v1/models'

          def embed(_text, model:, dimensions:)
            raise NotImplementedError, 'Anthropic does not expose embeddings through this provider'
          end

          def list_models
            super.tap do |models|
              self.class.registry_publisher.publish_models_async(models, readiness: readiness(live: false))
            end
          end

          private

          def render_payload(messages, tools:, temperature:, model:, stream:, schema:, thinking:, tool_prefs:) # rubocop:disable Metrics/ParameterLists
            system_messages, chat_messages = messages.partition { |message| message.role == :system }

            {
              model: model.id,
              messages: format_messages(chat_messages, thinking: thinking_enabled?(thinking)),
              stream: stream,
              max_tokens: model.max_tokens || 4096,
              system: system_content(system_messages),
              thinking: thinking_payload(thinking),
              temperature: temperature,
              tools: format_tools(tools),
              tool_choice: tool_choice(tool_prefs),
              output_config: output_config(schema)
            }.compact
          end

          def system_content(messages)
            content = messages.flat_map { |message| content_blocks(message.content) }
            content.empty? ? nil : content
          end

          def format_messages(messages, thinking:)
            messages.map do |message|
              if message.tool_call?
                format_tool_call_message(message, thinking: thinking)
              elsif message.tool_result?
                format_tool_result_message(message)
              else
                {
                  role: anthropic_role(message.role),
                  content: content_blocks(message.content, thinking: thinking, message: message)
                }
              end
            end
          end

          def anthropic_role(role)
            role == :assistant ? 'assistant' : 'user'
          end

          def content_blocks(content, thinking: false, message: nil)
            raw_blocks = raw_content(content)
            return with_thinking(raw_blocks, message, thinking) if raw_blocks

            blocks = []
            blocks << text_block(content_text(content)) unless content_text(content).to_s.empty?
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

          def text_block(text)
            { type: 'text', text: text }
          end

          def attachment_blocks(content)
            content.attachments.filter_map do |attachment|
              next unless attachment.image?

              {
                type: 'image',
                source: {
                  type: 'base64',
                  media_type: attachment.mime_type,
                  data: attachment.encoded
                }
              }
            end
          end

          def with_thinking(blocks, message, enabled)
            return blocks unless enabled && message&.role == :assistant

            thinking_block = thinking_block(message.thinking)
            thinking_block ? [thinking_block, *blocks] : blocks
          end

          def format_tool_call_message(message, thinking:)
            blocks = content_blocks(message.content, thinking: thinking, message: message)
            message.tool_calls.each_value { |tool_call| blocks << tool_use_block(tool_call) }
            { role: 'assistant', content: blocks }
          end

          def tool_use_block(tool_call)
            {
              type: 'tool_use',
              id: tool_call.id,
              name: tool_call.name,
              input: tool_call.arguments
            }
          end

          def format_tool_result_message(message)
            {
              role: 'user',
              content: [
                {
                  type: 'tool_result',
                  tool_use_id: message.tool_call_id,
                  content: content_blocks(message.content)
                }
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
            return thinking[:budget] || thinking['budget'] if thinking.is_a?(Hash)
            return thinking.budget if thinking.respond_to?(:budget) && thinking.budget

            1024
          end

          def thinking_block(thinking)
            return nil unless thinking

            if thinking.text
              { type: 'thinking', thinking: thinking.text, signature: thinking.signature }.compact
            elsif thinking.signature
              { type: 'redacted_thinking', data: thinking.signature }
            end
          end

          def format_tools(tools)
            return nil if tools.empty?

            tools.values.map do |tool|
              {
                name: tool.name,
                description: tool.description,
                input_schema: tool_schema(tool)
              }
            end
          end

          def tool_schema(tool)
            return tool.params_schema if tool.respond_to?(:params_schema) && tool.params_schema

            { type: 'object', properties: {}, required: [] }
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
            { format: { type: 'json_schema', schema: normalized } }
          end

          def parse_completion_response(response)
            body = response.body
            content_blocks = body['content'] || []
            usage = body['usage'] || {}

            Legion::Extensions::Llm::Message.new(
              role: :assistant,
              content: text_from(content_blocks),
              model_id: body['model'],
              thinking: thinking_from(content_blocks),
              tool_calls: parse_tool_calls(content_blocks),
              input_tokens: usage['input_tokens'],
              output_tokens: usage['output_tokens'],
              cached_tokens: usage['cache_read_input_tokens'],
              cache_creation_tokens: cache_creation_tokens(usage),
              thinking_tokens: thinking_tokens(usage),
              raw: body
            )
          end

          def text_from(blocks)
            blocks.select { |block| block['type'] == 'text' }.map { |block| block['text'] }.join
          end

          def thinking_from(blocks)
            thinking_block = blocks.find { |block| block['type'] == 'thinking' }
            redacted_block = blocks.find { |block| block['type'] == 'redacted_thinking' }

            Legion::Extensions::Llm::Thinking.build(
              text: thinking_block&.dig('thinking') || thinking_block&.dig('text'),
              signature: thinking_block&.dig('signature') || redacted_block&.dig('data')
            )
          end

          def cache_creation_tokens(usage)
            cache_creation = usage['cache_creation']
            cache_creation_values = cache_creation.values if cache_creation

            usage['cache_creation_input_tokens'] || cache_creation_values&.compact&.sum
          end

          def thinking_tokens(usage)
            usage.dig('output_tokens_details', 'thinking_tokens') ||
              usage.dig('output_tokens_details', 'reasoning_tokens') ||
              usage['thinking_tokens'] ||
              usage['reasoning_tokens']
          end

          def build_chunk(data)
            delta_type = data.dig('delta', 'type')

            Legion::Extensions::Llm::Chunk.new(
              role: :assistant,
              content: delta_type == 'text_delta' ? data.dig('delta', 'text') : nil,
              model_id: data.dig('message', 'model'),
              thinking: Legion::Extensions::Llm::Thinking.build(
                text: delta_type == 'thinking_delta' ? data.dig('delta', 'thinking') : nil,
                signature: delta_type == 'signature_delta' ? data.dig('delta', 'signature') : nil
              ),
              input_tokens: data.dig('message', 'usage', 'input_tokens'),
              output_tokens: data.dig('message', 'usage', 'output_tokens') || data.dig('usage', 'output_tokens'),
              tool_calls: parse_tool_calls(data['content_block'])
            )
          end

          def parse_tool_calls(content_blocks)
            blocks = Array(content_blocks).select { |block| block && block['type'] == 'tool_use' }
            return nil if blocks.empty?

            blocks.to_h do |block|
              [
                block['id'],
                Legion::Extensions::Llm::ToolCall.new(
                  id: block['id'],
                  name: block['name'],
                  arguments: block['input'] || {}
                )
              ]
            end
          end

          def parse_list_models_response(response, provider, _capabilities)
            Array(response.body['data']).map do |model|
              model_id = model.fetch('id')
              Legion::Extensions::Llm::Model::Info.new(
                id: model_id,
                name: model['display_name'] || model_id,
                provider: provider,
                metadata: model.merge('created_at' => model['created_at']).compact
              )
            end
          end
        end
      end
    end
  end
end
