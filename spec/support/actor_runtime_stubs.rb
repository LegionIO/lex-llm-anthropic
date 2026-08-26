# frozen_string_literal: true

# Minimal stand-ins for the LegionIO actor runtime, which is not a dependency
# of this gem. They are defined before the extension entrypoint loads so the
# real Discovery actor / Callable classes — which subclass the
# LegionIO Every actor base and include the Lex settings helper — load in the
# test process. Every definition is guarded with const_defined?: inside a
# LegionIO host the real classes exist and win.

require 'legion/logging'
require 'legion/logging/helper'
require 'legion/settings/helper'

module Legion
  module Extensions
    module Actors
      unless const_defined?(:Every, false)
        # Test double for the LegionIO periodic actor base. It installs no
        # timer: specs drive the discovery runner module (refresh /
        # remove_all_instances) and the actor's #time / #shutdown directly.
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
        # Legion::Extensions::Llm::Anthropic::Actor::Discovery (and the runner
        # module, which stops at the Runners boundary word) — resolves to
        # Settings[:extensions][:llm][:anthropic]. Legion::Logging::Helper adds
        # the `log` accessor and the non-re-raising `handle_exception` (the
        # real default is `handled: true`) that the shared discovery pipeline
        # and the callable mix in through this helper.
        module Lex
          include ::Legion::Settings::Helper
          include ::Legion::Logging::Helper
        end
      end
    end
  end
end
