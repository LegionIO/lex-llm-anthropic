# frozen_string_literal: true

require 'bundler/setup'

# The lex gem ships without LegionIO on its load path. Define the actor
# runtime stand-ins (Every base, Lex settings shim) before the extension
# entrypoint loads so the real discovery actor and callable classes load for
# testing instead of being skipped by the actor file's runtime guard.
require_relative 'support/actor_runtime_stubs'

require 'legion/extensions/llm'
require 'legion/extensions/llm/anthropic'

# Load the conformance kit from the lex-llm gem spec directory (not on the
# load path). Only the files this suite uses are loaded — the kit's translator
# self-test specs and unused example groups must not run inside this suite.
lex_llm_gem_path = Gem.loaded_specs['lex-llm']&.full_gem_path
if lex_llm_gem_path
  conformance_dir = File.join(lex_llm_gem_path, 'spec', 'legion', 'extensions', 'llm', 'conformance')
  %w[
    conformance.rb
    provider_translator_examples.rb
    ssot_provider_examples.rb
  ].each do |file|
    path = File.join(conformance_dir, file)
    require path if File.exist?(path)
  end
end
