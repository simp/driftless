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

  it 'reads a Puppetfile overlay, taking :branch and warning about the rest' do
    result = load('Branchfile', "mod 'puppetlabs-stdlib', git: 'g', branch: 'main'\nmod 'org-x', git: 'g', tag: 'v1'\nmod 'org-f', '1.0.0'\n")
    expect(result.branches).to eq('puppetlabs-stdlib' => 'main')
    expect(result.warnings.map { |w| w.sub(/\A.*: /, '') }).to eq(['org-x names no :branch; ignored', 'org-f names no :branch; ignored'])
    expect(load('Branchfile', "raise 'boom'\n").error).to include('boom')
  end
end
