# coding: utf-8
require File.expand_path('../lib/database_exporter/version', __FILE__)

Gem::Specification.new do |spec|
  spec.name          = 'database_exporter'
  spec.version       = DatabaseExporter::VERSION
  spec.authors       = ['Marton Somogyi']
  spec.email         = ['msomogyi@whitepages.com']
  spec.summary       = %q{Export your SQL database}
  spec.description   = %q{Duplicate a databse with sanitization options using SQL comments}
  spec.homepage      = 'https://github.com/mcbuddha/database_exporter'
  spec.license       = 'MIT'

  spec.files         = `git ls-files -z`.split("\x0")
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ['lib']

  spec.add_development_dependency 'bundler', '~> 1.6'
  spec.add_development_dependency 'rake', '~> 10'
  spec.add_development_dependency 'pg', '~> 0.17'

  spec.add_runtime_dependency 'activerecord_comments', '~> 0'
  spec.add_runtime_dependency 'progress', '~> 3'
  spec.add_runtime_dependency 'iconv', '~> 1'
end
