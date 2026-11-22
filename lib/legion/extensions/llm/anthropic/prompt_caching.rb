# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Anthropic
        # Native Messages API placement policy, shared by both render paths.
        # Explicit controls belong to the caller; automatic caching never
        # changes their positions, TTL ordering, or validation semantics.
        module PromptCaching
          MAX_BREAKPOINTS = 4
          CACHEABLE_BLOCK_TYPES = %w[text image document tool_use tool_result].freeze

          module_function

          def project_message_control(blocks:, control:, **)
            project_control(block: last_cacheable(blocks: blocks), control: control)
            blocks
          end

          def project_control(block:, control:, **)
            block[:cache_control] = control if block && !control.nil? && !block.key?(:cache_control)
            block
          end

          def apply(payload:, cache_tools:, cache_system:, message_prefix_count:, **)
            return payload if explicit_controls?(payload: payload)

            candidates = []
            candidates << payload.fetch(:tools, []).last if cache_tools
            candidates << last_cacheable(blocks: payload.fetch(:system, [])) if cache_system
            prefix = payload.fetch(:messages).first(message_prefix_count)
            candidates << last_cacheable(blocks: prefix.flat_map { |message| message.fetch(:content) })
            candidates.compact.first(MAX_BREAKPOINTS).each do |block|
              block[:cache_control] = { type: 'ephemeral' }
            end
            payload
          end

          def explicit_controls?(payload:)
            payload.fetch(:tools, []).any? { |tool| tool.key?(:cache_control) } ||
              explicit_blocks?(blocks: payload.fetch(:system, [])) ||
              payload.fetch(:messages).any? { |message| explicit_blocks?(blocks: message.fetch(:content)) }
          end

          def explicit_blocks?(blocks:)
            blocks.any? do |block|
              block.key?(:cache_control) ||
                (block[:type] == 'tool_result' && block[:content].is_a?(Array) && explicit_blocks?(blocks: block[:content]))
            end
          end

          def last_cacheable(blocks:)
            blocks.reverse_each.find do |block|
              CACHEABLE_BLOCK_TYPES.include?(block[:type]) &&
                (block[:type] != 'text' || !block.fetch(:text).empty?)
            end
          end
        end
      end
    end
  end
end
