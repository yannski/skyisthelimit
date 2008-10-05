require 'rubygems'
Gem::manage_gems
require 'rake/gempackagetask'

spec = Gem::Specification.new do |s|
  s.platform  =   Gem::Platform::RUBY
  s.name      =   "skyisthelimit"
  s.version   =   "0.1.1"
  s.author    =   "Yann Klis"
  s.email     =   "yann.klis @nospam@ novelys.com"
  s.summary   =   "A Capistrano extension that helpd building complex system architectures (including Cloud Computing)."
  s.files     =   FileList['lib/*.rb', 'lib/capistrano/*.rb', 'lib/ext/*.rb'].to_a
  s.require_path  =   "lib"
  s.autorequire   =   "skyisthelimit"
#  s.test_files = Dir.glob('tests/*.rb')
  s.has_rdoc  =   true
  s.extra_rdoc_files  =   ["README", "MIT-LICENSE"]
  s.add_dependency("amazon-ec2")
end

Rake::GemPackageTask.new(spec) do |pkg|
  pkg.need_tar = true
end

task :default => "pkg/#{spec.name}-#{spec.version}.gem" do
  puts "generated latest version"
end

