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
      expect(result.modules.map(&:default_branch)).to eq([nil, nil, nil, 'main', nil])
    end
  end

  it 'records Forge modules without a remote' do
    with_puppetfile("mod 'puppetlabs-stdlib', '9.0.0'\nmod 'puppetlabs-concat', :latest\nmod 'puppetlabs-apt'\n") do |result|
      expect(result.modules.map(&:git)).to eq([nil, nil, nil])
      expect(result.modules.map(&:path)).to eq(%w[modules/stdlib modules/concat modules/apt])
    end
  end

  it 'marks a local module, by :local or :type, and no other' do
    with_puppetfile("mod 'site', :local => true\nmod 'data', type: 'local'\nmod 'puppetlabs-apt'\nmod 'a', git: 'g'\n") do |result|
      expect(result.modules.map(&:local)).to eq([true, true, false, false])
      expect(result.modules.map(&:version)).to eq([nil, nil, nil, nil])
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

  describe 'Forge versions and load_file' do
    it 'keeps a Forge module\'s declared version and leaves it nil for git modules' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'Proposed')
        File.write(path, <<~PF)
          mod 'puppetlabs-stdlib', '9.4.0'
          mod 'puppetlabs-concat', version: '7.0.0'
          mod 'puppetlabs-apache'
          mod 'org-git', git: 'g', tag: 'v1'
        PF
        result = described_class.load_file(path)
        expect(result.exists?).to be true
        expect(result.modules.map(&:version)).to eq(['9.4.0', '7.0.0', nil, nil])
        expect(result.modules.map(&:path)).to eq(%w[modules/stdlib modules/concat modules/apache modules/git])
      end
    end

    it 'defaults version to nil when a Module is built without one' do
      m = described_class::Module.new(name: 'a', path: 'modules/a', git: 'g', ref: 'v1', ref_type: 'tag', default_branch: nil)
      expect(m.version).to be_nil
    end
  end
end
