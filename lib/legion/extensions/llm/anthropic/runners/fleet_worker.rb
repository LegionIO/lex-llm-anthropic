# frozen_string_literal: true

require 'legion/extensions/llm/fleet/provider_responder'
require 'legion/extensions/llm/anthropic'

module Legion
  module Extensions
    module Llm
      module Anthropic
        module Runners
          # Runner entrypoint for Anthropic fleet request execution.
          module FleetWorker
            module_function

            def handle_fleet_request(payload, delivery: nil, properties: nil)
              Legion::Extensions::Llm::Fleet::ProviderResponder.call(
                payload: payload,
                provider_family: Anthropic::PROVIDER_FAMILY,
                provider_class: Anthropic::Provider,
                provider_instances: -> { Anthropic.discover_instances },
                delivery: delivery,
                properties: properties
              )
            end
          end
        end
      end
    end
  end
end
