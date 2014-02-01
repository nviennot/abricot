# encoding: utf-8
$:.unshift File.expand_path("../lib", __FILE__)

Gem::Specification.new do |s|
  s.name        = 'abricot'
  s.version     = '0.1'
  s.platform    = Gem::Platform::RUBY
  s.authors     = ["Nicolas Viennot"]
  s.email       = ["nicolas@viennot.biz"]
  s.homepage    = "https://github.com/nviennot/abricot"
  s.summary     = "Fast Cloud Management Tool with Redis pub/sub"
  s.description = "Fast Cloud Management Tool with Redis pub/sub"
  s.license     = "LGPLv3"

  s.add_dependency "redis", "~> 3.0.7"
  s.add_dependency "ruby-progressbar", "~> 1.4.1"
  s.add_dependency "thor", "~> 0.18.1"
  s.add_dependency "json", "~> 1.8.1"

  s.executables   = ['abricot']

  s.files        = Dir["lib/**/*"] + Dir["bin/**/*"] + ['README.md']
  s.require_path = 'lib'
  s.has_rdoc     = false

  s.required_ruby_version = '>= 1.9.3'
end
