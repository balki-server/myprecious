Gem::Specification.new do |s|
  s.name        = 'myprecious'
  s.version     = '0.0.8'
  s.date        = '2019-03-28'
  s.summary     = "Your precious dependencies!"
  s.description = "A simple, markdown generated with information about your gems"
  s.authors     = ["Balki Kodarapu"]
  s.email       = 'balki.kodarapu@gmail.com'
  s.files       = ["lib/myprecious.rb"]
  s.executables << 'myprecious'
  s.add_runtime_dependency 'gems', '~> 1.0', '>= 1.0.0'
  s.add_runtime_dependency 'git', '~> 1.5', '>= 1.5.0'
  s.homepage    =
    'http://rubygems.org/gems/myprecious'
  s.license       = 'MIT'
end
