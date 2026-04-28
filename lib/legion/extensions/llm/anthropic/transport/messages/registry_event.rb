# frozen_string_literal: true

require 'legion/extensions/llm/anthropic/transport/exchanges/llm_registry'

module Legion
  module Extensions
    module Llm
      module Anthropic
        module Transport
          module Messages
            # Publishes lex-llm RegistryEvent envelopes to the llm.registry exchange.
            class RegistryEvent < ::Legion::Transport::Message
              def initialize(event:, **options)
                super(**event.to_h.merge(options))
              end

              def exchange
                Transport::Exchanges::LlmRegistry
              end

              def routing_key
                @options[:routing_key] || "llm.registry.#{@options.fetch(:event_type)}"
              end

              def type
                'llm.registry.event'
              end

              def app_id
                @options[:app_id] || RegistryPublisher::APP_ID
              end

              def persistent # rubocop:disable Naming/PredicateMethod
                false
              end
            end
          end
        end
      end
    end
  end
end
