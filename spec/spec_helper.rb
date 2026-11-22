# frozen_string_literal: true

require 'bundler/setup'

require 'legion/logging'
Legion::Logging.setup(level: nil, log_file: File::NULL, log_stdout: false, async: false)

require 'legion/extensions/llm'
# Load the declared host test dependency without starting services or actors.
require 'legion/transport'
require 'legion/extensions/helpers/lex'
require 'legion/extensions/actors/every'
require 'legion/extensions/actors/subscription'
require 'legion/extensions/llm/anthropic'

# Load the conformance kit from the lex-llm gem spec directory (not on the
# load path). Only the files this suite uses are loaded — the kit's translator
# self-test specs and unused example groups must not run inside this suite.
conformance_dir = File.join(Gem.loaded_specs.fetch('lex-llm').full_gem_path, 'spec', 'legion', 'extensions', 'llm', 'conformance')
%w[
  conformance.rb
  provider_translator_examples.rb
  ssot_provider_examples.rb
].each do |file|
  require File.join(conformance_dir, file)
end
