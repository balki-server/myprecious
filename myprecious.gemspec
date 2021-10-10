require 'rake'
Gem::Specification.new do |s|
  s.name        = 'myprecious'
  s.version     = '0.2.1'
  s.date        = '2021-10-10'
  s.summary     = "Your precious dependencies!"
  s.description = "A simple, markdown generated with information about your gems and python packages"
  s.authors     = ["Balki Kodarapu"]
  s.email       = 'balki.kodarapu@gmail.com'
  s.files       = FileList["lib/**/*.rb"].to_a
  s.executables << 'myprecious'
  s.add_runtime_dependency 'gems', '~> 1.0', '>= 1.0.0'
  s.add_runtime_dependency 'git', '~> 1.5', '>= 1.5.0'
  s.add_runtime_dependency 'rake-toolkit_program'
  s.add_runtime_dependency 'rest-client', '~> 2.0.2', '>= 2.0'
  s.add_runtime_dependency 'parslet', '~> 2.0'
  s.add_runtime_dependency 'rubyzip', '~> 2.3'

  s.add_development_dependency "bundler", ">= 2.2.10"
  s.add_development_dependency "pry", "~> 0.13"
  s.add_development_dependency "rb-readline", "~> 0.5"
  s.add_development_dependency "byebug"

  s.homepage    =
    'http://rubygems.org/gems/myprecious'
  s.license       = 'MIT'
end
