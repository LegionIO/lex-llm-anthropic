# frozen_string_literal: true

require 'legion/extensions/llm'
require 'legion/extensions/llm/anthropic/registry_event_builder'
require 'legion/extensions/llm/anthropic/registry_publisher'
require 'legion/extensions/llm/anthropic/provider'
require 'legion/extensions/llm/anthropic/version'

module Legion
  module Extensions
    module Llm
      # Anthropic provider extension namespace.
      module Anthropic
        extend ::Legion::Extensions::Core if ::Legion::Extensions.const_defined?(:Core, false)

        PROVIDER_FAMILY = :anthropic

        def self.default_settings
          ::Legion::Extensions::Llm.provider_settings(
            family: PROVIDER_FAMILY,
            instance: {
              endpoint: 'https://api.anthropic.com',
              tier: :frontier,
              transport: :http,
              credentials: { api_key: 'env://ANTHROPIC_API_KEY' },
              usage: { inference: true, embedding: false },
              limits: { concurrency: 4 }
            }
          )
        end

        def self.provider_class
          Provider
        end
      end
    end
  end
end

Legion::Extensions::Llm::Provider.register(Legion::Extensions::Llm::Anthropic::PROVIDER_FAMILY,
                                           Legion::Extensions::Llm::Anthropic::Provider)
