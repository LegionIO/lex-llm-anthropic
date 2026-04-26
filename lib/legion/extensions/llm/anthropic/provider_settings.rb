# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Anthropic
        # Builds provider defaults while inheriting shared lex-llm defaults.
        module ProviderSettings
          module_function

          def build(family:, instance:)
            deep_merge(
              base_settings,
              {
                enabled: true,
                provider_family: family,
                discovery: { enabled: true, interval_seconds: 300 },
                instances: {
                  default: {
                    enabled: true,
                    credentials: nil,
                    fleet: { enabled: false, consumer_priority: 0, prefetch: 1 }
                  }.merge(instance)
                }
              }
            )
          end

          def base_settings
            return {} unless ::Legion::Extensions::Llm.respond_to?(:default_settings)

            deep_dup(::Legion::Extensions::Llm.default_settings)
          end

          def deep_dup(value)
            case value
            when Hash
              value.to_h { |key, inner_value| [key, deep_dup(inner_value)] }
            when Array
              value.map { |inner_value| deep_dup(inner_value) }
            else
              value
            end
          end

          def deep_merge(left, right)
            left.merge(right) do |_key, left_value, right_value|
              left_value.is_a?(Hash) && right_value.is_a?(Hash) ? deep_merge(left_value, right_value) : right_value
            end
          end
        end
      end
    end
  end
end
