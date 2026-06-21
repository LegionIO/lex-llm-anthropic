# frozen_string_literal: true

require 'digest'

begin
  require 'legion/extensions/actors/every'
rescue LoadError => e
  warn(e.message) if $VERBOSE
end

begin
  require 'legion/extensions/llm/inventory/scoped_refresher'
rescue LoadError => e
  warn(e.message) if $VERBOSE
end

return unless defined?(Legion::Extensions::Actors::Every)

module Legion
  module Extensions
    module Llm
      module Anthropic
        module Actor
          class DiscoveryRefresh < Legion::Extensions::Actors::Every
            include Legion::Logging::Helper
            include Legion::Extensions::Llm::Inventory::ScopedRefresher if defined?(Legion::Extensions::Llm::Inventory::ScopedRefresher)

            EMBED_TYPES = %i[embed embedding].freeze

            def self.every_seconds = 3600

            def runner_class    = self.class
            def runner_function = 'manual'
            def run_now?        = true
            def use_runner?     = false
            def check_subtask?  = false
            def generate_task?  = false

            def time
              return self.class.every_seconds unless defined?(Legion::Settings)

              Legion::Settings.dig(:extensions, :llm, :anthropic, :discovery_interval) || self.class.every_seconds
            end

            def scope_key
              { provider: :anthropic }
            end

            def compute_lanes_for_scope
              return [] unless defined?(Legion::LLM::Call::Registry)

              instances = Legion::LLM::Call::Registry.all_instances.select do |e|
                (e[:provider] || '').to_sym == :anthropic
              end

              lanes = []

              instances.each do |instance|
                adapter = instance[:adapter]
                source =
                  if adapter.respond_to?(:discover_offerings) then adapter.discover_offerings(live: true)
                  elsif adapter.respond_to?(:offerings) then adapter.offerings(live: false)
                  else next
                  end

                Array(source).filter_map do |raw|
                  offering = offering_to_hash(raw)
                  next unless offering

                  instance_id = instance[:instance] || instance[:instance_id] || instance[:id] || 'default'
                  model       = offering[:model] || offering[:id]
                  next unless model

                  offering_type = if EMBED_TYPES.include?((offering[:type] || '').to_sym)
                                    :embedding
                                  else
                                    :inference
                                  end

                  tier = offering[:tier]&.to_sym || :frontier

                  capabilities = if defined?(Legion::Extensions::Llm::Inventory::Capabilities)
                                   Legion::Extensions::Llm::Inventory::Capabilities.normalize(offering[:capabilities])
                                 else
                                   Array(offering[:capabilities])
                                 end

                  lane_id = Legion::Extensions::Llm::Inventory::ScopedRefresher.compose_id(
                    tier:            tier,
                    provider_family: :anthropic,
                    instance_id:     instance_id,
                    type:            offering_type,
                    model:           model
                  )

                  lane = {
                    id:                    lane_id,
                    tier:                  tier,
                    provider_family:       :anthropic,
                    instance_id:           instance_id,
                    model:                 model,
                    canonical_model_alias: offering[:canonical_model_alias],
                    type:                  offering_type,
                    capabilities:          capabilities,
                    limits:                offering[:limits] || {},
                    enabled:               offering.fetch(:enabled, true),
                    cost:                  offering[:cost] || {}
                  }.compact

                  lanes << lane

                  # G29: also emit a fleet lane for each inference lane when fleet dispatch is configured
                  if offering_type == :inference
                    settings = Legion::Settings.dig(:extensions, :llm, :anthropic) || {}
                    if settings[:fleet]&.dig(:dispatch, :enabled)
                      fleet_id = Legion::Extensions::Llm::Inventory::ScopedRefresher.compose_id(
                        tier:            :fleet,
                        provider_family: :anthropic,
                        instance_id:     instance_id,
                        type:            :inference,
                        model:           model
                      )
                      lanes << lane.merge(id: fleet_id, tier: :fleet)
                    end
                  end
                end
              end

              lanes
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true, operation: 'anthropic.actor.discovery_refresh.compute_lanes')
              []
            end

            def credential_hash
              settings = Legion::Settings.dig(:extensions, :llm, :anthropic) || {}
              Digest::SHA256.hexdigest(settings[:api_key].to_s + settings[:instances].to_s)[0, 16]
            end

            def manual
              tick if respond_to?(:tick)
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true, operation: 'anthropic.actor.discovery_refresh')
            end

            private

            # ModelOffering objects do not implement `[]`; normalize to a Hash so the
            # writer stays Hash-shaped. Hash inputs pass through untouched.
            def offering_to_hash(offering)
              return nil if offering.nil?
              return offering if offering.is_a?(Hash)

              hash = offering.to_h
              hash[:type] ||= hash[:usage_type]
              hash[:enabled] = offering.respond_to?(:enabled?) ? offering.enabled? : true
              hash
            end
          end
        end
      end
    end
  end
end
