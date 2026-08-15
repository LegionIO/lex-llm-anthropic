# frozen_string_literal: true

# Minimal stand-ins for the LegionIO actor runtime, which is not a dependency
# of this gem. They are defined before the extension entrypoint loads so the
# real DiscoveryRefresh / AnthropicCallable classes — which subclass the
# LegionIO Every actor base and include the Lex settings helper — load in the
# test process. Every definition is guarded with const_defined?: inside a
# LegionIO host the real classes exist and win.

require 'legion/settings/helper'

module Legion
  module Extensions
    module Actors
      unless const_defined?(:Every, false)
        # Test double for the LegionIO periodic actor base. It installs no
        # timer: specs drive DiscoveryRefresh#manual / #time / #shutdown
        # directly.
        class Every
          def initialize(**_options); end
        end
      end
    end

    module Helpers
      unless const_defined?(:Lex, false)
        # The Lex settings helper, wired exactly as the LegionIO host wires it:
        # resolution comes from the real Legion::Settings::Helper (legion-settings),
        # which derives the nested extension path from the calling class
        # namespace. This gem's actor —
        # Legion::Extensions::Llm::Anthropic::Actor::DiscoveryRefresh — stops at
        # the Actor boundary word and resolves to
        # Settings[:extensions][:llm][:anthropic].
        module Lex
          include ::Legion::Settings::Helper
        end
      end
    end
  end
end
