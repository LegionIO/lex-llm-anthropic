# frozen_string_literal: true

require 'legion/extensions/llm/fleet/provider_responder'
require 'legion/extensions/llm/inventory/registry'
require 'legion/extensions/llm/anthropic'

module Legion
  module Extensions
    module Llm
      module Anthropic
        module Runners
          # Runner entrypoint for Anthropic fleet request execution.
          #
          # Invoked by the Subscription actor as
          # `runner_class.send(runner_function, **message)` — the decoded
          # envelope (symbol keys) merged with delivery metadata. The envelope
          # itself is the responder payload; the actor acks the AMQP delivery
          # after this returns.
          module FleetWorker
            module_function

            def handle_fleet_request(**message)
              Legion::Extensions::Llm::Fleet::ProviderResponder.call(
                payload:            message,
                provider_family:    Anthropic::PROVIDER_FAMILY,
                provider_class:     Anthropic::Provider,
                provider_instances: -> { Anthropic.discover_instances },
                registry:           Legion::Extensions::Llm::Inventory::Registry
              )
            end
          end
        end
      end
    end
  end
end
