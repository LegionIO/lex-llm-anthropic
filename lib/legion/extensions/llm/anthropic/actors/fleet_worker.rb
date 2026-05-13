# frozen_string_literal: true

require 'legion/logging/helper'

actor_load_logger = Object.new.extend(Legion::Logging::Helper)
actor_load_logger.define_singleton_method(:lex_filename) { 'llm_anthropic' }

begin
  require 'legion/extensions/actors/subscription'
rescue LoadError => e
  subscription_load_error = e
end

unless defined?(Legion::Extensions::Actors::Subscription)
  if subscription_load_error
    actor_load_logger.handle_exception(subscription_load_error, level: :warn, handled: true,
                                                                operation: 'anthropic.actor.subscription_load')
  end
  raise LoadError, 'LegionIO actor runtime is required for Anthropic fleet worker'
end

require 'legion/extensions/llm/anthropic'
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
