require 'spec_helper'
require 'tmpdir'

require 'pupgrade/compile/enc'
require 'pupgrade/compile/factset'

RSpec.describe Pupgrade::Compile::Enc do
  let(:dir) { Dir.mktmpdir }

  after(:each) { FileUtils.rm_rf(dir) }

  def factset(certname, facts)
    Pupgrade::Compile::Factset.new(certname: certname, values: facts, trusted: { 'extensions' => { 'pp_role' => 'db' } },
                                   trusted_external: {}, path: "#{certname}.json")
  end

  def write(name, text)
    File.write(File.join(dir, name), text)
    File.join(dir, name)
  end

  before(:each) { silence_logger }

  it 'applies the rules in order, later assignments winning, with globs, fact values, and interpolation' do
    yaml = write('enc.yaml', <<~YAML)
      rules:
        - set:
            role: role::base
            family: '${facts.os.family}'
        - when:
            certname: 'pup*'
          set:
            role: role::puppetserver
          classes: [profile::puppetserver]
        - when:
            facts.os.family: [RedHat, Rocky]
          set:
            site: '${certname[/\\A[^.]+\\.([^.]+)\\./, 1]}'
            ext: '${trusted.extensions.pp_role}'
            via: '${vars.role}'
          classes: [profile::el, profile::puppetserver]
    YAML
    enc = described_class.load(yaml, nil, vars: { 'tenant' => 'blue', 'role' => 'overridden' })
    node = enc.resolve(factset('pup1.b.example.tld', 'os' => { 'family' => 'RedHat' }))
    expect(node.vars).to eq('tenant' => 'blue', 'role' => 'role::puppetserver', 'family' => 'RedHat', 'site' => 'b', 'ext' => 'db',
                            'via' => 'role::puppetserver')
    expect(node.classes).to eq(%w[profile::puppetserver profile::el])
    expect(node.fact('os.family')).to eq('RedHat')
    expect(node['site']).to eq('b')

    allow(Driftless).to receive(:logger).and_call_original
    log = capture_log(level: :info) { node = enc.resolve(factset('web01.example.com', 'os' => { 'family' => 'Debian' })) }
    expect(log).to include("info: enc: web01.example.com: variables #{{ 'tenant' => 'blue', 'role' => 'role::base', 'family' => 'Debian' }.inspect}\n")
    expect(log).not_to include('; classes')
    expect(node.vars).to eq('tenant' => 'blue', 'role' => 'role::base', 'family' => 'Debian')
    expect(node.classes).to eq([])
    expect(enc.empty?).to be(false)
    expect(described_class.load(nil, nil).empty?).to be(true)
  end

  it 'lets the Ruby file decide variables, classes, and mock answers with the node in hand' do
    yaml = write('enc.yaml', "rules:\n  - set: { site: '${certname[/\\.([a-z])\\./, 1]}' }\n")
    ruby = write('compiler.rb', <<~RUBY)
      variable(:tenant) { |node| { 'b' => 'blue', 'g' => 'green' }[node['site']] }
      variable(:untouched) { |_node| nil }
      classes { |node| ['profile::el'] if node.fact('os.family') == 'RedHat' }
      mock(/\\Arpm -q (\\S+)\\z/) { |node, m| node.fact('os.family') == 'RedHat' ? "\#{m[1]}-1.0\\n" : nil }
      fact('os.selinux.enabled') { |node| false if node.fact('os.family') == 'RedHat' }
    RUBY
    enc  = described_class.load(yaml, ruby)
    node = enc.resolve(factset('pup1.g.example.tld', 'os' => { 'family' => 'RedHat' }))
    expect(node.vars).to eq('site' => 'g', 'tenant' => 'green')
    expect(node.classes).to eq(['profile::el'])
    expect(enc.ruby.mocks.size).to eq(1)
    pattern, block = enc.ruby.mocks.first
    expect(block.call(node, pattern.match('rpm -q bash'))).to eq("bash-1.0\n")
    other = enc.resolve(factset('web01.example.com', 'os' => { 'family' => 'Debian' }))
    expect(other.vars).to eq('site' => '')
    expect(block.call(other, pattern.match('rpm -q bash'))).to be_nil
    path, fact = enc.ruby.facts.first
    expect([path, fact.call(node), fact.call(other)]).to eq(['os.selinux.enabled', false, nil])
    expect { described_class::Rules.new.fact('x') }.to raise_error(described_class::Error, /needs a block/)
  end

  it 'refuses files that do not read as rules' do
    expect { described_class.load(write('x.yaml', "- not: a mapping\n"), nil) }.to raise_error(described_class::Error, /expected a mapping/)
    expect { described_class.load(write('y.yaml', "rules:\n  - sets: {}\n"), nil) }.to raise_error(described_class::Error, /unknown key "sets"/)
    expect { described_class.load(write('z.yaml', "rules:\n  - set: { a: '${nope.x}' }\n"), nil).resolve(factset('n', {})) }
      .to raise_error(described_class::Error, /references start with/)
    expect { described_class.load(nil, write('bad.rb', "variable(:x)\n")) }.to raise_error(described_class::Error, /needs a block/)
    expect { described_class.load(nil, write('boom.rb', "raise 'no'\n")) }.to raise_error(described_class::Error, /boom.rb: RuntimeError: no/)
    expect { described_class.load(File.join(dir, 'missing.yaml'), nil) }.to raise_error(described_class::Error, /no such file/)
  end
end
