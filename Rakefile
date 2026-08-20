require 'bundler/gem_tasks'
require 'rspec/core/rake_task'

RSpec::Core::RakeTask.new(:spec)

task default: :spec

# Load extra rake tasks if any exist
Dir.glob('scripts/rake/*.rake').each { |r| load r}
