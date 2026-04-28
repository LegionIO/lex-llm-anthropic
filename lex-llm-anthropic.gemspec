# frozen_string_literal: true

require_relative 'lib/legion/extensions/llm/anthropic/version'

Gem::Specification.new do |spec|
  spec.name          = 'lex-llm-anthropic'
  spec.version       = Legion::Extensions::Llm::Anthropic::VERSION
  spec.authors       = ['LegionIO']
  spec.email         = ['matthewdiverson@gmail.com']
  spec.summary       = 'LegionIO LLM Anthropic provider extension'
  spec.description   = 'Anthropic provider integration for the LegionIO LLM routing framework.'
  spec.homepage      = 'https://github.com/LegionIO/lex-llm-anthropic'
  spec.license       = 'MIT'
  spec.required_ruby_version = '>= 3.4'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = spec.homepage
  spec.metadata['documentation_uri'] = spec.homepage
  spec.metadata['changelog_uri'] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata['bug_tracker_uri'] = "#{spec.homepage}/issues"
  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.files = `git ls-files -z`.split("\x0").reject { |file| file.match(%r{^(spec|test|features|tmp|coverage)/}) }
  spec.require_paths = ['lib']

  spec.add_dependency 'lex-llm', '>= 0.1.3'
end
