# frozen_string_literal: true

require 'legion/extensions/llm/fleet/provider_responder'

module Legion
  module Extensions
    module Llm
      module Anthropic
        module Actor
          # Subscription actor for Anthropic fleet request consumption.
          class FleetWorker < Legion::Extensions::Actors::Subscription
            def runner_class
              'Legion::Extensions::Llm::Anthropic::Runners::FleetWorker'
            end

            def runner_function
              'handle_fleet_request'
            end

            def use_runner?
              false
            end

            def enabled?
              Legion::Extensions::Llm::Fleet::ProviderResponder.enabled_for?(Anthropic.discover_instances)
            end
          end
        end
      end
    end
  end
end
