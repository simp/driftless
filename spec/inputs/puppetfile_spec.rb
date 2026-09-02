require 'spec_helper'
require 'tmpdir'

require 'driftless/inputs/puppetfile'

RSpec.describe Driftless::Inputs::Puppetfile do
  def with_puppetfile(contents)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'Puppetfile'), contents) if contents
      yield described_class.load(dir)
    end
  end

  it 'reports exists? false when there is no Puppetfile' do
    with_puppetfile(nil) do |result|
      expect(result.exists?).to be false
      expect(result.modules).to eq([])
      expect(result.error).to be_nil
    end
  end

  it 'places a git module under the default moduledir by the last name segment' do
    with_puppetfile("mod 'puppetlabs-stdlib', :git => 'git@git.example.com:puppet/stdlib.git', :tag => 'v9.0.0'\n") do |result|
      m = result.modules.first
      expect(m.name).to eq('puppetlabs-stdlib')
      expect(m.path).to eq('modules/stdlib')
      expect(m.git).to eq('git@git.example.com:puppet/stdlib.git')
      expect([m.ref, m.ref_type]).to eq(['v9.0.0', 'tag'])
    end
  end

  it 'follows moduledir and install_path' do
    contents = <<~PF
      forge 'https://forge.puppet.com'
      moduledir 'site-modules'
      mod 'profile', git: 'https://git.example.com/puppet/profile.git', branch: 'main'
      mod 'tenant-data', git: 'https://git.example.com/tenant/data.git', ref: 'abc', install_path: './data'
    PF
    with_puppetfile(contents) do |result|
      expect(result.modules.map(&:path)).to eq(%w[site-modules/profile data/data])
      expect(result.modules.map { |m| [m.ref, m.ref_type] }).to eq([%w[main branch], %w[abc ref]])
    end
  end

  it 'takes ref over tag over commit over branch, and reads a 40-hex ref as a commit' do
    sha = 'a' * 40
    contents = <<~PF
      mod 'a', git: 'g', ref: '#{sha}', tag: 'v1'
      mod 'b', git: 'g', tag: 'v1', commit: '#{sha}', branch: 'main'
      mod 'c', git: 'g', commit: '#{sha}', branch: 'main'
      mod 'd', git: 'g', branch: :control_branch, default_branch: 'main'
      mod 'e', git: 'g'
    PF
    with_puppetfile(contents) do |result|
      expect(result.modules.map { |m| [m.ref, m.ref_type] }).to eq([
        [sha, 'commit'], %w[v1 tag], [sha, 'commit'], [:control_branch, 'branch'], [nil, nil],
      ])
    end
  end

  it 'records Forge modules without a remote' do
    with_puppetfile("mod 'puppetlabs-stdlib', '9.0.0'\nmod 'puppetlabs-concat', :latest\nmod 'puppetlabs-apt'\n") do |result|
      expect(result.modules.map(&:git)).to eq([nil, nil, nil])
      expect(result.modules.map(&:path)).to eq(%w[modules/stdlib modules/concat modules/apt])
    end
  end

  it 'returns the error for a Puppetfile it cannot evaluate, with no modules' do
    with_puppetfile("mod 'a', git: 'g'\nnot_a_declaration 'x'\n") do |result|
      expect(result.exists?).to be true
      expect(result.modules).to eq([])
      expect(result.error).to include("unrecognized Puppetfile declaration 'not_a_declaration'")
    end
    with_puppetfile("mod 'a', git: 'g'\nmod (\n") do |result|
      expect(result.error).to include('SyntaxError')
    end
  end
end
