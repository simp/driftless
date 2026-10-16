require 'spec_helper'
require 'tmpdir'

require 'driftless/inputs/branchfile'

RSpec.describe Driftless::Inputs::Branchfile do
  def load(name, contents)
    Dir.mktmpdir do |dir|
      path = File.join(dir, name)
      File.write(path, contents) if contents
      return described_class.load(path)
    end
  end

  it 'reports an absent file' do
    result = load('branches.yaml', nil)
    expect(result.exists?).to be false
    expect(result.branch_for('stdlib')).to be_nil
  end

  it 'reads a YAML mapping, matching names in either spelling or by last segment' do
    result = load('branches.yaml', "puppetlabs/stdlib: main\nconcat: develop\n")
    expect(result.error).to be_nil
    expect(result.branch_for('puppetlabs-stdlib')).to eq('main')
    expect(result.branch_for('PUPPETLABS/STDLIB')).to eq('main')
    expect(result.branch_for('stdlib')).to eq('main')
    expect(result.branch_for('puppetlabs-concat')).to eq('develop')
    expect(result.branch_for('apache')).to be_nil
    expect(load('b.yml', "- a\n").error).to include('expected a mapping')
    expect(load('b.yml', "a: [\n").error).not_to be_nil
  end

  it 'records a branch in a YAML file, creating or replacing as needed' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'branches.yaml')
      described_class.record(path, 'puppetlabs-stdlib', 'main')
      File.write(path, File.read(path) + "concat: develop\n")
      described_class.record(path, 'puppetlabs/stdlib', 'next')
      expect(YAML.safe_load(File.read(path))).to eq('concat' => 'develop', 'puppetlabs/stdlib' => 'next')
      File.write(path, "- a\n")
      expect { described_class.record(path, 'x', 'y') }.to raise_error(described_class::Error, /expected a mapping/)
    end
  end

  it 'records a branch in a Puppetfile overlay, replacing one mod line or appending' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'Branchfile')
      File.write(path, "# keep me\nmod 'puppetlabs/stdlib', git: 'g', branch: 'main'\nmod 'org-x', :branch => 'dev'\n")
      described_class.record(path, 'puppetlabs-stdlib', 'next')
      described_class.record(path, 'org-new', 'main')
      expect(File.read(path)).to eq("# keep me\nmod 'puppetlabs-stdlib', :branch => 'next'\nmod 'org-x', :branch => 'dev'\nmod 'org-new', :branch => 'main'\n")
      expect(described_class.load(path).branches).to eq('puppetlabs-stdlib' => 'next', 'org-x' => 'dev', 'org-new' => 'main')
    end
  end

  it 'reads a Puppetfile overlay, taking :branch and warning about the rest' do
    result = load('Branchfile', "mod 'puppetlabs-stdlib', git: 'g', branch: 'main'\nmod 'org-x', git: 'g', tag: 'v1'\nmod 'org-f', '1.0.0'\n")
    expect(result.branches).to eq('puppetlabs-stdlib' => 'main')
    expect(result.warnings.map { |w| w.sub(/\A.*: /, '') }).to eq(['org-x names no :branch; ignored', 'org-f names no :branch; ignored'])
    expect(load('Branchfile', "raise 'boom'\n").error).to include('boom')
  end
end
