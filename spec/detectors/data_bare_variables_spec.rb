require 'spec_helper'

require 'driftless/detectors/data_bare_variables'
require 'driftless/models/hiera_data_file_info'
require 'driftless/reported'

RSpec.describe Driftless::Detectors::DataBareVariables do
  def hand_corpus(data_files: [])
    Driftless::Corpus.new(
      repo_dir:       nil,
      hiera_tiers:    [],
      puppet_classes: {},
      data_files:     data_files,
      reported:       Driftless::Reported.new(data: {}),
      code_lookup_calls: [], data_lookup_calls: [],
    )
  end

  def file_info(source:, path: '/tmp/x.yaml')
    Driftless::HieraDataFileInfo.new(path: path, top_level_keys: {}, source: source)
  end

  def flagged(source)
    described_class.new(hand_corpus(data_files: [file_info(source: source)]))
      .call.map { |f| f.meta[:interpolation] }
  end

  it 'flags an unqualified interpolation in a value' do
    expect(flagged(%(k: "%{my_role}"\n))).to eq(['my_role'])
  end

  it 'flags a bare fact name, current or legacy alike' do
    expect(flagged(%(a: "%{kernel}"\nb: "%{osfamily}"\n))).to contain_exactly('kernel', 'osfamily')
  end

  it 'ignores top-scope and class-scoped forms' do
    expect(flagged(%(a: "%{::my_role}"\nb: "%{settings::strict_variables}"\n))).to be_empty
  end

  it 'ignores structured accessors' do
    expect(flagged(%(a: "%{facts.os.family}"\nb: "%{trusted.certname}"\nc: "%{server_facts.environment}"\n)))
      .to be_empty
  end

  it 'ignores Hiera function calls' do
    expect(flagged(%(a: "%{lookup('x')}"\nb: "%{alias('y')}"\n))).to be_empty
  end

  it 'reports the line the interpolation appears on' do
    src = "# comment\nk: \"prefix-%{my_role}-suffix\"\n"
    f = described_class.new(hand_corpus(data_files: [file_info(source: src)])).call.first
    expect(f.line).to eq(2)
    expect(f.path).to eq('/tmp/x.yaml')
  end

  it 'ignores an interpolation in a full-line comment' do
    expect(flagged("# mentions %{my_role}\nk: v\n")).to be_empty
  end

  it 'ignores an interpolation in a trailing comment' do
    expect(flagged(%(k: v # %{my_role}\n))).to be_empty
  end

  it 'ignores an interpolation in a mapping key' do
    expect(flagged(%("%{my_role}": v\n))).to be_empty
  end

  it 'reports the exact line inside a literal block scalar' do
    src = "k: |\n  first\n  %{my_role}\n"
    f = described_class.new(hand_corpus(data_files: [file_info(source: src)])).call.first
    expect(f.line).to eq(3)
  end

  it 'emits one finding per interpolation on a line' do
    expect(flagged(%(k: "%{a_var}-%{b_var}"\n))).to contain_exactly('a_var', 'b_var')
  end

  it 'aggregates across data files' do
    files = [
      file_info(path: '/tmp/a.yaml', source: %(k: "%{one}"\n)),
      file_info(path: '/tmp/b.yaml', source: %(k: "%{two}"\n)),
    ]
    findings = described_class.new(hand_corpus(data_files: files)).call
    expect(findings.map(&:path)).to contain_exactly('/tmp/a.yaml', '/tmp/b.yaml')
  end

  it 'names the offending interpolation in the message' do
    f = described_class.new(hand_corpus(data_files: [file_info(source: %(k: "%{my_role}"\n))])).call.first
    expect(f.message).to include('%{my_role}')
  end

  it 'emits nothing for a file with no interpolations' do
    expect(flagged(%(k: "a literal value"\n))).to be_empty
  end
end
