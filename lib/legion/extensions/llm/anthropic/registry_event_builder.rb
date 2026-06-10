# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module Extensions
    module Llm
      module Anthropic
        # Builds sanitized lex-llm registry envelopes for Anthropic provider state.
        class RegistryEventBuilder
          include Legion::Logging::Helper

          def model_available(model, readiness:)
            registry_event_class.available(
              model_offering(model),
              runtime:  runtime_metadata,
              health:   model_health(readiness),
              metadata: model_metadata(model)
            )
          end

          private

          def model_offering(model)
            {
              provider_family:   :anthropic,
              provider_instance: provider_instance,
              transport:         :http,
              model:             model.id,
              usage_type:        :inference,
              capabilities:      Array(model.capabilities).map(&:to_sym),
              limits:            model_limits(model),
              metadata:          { lex: :llm_anthropic, model_name: model.name }.compact
            }
          end

          def model_health(readiness)
            ready = readiness.fetch(:ready, true) == true
            { ready:, status: ready ? :available : :degraded }
          end

          def model_metadata(model)
            { extension: :lex_llm_anthropic, provider: :anthropic, model_type: model.type }
          end

          def runtime_metadata
            { node: provider_instance }
          end

          def model_limits(model)
            {
              context_window:    model.context_window,
              max_output_tokens: model.max_output_tokens
            }.compact
          end

          def provider_instance
            configured_node = (::Legion::Settings.dig(:node, :canonical_name) if defined?(::Legion::Settings))
            value = configured_node.to_s.strip
            value.empty? ? :anthropic : value.to_sym
          rescue StandardError => e
            handle_exception(e, level: :debug, handled: true,
                                operation: 'anthropic.registry.provider_instance')
            :anthropic
          end

          def registry_event_class
            ::Legion::Extensions::Llm::Routing::RegistryEvent
          end
        end
      end
    end
  end
end
