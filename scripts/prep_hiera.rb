#! /usr/bin/env ruby

require 'yaml'

# Transalate eyaml tiers in `hiera.yaml` into mockable yaml version, with data
# under spec/data/. 
#
#
# Onceover doesn't have access to eyaml keys, so it would fail while loading
# the real `hiera.yaml`.  This means that any encrypted values need to have a
# plaintext dummy value present, to allow parameters to resolve.
#
# This builds on the recommendation from the onceover docs
# (https://github.com/voxpupuli/onceover#hiera-eyaml)
#
# This script prints to stdout, but the result should be placed into
# spec/hiera.yaml (which Onceover will prefer, if it exists)


if ARGV[0].nil?
  puts "Usage: prep_hiera <hiera config>"
  exit 1
end

contents = YAML.load_file("#{ARGV[0]}")

########################################
#
# Filter out the eyaml sections
#
########################################
hierarchy = contents['hierarchy']
if hierarchy.nil?
  puts "'hierarchy' section is missing from #{ARGV[0]}"
  exit 1
end

translated = hierarchy.map do |section|
  section['paths'] = section['paths'].map { |path| "../spec/mock_data/#{path}" } + section['paths']
  if section.has_key?('lookup_key')
    section['name'] += ' (mocked data only)'
    section['paths'].each do |path|
      next(path) unless path =~ /\.eyaml\z/
      path.sub!(%{\A(\.\./spec/mock_data/.*)\.eyaml\z}, '\1.yaml')
    end
    section['paths'].compact!
    section.delete 'lookup_key'
    [ 'pkcs7_private_key', 'pkcs7_public_key' ].each do |opt|
      section['options'].delete(opt) if section.dig('options', opt)
    end
    section.delete('options') if section['options'].empty?
  end
  section
end

contents['hierarchy'] = translated

########################################
#
# Readjust the datadir relative to spec/
#
########################################
datadir = contents.dig('defaults', 'datadir')
unless datadir.nil?
  contents['defaults']['datadir'] = '../data'
end

# Dump modified YAML to stdout
puts YAML.dump(contents)
