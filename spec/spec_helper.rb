# frozen_string_literal: true

require 'bundler/setup'
require 'legion/extensions/llm'
require 'legion/extensions/llm/anthropic'

# Load conformance kit from lex-llm gem spec directory (not on load path).
lex_llm_gem_path = Gem.loaded_specs['lex-llm']&.full_gem_path
if lex_llm_gem_path
  conformance_dir = File.join(lex_llm_gem_path, 'spec', 'legion', 'extensions', 'llm', 'conformance')
  Dir[File.join(conformance_dir, '**', '*.rb')].each { |path| require path } if Dir.exist?(conformance_dir)
end
