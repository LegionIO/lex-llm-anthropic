# frozen_string_literal: true

require 'legion/extensions/llm'
require 'legion/extensions/llm/anthropic/provider_settings'
require 'legion/extensions/llm/anthropic/version'

module Legion
  module Extensions
    module Llm
      # Anthropic provider extension namespace.
      module Anthropic
        extend ::Legion::Extensions::Core if ::Legion::Extensions.const_defined?(:Core, false)

        PROVIDER_FAMILY = :anthropic

        def self.default_settings
          ProviderSettings.build(
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
      end
    end
  end
end
