# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Anthropic
        module Transport
          module Exchanges
            # Topic exchange for Anthropic provider availability events.
            class LlmRegistry < ::Legion::Transport::Exchange
              def exchange_name
                'llm.registry'
              end

              def default_type
                'topic'
              end
            end
          end
        end
      end
    end
  end
end
