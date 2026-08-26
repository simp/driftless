require 'spec_helper'

require 'driftless/detectors/data_lookup_missing_hiera_keys'
require 'driftless/models/hiera_data_file_info'
require 'driftless/models/lookup_call'

RSpec.describe Driftless::Detectors::DataLookupMissingHieraKeys do
  let(:default_yaml) do
    Driftless::HieraDataFileInfo.new(
      path: '/tmp/default.yaml',
      top_level_keys: {
        'profile::web::vhost' => 2,
        'namespace::defined'  => 3,
      },
    )
  end

  it 'flags YAML interpolations for keys not defined anywhere in Hiera' do
    calls = [
      Driftless::LookupCall.new(key: 'namespace::defined',  file: '/tmp/a.yaml', line: 4,  has_default: false),
      Driftless::LookupCall.new(key: 'never::defined::key', file: '/tmp/a.yaml', line: 8,  has_default: false),
    ]
    corpus   = build_corpus(data_files: [default_yaml], data_lookup_calls: calls)
    findings = described_class.new(corpus).call
    expect(findings.map { |f| f.meta[:lookup_key] }).to eq(['never::defined::key'])
    expect(findings.first.path).to eq('/tmp/a.yaml')
    expect(findings.first.line).to eq(8)
  end

  it 'names the function in the message and meta' do
    calls = [Driftless::LookupCall.new(key: 'missing', function: 'alias', file: '/tmp/x.yaml', line: 1,
                                       has_default: false)]
    corpus   = build_corpus(data_files: [default_yaml], data_lookup_calls: calls)
    findings = described_class.new(corpus).call
    expect(findings.first.message).to eq('"missing" not defined in any Hiera file (via alias)')
    expect(findings.first.meta[:function]).to eq('alias')
  end

  it 'does NOT include has_default in meta (data-side interpolations cannot carry defaults)' do
    calls = [Driftless::LookupCall.new(key: 'missing', file: '/tmp/x.yaml', line: 1, has_default: false)]
    corpus   = build_corpus(data_files: [default_yaml], data_lookup_calls: calls)
    findings = described_class.new(corpus).call
    expect(findings.first.meta.keys).to eq(%i[lookup_key function])
  end

  it 'is scoped to data_lookup_calls only — code_lookup_calls do not appear here' do
    code_call = Driftless::LookupCall.new(key: 'code::only', file: 'main.pp', line: 1, has_default: false)
    corpus    = build_corpus(data_files: [default_yaml], code_lookup_calls: [code_call])
    findings  = described_class.new(corpus).call
    expect(findings).to be_empty
  end

  it 'emits per-call (not deduplicated) so multiple interpolations of the same missing key each get reported' do
    calls = [
      Driftless::LookupCall.new(key: 'missing', file: '/tmp/a.yaml', line: 2, has_default: false),
      Driftless::LookupCall.new(key: 'missing', file: '/tmp/b.yaml', line: 4, has_default: false),
    ]
    corpus   = build_corpus(data_files: [default_yaml], data_lookup_calls: calls)
    findings = described_class.new(corpus).call
    expect(findings.length).to eq(2)
    expect(findings.map { |f| [f.path, f.line] }).to contain_exactly(['/tmp/a.yaml', 2], ['/tmp/b.yaml', 4])
  end
end
