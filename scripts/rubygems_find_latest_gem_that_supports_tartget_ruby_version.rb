require 'net/http'
require 'json'
require 'uri'

GEM_SERVER=ENV['GEM_SERVER']||'https://rubygems.org'

# --- CLI ARGUMENTS ---
if ARGV.length < 2
  puts 'Usage: ruby find_gem.rb <target_ruby_version> <gem_name>'
  puts 'Example: ruby find_gem.rb  2.7 colored2'
  exit 1
end

TARGET_RUBY = ARGV[0]
GEM_NAME    = ARGV[1]
# ---------------------

def fetch_json(url)
  response = Net::HTTP.get_response(URI(url))
  JSON.parse(response.body) if response.code == '200'
rescue
  nil
end

puts 'Streaming Compact Index to extract version names...'
index_url = "#{GEM_SERVER}/info/#{GEM_NAME}"
response = Net::HTTP.get_response(URI(index_url))

if response.code != '200'
  puts "Error: Could not find gem '#{GEM_NAME}' on the index server."
  exit 1
end

verbose = ENV.fetch('VERBOSE','no') == 'yes'

# The compact index lists versions at the start of each line
# We extract the version tokens and reverse them to prioritize the latest releases
version_numbers = response.body.lines.map { |line| line.split(' ').first }.compact.reverse


puts "-- #{GEM_NAME} versions: #{version_numbers.join(', ')}" if verbose

puts "Scanning v2 API to find the latest release supporting Ruby #{TARGET_RUBY}..."
target_version = Gem::Version.new(TARGET_RUBY)
latest_compatible = nil

version_numbers.each do |version|
  v2_url = "#{GEM_SERVER}/api/v2/rubygems/#{GEM_NAME}/versions/#{version}.json"
  details = fetch_json(v2_url)
  
  next unless details && details['ruby_version']
  
  begin
puts "   -- #{GEM_NAME} #{version}: required ruby version: #{details['ruby_version']}" if verbose
    requirement = Gem::Requirement.new(details['ruby_version'])
    if requirement.satisfied_by?(target_version)
      latest_compatible = version
      break # First match wins since our array order is descending (newest first)
    end
  rescue ArgumentError
    next
  end
end

if latest_compatible
  puts "\nSuccess! The latest version of '#{GEM_NAME}' supporting Ruby #{TARGET_RUBY} is: #{latest_compatible}"
else
  puts "\nNo versions of '#{GEM_NAME}' found that support Ruby #{TARGET_RUBY}."
end
