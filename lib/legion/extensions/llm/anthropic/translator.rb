# frozen_string_literal: true

require 'legion/logging/helper'
require 'legion/extensions/llm/canonical'

module Legion
  module Extensions
    module Llm
      module Anthropic
        # Canonical provider translator for Anthropic Messages API.
        # Implements the provider-boundary contract: canonical to Anthropic wire format.
        # Extracted from Provider render_format/parse methods - behaviour preserved, not rewritten.
        class Translator
          include Legion::Logging::Helper

          # Anthropic-specific capabilities per the Phase 3 design.
          CAPABILITIES = {
            provider:              'anthropic',
            # Thinking lifecycle: open thinking -> delta -> signature_delta -> close.
            # Signature required alongside thinking content on Anthropic.
            thinking:              :signature_lifecycle,
            # Anthropic supports assistant prefill (sending partial assistant message
            # to bias completion direction) - used in mid-stream failover (G6).
            assistant_prefill:     true,
            # Streaming support.
            streaming:             true,
            # Tool calls are first-class (tool_use content blocks).
            tool_calls:            :native,
            # System prompt as array of content blocks.
            system_content_blocks: true,
            # Supported params (G18). Unsupported params dropped with debug log.
            supported_params:      %i[
              max_tokens temperature stop_sequences seed response_format
            ].freeze
          }.freeze

          def capabilities = CAPABILITIES
          def config = @config || {}
          def initialize(config = {}) = @config = config

          # Render: Canonical::Request to Anthropic wire Hash.
          def render_request(canonical_request)
            msgs = canonical_request.messages || []
            system_messages, chat_messages = msgs.partition { |msg| msg.role == :system }

            system_parts = if canonical_request.system
                             render_system_string(canonical_request.system)
                           else
                             render_system_content(system_messages)
                           end
            message_parts = render_messages(chat_messages, thinking: thinking_enabled?(canonical_request))
            tools = render_tools(canonical_request.tools)
            tool_choice = render_tool_choice(canonical_request.tool_choice)
            model_id = canonical_request.metadata&.dig(:model) || 'claude-sonnet-4'

            base = {
              model:       model_id,
              messages:    message_parts,
              stream:      canonical_request.stream,
              system:      system_parts,
              temperature: canonical_request.params&.temperature
            }.compact

            params = canonical_request.params
            if params
              base[:max_tokens] = params.max_tokens
              base[:stop_sequences] = params.stop_sequences
              base[:seed] = params.seed
              drop_unsupported_params(params)
              base[:response_format] = render_response_format(params.response_format)
            end

            base[:thinking] = render_thinking_config(canonical_request) if thinking_enabled?(canonical_request)
            base[:tools] = tools if tools && !tools.empty?
            base[:tool_choice] = tool_choice if tool_choice
            base[:max_tokens] ||= canonical_request.metadata&.dig(:default_max_tokens) || settings_default_max_tokens

            base.compact
          end

          # Parse: Anthropic wire Hash to Canonical::Response. Accepts both Anthropic wire format
          # (content: array of blocks) and canonical form (text: string) for conformance kit compatibility.
          def parse_response(wire)
            # If the wire has canonical 'text' key, pass through using Canonical::Response factory.
            return Canonical::Response.from_hash(wire) if wire.key?(:text) || wire.key('text')

            content = Array(wire[:content] || wire['content'] || [])
            usage = wire[:usage] || wire['usage'] || {}
            raw_usage = parse_usage(usage)

            text = extract_text(content)
            thinking = extract_thinking(content)
            tool_calls = extract_tool_calls(content)
            stop_reason = map_stop_reason(wire[:stop_reason] || wire['stop_reason'])
            model = wire[:model] || wire['model']

            Canonical::Response.build(
              text:        text,
              thinking:    thinking,
              tool_calls:  tool_calls,
              usage:       raw_usage,
              stop_reason: stop_reason,
              model:       model,
              routing:     {},
              metadata:    wire.except(:content, :usage, :stop_reason, :model).compact
            )
          end

          # Parse chunk: raw streaming event to Canonical::Chunk.
          def parse_chunk(raw)
            return nil unless raw.is_a?(Hash) && (raw.key?(:type) || raw.key?('type'))

            type = raw[:type] || raw['type']

            case type
            when 'text_delta', :text_delta
              Canonical::Chunk.text_delta(
                delta:       extract_delta(raw, 'text_delta'),
                request_id:  raw[:request_id],
                block_index: raw[:block_index]
              )
            when 'thinking_delta', :thinking_delta
              delta_obj = raw[:delta] || raw['delta']
              sig_from_delta = (delta_obj[:signature] || delta_obj['signature'] if delta_obj.is_a?(Hash))

              Canonical::Chunk.thinking_delta(
                delta:       extract_delta(raw, 'thinking_delta'),
                request_id:  raw[:request_id],
                block_index: raw[:block_index],
                signature:   raw[:signature] || raw['signature'] || sig_from_delta
              )
            when 'tool_call_delta', :tool_call_delta
              tc = extract_tool_call_from_chunk(raw)
              return nil unless tc

              Canonical::Chunk.tool_call_delta(
                tool_call:   tc,
                request_id:  raw[:request_id],
                block_index: raw[:block_index]
              )
            when 'error', :error
              Canonical::Chunk.error_chunk(
                error:      raw[:error] || raw['error'] || 'unknown',
                request_id: raw[:request_id] || '',
                metadata:   raw[:metadata] || raw['metadata'] || {}
              )
            when 'done', :done
              usage = (Canonical::Usage.from_hash(raw[:usage] || raw['usage'] || {}) if raw[:usage] || raw['usage'])

              Canonical::Chunk.done(
                request_id:  raw[:request_id] || '',
                usage:       usage,
                stop_reason: map_stop_reason(raw[:stop_reason] || raw['stop_reason'])
              )
            else
              # Per G20d: ignore unknown chunk types on consume
              log.debug("[anthropic translator] ignoring unknown chunk type: #{type.inspect}")
              nil
            end
          rescue StandardError => e
            handle_exception(e, level: :debug, handled: true, operation: 'anthropic.translator.parse_chunk')
            Canonical::Chunk.error_chunk(
              error:      "#{e.class}: #{e.message}",
              request_id: raw[:request_id] || ''
            )
          end

          private

          # --- render_messages ---

          def render_messages(messages, thinking:)
            messages.map do |msg|
              case msg.role
              when :assistant
                render_assistant_message(msg, thinking:)
              when :tool
                render_tool_result_message(msg)
              else
                {
                  role:    msg.role.to_s,
                  content: render_content_blocks(msg.content)
                }
              end
            end
          end

          def render_assistant_message(msg, thinking:)
            blocks = render_content_blocks(msg.content)
            blocks.unshift({ type: 'text', text: '' }) if thinking && msg.text.to_s.empty? && !msg.tool_calls&.empty?

            Array(msg.tool_calls).each do |tc|
              args = tc.is_a?(Canonical::ToolCall) ? tc.arguments : (tc[:arguments] || tc['arguments'] || {})
              args = parse_json_or_hash(args)
              blocks << {
                type:  'tool_use',
                id:    tc.is_a?(Canonical::ToolCall) ? tc.id : (tc[:id] || tc['id']),
                name:  tc.is_a?(Canonical::ToolCall) ? tc.name : (tc[:name] || tc['name']),
                input: args
              }
            end

            { role: 'assistant', content: blocks }
          end

          def render_tool_result_message(msg)
            tool_call_id = msg.tool_call_id
            result_content = render_content_blocks(msg.content)

            {
              role:    'user',
              content: [
                { type: 'tool_result', tool_use_id: tool_call_id, content: result_content }
              ]
            }
          end

          def render_content_blocks(content)
            return [{ type: 'text', text: content.to_s }] if content.is_a?(String)
            return [] if content.nil?

            blocks = Array(content).filter_map do |block|
              case block
              when Canonical::ContentBlock
                content_block_to_wire(block)
              when Hash
                hash_block_to_wire(block)
              else
                { type: 'text', text: block.to_s }
              end
            end
            blocks.empty? ? [] : blocks
          end

          def content_block_to_wire(block)
            wire = case block.type
                   when :thinking
                     { type: 'thinking', thinking: block.text || '' }
                   when :tool_use
                     { type: 'tool_use', id: block.id, name: block.name, input: block.input || {} }
                   when :tool_result
                     { type: 'tool_result', tool_use_id: block.tool_use_id,
                       content: [{ type: 'text', text: block.text || '' }] }
                   when :image
                     { type: 'image', source: { type: block.source_type || 'base64',
                                                media_type: block.media_type, data: block.data } }
                   else
                     { type: 'text', text: block.text || '' }
                   end
            wire[:cache_control] = block.cache_control if block.cache_control
            wire
          end

          def hash_block_to_wire(block)
            block_type = block[:type] || block['type']
            cc = block[:cache_control] || block['cache_control']

            wire = case block_type
                   when 'image'
                     { type: 'image', source: block[:source] || block['source'] || {} }
                   when 'tool_result'
                     {
                       type:        'tool_result',
                       tool_use_id: block[:tool_use_id] || block['tool_use_id'],
                       content:     Array(block[:content] || block['content']).map do |item|
                         if item.is_a?(Hash)
                           { type: 'text', text: item[:text] || item['text'] || '' }
                         else
                           { type: 'text', text: item.to_s }
                         end
                       end
                     }
                   else
                     return block
                   end
            wire[:cache_control] = cc if cc
            wire
          end

          # --- system content ---

          def render_system_string(system_input)
            return system_input if system_input.is_a?(Hash) || system_input.is_a?(Array)

            [{ type: 'text', text: system_input.to_s }]
          end

          def render_system_content(messages)
            parts = messages.flat_map do |msg|
              content = msg.content
              if content.is_a?(Canonical::ContentBlock) && content.type == :text
                [{ type: 'text', text: content.text || '' }]
              elsif content.is_a?(Array)
                render_content_blocks(content)
              else
                [{ type: 'text', text: content.to_s }]
              end
            end
            parts.empty? ? nil : parts
          end

          # --- tools ---

          def render_tools(tools)
            return nil if tools.nil? || tools.empty?

            tools.values.map do |tool|
              name = tool.is_a?(Canonical::ToolDefinition) ? tool.name : (tool[:name] || tool['name'])
              desc = tool.is_a?(Canonical::ToolDefinition) ? tool.description : (tool[:description] || tool['description'] || '')
              params = if tool.is_a?(Canonical::ToolDefinition)
                         tool.parameters
                       else
                         Canonical::ToolDefinition.normalize_parameters(tool[:parameters] || tool['parameters'])
                       end

              { name: name, description: desc, input_schema: params }
            end
          end

          # --- tool_choice ---

          def render_tool_choice(tool_choice)
            return nil unless tool_choice

            case tool_choice
            when :auto, 'auto'
              { type: 'auto' }
            when :none, 'none'
              nil
            when :required, 'required'
              { type: 'any' }
            when Hash
              { type: 'tool', name: tool_choice[:name] || tool_choice['name'] }
            when Symbol, String
              { type: 'tool', name: tool_choice.to_s }
            end
          end

          # --- thinking ---

          def thinking_enabled?(canonical_request)
            thinking = canonical_request.thinking
            return false unless thinking

            case thinking
            when Canonical::Thinking::Config
              thinking.enabled?
            when Hash
              !!thinking
            else
              true
            end
          end

          def render_thinking_config(canonical_request)
            tc = canonical_request.thinking
            budget = case tc
                     when Canonical::Thinking::Config
                       tc.budget
                     when Hash
                       tc[:budget] || tc['budget'] || tc[:budget_tokens] || tc['budget_tokens']
                     end

            budget ||= canonical_request.params&.max_thinking_tokens
            budget = default_thinking_budget if budget.nil? || budget.zero?

            { type: 'enabled', budget_tokens: budget }
          end

          def default_thinking_budget
            @config[:default_thinking_budget] || 1024
          end

          # --- response_format ---

          def render_response_format(fmt)
            return nil unless fmt

            normalized = fmt.is_a?(Hash) ? fmt : {}
            fmt_type = normalized[:type] || normalized['type']
            schema = normalized[:schema] || normalized['schema'] || normalized.except(:type)

            case fmt_type
            when 'json_object', 'json_schema'
              if schema && !schema.empty?
                { type: 'json_schema', schema: schema }
              else
                { type: 'json_object' }
              end
            when :json, 'json'
              { type: 'json_object' }
            end
          end

          # --- unsupported params ---

          def drop_unsupported_params(params)
            # Anthropic Messages API does NOT support: top_p, top_k, frequency_penalty, presence_penalty.
            unsupported = {}
            unsupported[:top_p] = params.top_p if params.top_p
            unsupported[:top_k] = params.top_k if params.top_k
            unsupported[:frequency_penalty] = params.frequency_penalty if params.frequency_penalty
            unsupported[:presence_penalty] = params.presence_penalty if params.presence_penalty

            return if unsupported.empty?

            log.debug("[anthropic translator] dropping unsupported params: #{unsupported.keys.join(', ')}")
          end

          # --- response parsing ---

          def extract_text(blocks)
            blocks.select { |b| (b[:type] || b['type']) == 'text' }
                  .map { |b| b[:text] || b['text'] || '' }
                  .join
          end

          def extract_thinking(blocks)
            thinking_block = blocks.find { |b| (b[:type] || b['type']) == 'thinking' }
            redacted_block = blocks.find { |b| (b[:type] || b['type']) == 'redacted_thinking' }

            content = thinking_block&.dig(:thinking) || thinking_block&.dig('thinking') ||
                      thinking_block&.dig(:text) || thinking_block&.dig('text')
            signature = thinking_block&.dig(:signature) || thinking_block&.dig('signature') ||
                        redacted_block&.dig(:data) || redacted_block&.dig('data')

            Canonical::Thinking.from_hash({ content: content, signature: signature })
          end

          def extract_tool_calls(blocks)
            tc_blocks = blocks.select { |b| (b[:type] || b['type']) == 'tool_use' }
            return [] if tc_blocks.empty?

            tc_blocks.map do |block|
              args_input = block[:input] || block['input'] || {}
              args = parse_json_or_hash(args_input)

              Canonical::ToolCall.build(
                id:        block[:id] || block['id'],
                name:      block[:name] || block['name'],
                arguments: args,
                source:    :client
              )
            end
          end

          def parse_json_or_hash(input)
            return input if input.is_a?(Hash)

            if input.is_a?(String)
              begin
                Legion::JSON.load(input)
              rescue Legion::JSON::ParseError
                { raw_json: input }
              end
            else
              {}
            end
          end

          def parse_usage(usage)
            Canonical::Usage.from_hash(
              input_tokens:       usage[:input_tokens] || usage['input_tokens'],
              output_tokens:      usage[:output_tokens] || usage['output_tokens'],
              cache_read_tokens:  usage[:cache_read_input_tokens] || usage['cache_read_input_tokens'],
              cache_write_tokens: cache_creation_input_tokens(usage),
              thinking_tokens:    thinking_tokens_raw(usage)
            )
          end

          def cache_creation_input_tokens(usage)
            val = usage[:cache_creation_input_tokens] || usage['cache_creation_input_tokens']
            return val if val

            cache_creation = usage[:cache_creation] || usage['cache_creation']
            return cache_creation.values.sum if cache_creation.is_a?(Hash)

            val
          end

          def thinking_tokens_raw(usage)
            usage.dig(:output_tokens_details, :thinking_tokens) ||
              usage.dig('output_tokens_details', 'thinking_tokens') ||
              usage.dig(:output_tokens_details, :reasoning_tokens) ||
              usage.dig('output_tokens_details', 'reasoning_tokens') ||
              usage[:thinking_tokens] || usage['thinking_tokens'] ||
              usage[:reasoning_tokens] || usage['reasoning_tokens']
          end

          # --- chunk parsing ---

          def extract_delta(raw, _type)
            delta_val = raw[:delta] || raw['delta']
            # Canonical form: delta is a plain string (e.g. from conformance fixtures).
            return delta_val if delta_val.is_a?(String) && !delta_val.empty?

            # Anthropic wire form: delta is a nested object with {text:} or {thinking:}.
            raw.dig(:delta, :text) || raw.dig('delta', 'text') ||
              raw.dig(:delta, :thinking) || raw.dig('delta', 'thinking') ||
              ''
          end

          def extract_tool_call_from_chunk(raw)
            # Canonical form: tool_call is directly in the chunk (e.g. from conformance fixtures).
            tc_data = raw[:tool_call] || raw['tool_call']
            return extract_tc_from_data(tc_data) if tc_data

            # Anthropic wire form: tool call is in content_block with type 'tool_use'.
            cb = raw[:content_block] || raw['content_block']
            return nil unless cb && ((cb[:type] || cb['type']) == 'tool_use')

            extract_tc_from_data(cb)
          end

          def extract_tc_from_data(data)
            Canonical::ToolCall.build(
              id:        data[:id] || data['id'],
              name:      data[:name] || data['name'],
              arguments: data[:arguments] || data['arguments'] || {}
            )
          end

          # --- stop_reason mapping ---

          def map_stop_reason(raw)
            return nil unless raw

            mapping = {
              'end_turn'       => :end_turn,
              'tool_use'       => :tool_use,
              'max_tokens'     => :max_tokens,
              'stop_sequence'  => :stop_sequence,
              'content_filter' => :content_filter
            }

            result = mapping[raw.to_s]
            return result if result

            log.debug("[anthropic translator] unmapped stop_reason: #{raw.inspect}, defaulting to :end_turn")
            :end_turn
          end

          # --- settings helpers ---

          def settings_default_max_tokens
            @config[:default_max_tokens] || 4096
          end
        end
      end
    end
  end
end
