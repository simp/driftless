require 'spec_helper'

require 'driftless/detectors/data_legacy_facts'
require 'driftless/models/hiera_data_file_info'
require 'driftless/reported'

RSpec.describe Driftless::Detectors::DataLegacyFacts do
  def hand_corpus(data_files: [])
    Driftless::Corpus.new(
      repo_dir:       nil,
      hiera_tiers:    [],
      puppet_classes: {},
      data_files:     data_files,
      reported:       Driftless::Reported.new(data: {}),
      code_lookup_calls:   [], data_lookup_calls: [],
    )
  end

  def file_info(path: '/tmp/x.yaml', source:)
    Driftless::HieraDataFileInfo.new(path: path, top_level_keys: {}, source: source)
  end

  it 'emits no findings when values interpolate only modern structured facts' do
    df = file_info(source: <<~YAML)
      profile::base::os_family: "%{facts.os.family}"
      profile::base::host:      "%{facts.networking.hostname}"
      literal_value:            "just a string"
    YAML
    expect(described_class.new(hand_corpus(data_files: [df])).call).to be_empty
  end

  it 'flags top-scope legacy fact interpolations in a value' do
    df = file_info(source: <<~YAML)
      profile::base::os: "%{::osfamily}"
    YAML
    findings = described_class.new(hand_corpus(data_files: [df])).call
    expect(findings.size).to eq(1)
    expect(findings.first.path).to eq('/tmp/x.yaml')
    expect(findings.first.line).to eq(1)
    expect(findings.first.meta).to include(
      legacy: 'osfamily', modern: 'os.family', interpolation: '::osfamily'
    )
  end

  it 'ignores structured accessor forms' do
    df = file_info(source: <<~YAML)
      a: "prefix-%{facts.hostname}"
      b: "prefix-%{trusted.hostname}"
    YAML
    expect(described_class.new(hand_corpus(data_files: [df])).call).to be_empty
  end

  it 'reports correct line numbers across a multi-line file' do
    df = file_info(source: <<~YAML)
      # comment on line 1
      a: literal
      b: "another literal"
      c: "%{::osfamily}"
    YAML
    findings = described_class.new(hand_corpus(data_files: [df])).call
    expect(findings.first.line).to eq(4)
  end

  it 'ignores legacy facts quoted in comments' do
    df = file_info(source: <<~YAML)
      # explains %{::osfamily}
      a: "%{facts.os.family}" # was %{::osfamily}
    YAML
    expect(described_class.new(hand_corpus(data_files: [df])).call).to be_empty
  end

  it 'emits multiple findings when multiple legacy facts appear on one line' do
    df = file_info(source: <<~YAML)
      composite: "%{::osfamily}-%{::hostname}"
    YAML
    findings = described_class.new(hand_corpus(data_files: [df])).call
    expect(findings.map { |f| f.meta[:legacy] }).to contain_exactly('osfamily', 'hostname')
  end

  it 'ignores literal keys that merely share a name with a legacy fact' do
    df = file_info(source: <<~YAML)
      osfamily: "not an interpolation"
      profile::base::note: "the fact name is 'osfamily' but this is a literal"
    YAML
    expect(described_class.new(hand_corpus(data_files: [df])).call).to be_empty
  end

  it 'aggregates findings across multiple data files' do
    df1 = file_info(path: '/tmp/a.yaml', source: %(k: "%{::osfamily}"\n))
    df2 = file_info(path: '/tmp/b.yaml', source: %(k: "%{::fqdn}"\n))
    findings = described_class.new(hand_corpus(data_files: [df1, df2])).call
    expect(findings.map(&:path)).to contain_exactly('/tmp/a.yaml', '/tmp/b.yaml')
  end
  it 'flags top-scope legacy fact interpolations' do
    df = file_info(source: <<~YAML)
      profile::base::os:   "%{::osfamily}"
      profile::base::name: "%{::fqdn}"
    YAML
    findings = described_class.new(hand_corpus(data_files: [df])).call
    expect(findings.map { |f| f.meta[:legacy] }).to contain_exactly('osfamily', 'fqdn')
    expect(findings.map { |f| f.meta[:interpolation] }).to contain_exactly('::osfamily', '::fqdn')
  end

  it 'ignores a top-scope variable that is not a legacy fact' do
    df = file_info(source: <<~YAML)
      profile::base::site: "%{::my_site_var}"
    YAML
    expect(described_class.new(hand_corpus(data_files: [df])).call).to be_empty
  end

end
