require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'json'

require 'driftless/module_proposal'

RSpec.describe Driftless::ModuleProposal do
  def git(dir, *args)
    system('git', '-C', dir, '-c', 'user.name=t', '-c', 'user.email=t@example.com', *args, exception: true)
  end

  def metadata(dir, name, version)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, 'metadata.json'), JSON.generate('name' => name, 'version' => version))
  end

  # A module repo tagged v1 at version 1.0.0 and v2 at 2.0.0.
  def upstream(dir, name)
    metadata(dir, name, '1.0.0')
    git(dir, 'init', '-q', '-b', 'main')
    git(dir, 'add', '.')
    git(dir, 'commit', '-q', '-m', 'one')
    git(dir, 'tag', 'v1')
    metadata(dir, name, '2.0.0')
    git(dir, 'commit', '-q', '-am', 'two')
    git(dir, 'tag', 'v2')
    dir
  end

  # stdlib and concat deployed at v1; forge a Forge module on disk at 1.0.0.
  def control_repo(dir)
    File.write(File.join(dir, 'hiera.yaml'), "---\nversion: 5\nhierarchy: []\n")
    File.write(File.join(dir, 'environment.conf'), "modulepath = modules\n")
    up = File.join(dir, 'up')
    %w[stdlib concat extra].each { |m| upstream(File.join(up, m), "org-#{m}") }
    FileUtils.mkdir_p(File.join(dir, 'modules'))
    %w[stdlib concat].each do |m|
      git(File.join(dir, 'modules'), 'clone', '-q', File.join(up, m), File.join(dir, 'modules', m))
      git(File.join(dir, 'modules', m), 'checkout', '-q', '--detach', 'v1')
    end
    metadata(File.join(dir, 'modules/forge'), 'org-forge', '1.0.0')
    File.write(File.join(dir, 'Puppetfile'), <<~PF)
      mod 'org-stdlib', git: '#{up}/stdlib', tag: 'v1'
      mod 'org-concat', git: '#{up}/concat', tag: 'v1'
      mod 'org-forge', '1.0.0'
    PF
    up
  end

  let(:tmp) { Dir.mktmpdir }

  after(:each) { FileUtils.rm_rf(tmp) }

  it 'keeps metadata for unchanged entries and reads the rest from the remote or the Puppetfile' do
    up = control_repo(tmp)
    proposed = File.join(tmp, 'Puppetfile.new')
    File.write(proposed, <<~PF)
      mod 'org-stdlib', git: '#{up}/stdlib', tag: 'v1'
      mod 'org-concat', git: '#{up}/concat', tag: 'v2'
      mod 'org-extra', git: '#{up}/extra', branch: 'main'
      mod 'org-forge', '3.0.0'
      mod 'org-gone', git: '#{up}/gone', tag: 'v1'
    PF
    remotes  = []
    proposal = described_class.new(Driftless::ModuleInventory.new(tmp), proposed,
                                   remote: ->(url) {
                                     remotes << url
                                     Driftless::GitRemote.new(url, cache_dir: nil)
                                   })
    entries  = proposal.entries
    expect(entries.map(&:path)).to eq(%w[modules/concat modules/extra modules/forge modules/gone modules/stdlib])
    expect(entries.map { |e| e.metadata.version }).to eq(['2.0.0', '2.0.0', '3.0.0', nil, '1.0.0'])
    expect(entries.map(&:deployed)).to eq(%i[unknown unknown unknown unknown match])
    expect(entries.map { |e| e.declared.version }).to eq([nil, nil, '3.0.0', nil, nil])
    expect(remotes).to eq(["#{up}/concat", "#{up}/extra", "#{up}/gone"])
    expect(proposal.warnings).to match([
      'modules/forge: Forge module org-forge 3.0.0: metadata not fetched; its dependencies are unknown',
      a_string_matching(%r{\Amodules/gone: #{Regexp.escape(up)}/gone: git fetch: .*; its version and dependencies are unknown\z}),
    ])
  end

  it 'drops ignored modules by name or path, with or without a Puppetfile' do
    control_repo(tmp)
    inventory = Driftless::ModuleInventory.new(tmp)
    expect(described_class.new(inventory, nil, ignore: ['org-std*', 'modules/forge']).entries.map(&:path)).to eq(['modules/concat'])
    proposed = File.join(tmp, 'Puppetfile.new')
    File.write(proposed, "mod 'org-extra', '1.0.0'\n")
    expect(described_class.new(inventory, proposed, ignore: ['ORG-EXTRA']).entries.map(&:path))
      .to eq(%w[modules/concat modules/forge modules/stdlib])
  end

  it 'raises for a proposed Puppetfile that is absent or does not evaluate' do
    control_repo(tmp)
    inventory = Driftless::ModuleInventory.new(tmp)
    expect { described_class.new(inventory, File.join(tmp, 'nope')).entries }.to raise_error(described_class::Error, /no such file/)
    bad = File.join(tmp, 'bad')
    File.write(bad, "raise 'boom'\n")
    expect { described_class.new(inventory, bad).entries }.to raise_error(described_class::Error, /boom/)
  end
end
