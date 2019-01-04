# frozen_string_literal: true

lib = File.expand_path('lib', __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'git-lfs-s3/version'

Gem::Specification.new do |gem|
  gem.name          = 'lsst-git-lfs-s3'
  gem.version       = GitLfsS3::VERSION
  gem.authors       = [
    'Ryan LeFevre',
    'J. Matt Peterson',
    'Joshua Hoblitt',
  ]
  gem.email = [
    'meltingice8917@gmail.com',
    'jmatt@lsst.org',
    'josh@hoblitt.com',
  ]
  gem.description   = "LSST's Git LFS server"
  gem.summary       = "LSST's Git LFS server"
  gem.homepage      = 'https://github.com/lsst-sqre/git-lfs-s3'
  gem.license       = 'MIT'

  gem.files         = `git ls-files`.split($INPUT_RECORD_SEPARATOR)
  gem.executables   = gem.files.grep(%r{^bin/}).map { |f| File.basename(f) }
  gem.test_files    = gem.files.grep(%r{^(test|spec|features)/})
  gem.require_paths = ['lib']

  gem.add_dependency 'aws-sdk', '~> 2'
  gem.add_dependency 'multi_json', '~> 1'
  gem.add_dependency 'sinatra', '>= 2.0.2'

  gem.add_development_dependency 'rake', '~> 10'
  gem.add_development_dependency 'rubocop', '~> 0.61.1'
end
