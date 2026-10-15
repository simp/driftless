require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'json'

require 'driftless/module_inventory'

RSpec.describe Driftless::ModuleInventory do
  def git(dir, *args)
    system('git', '-C', dir, '-c', 'user.name=t', '-c', 'user.email=t@example.com', *args, exception: true)
  end

  def metadata(dir, name, version: '1.0.0')
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, 'metadata.json'), JSON.generate(
      'name' => name, 'version' => version,
      'requirements' => [{ 'name' => 'puppet', 'version_requirement' => '>= 7.0.0 < 9.0.0' }],
    ))
  end

  # A module repo: metadata.json committed and tagged v1, then a second commit.
  def upstream(dir, name)
    metadata(dir, name)
    git(dir, 'init', '-q', '-b', 'main')
    git(dir, 'add', '.')
    git(dir, 'commit', '-q', '-m', 'one')
    git(dir, 'tag', 'v1')
    git(dir, 'commit', '-q', '--allow-empty', '-m', 'two')
    dir
  end

  def deploy(upstream, dir, at: nil)
    FileUtils.mkdir_p(File.dirname(dir))
    git(File.dirname(dir), 'clone', '-q', upstream, dir)
    git(dir, 'checkout', '-q', '--detach', at) if at
  end

  # stdlib deployed at its tag; apache deployed at v1 while declared main;
  # stale deployed from stdlib while declared at a tag it does not have;
  # missing declared but not deployed; forge a Forge entry on disk at its
  # version and oldforge one at an earlier version; tenant
  # at :control_branch under install_path; profile on disk, undeclared.
  def control_repo(dir)
    File.write(File.join(dir, 'hiera.yaml'), "---\nversion: 5\nhierarchy: []\n")
    File.write(File.join(dir, 'environment.conf'), "modulepath = site-modules:modules\n")
    up = File.join(dir, 'up')
    deploy(upstream(File.join(up, 'stdlib'), 'puppetlabs-stdlib'), File.join(dir, 'modules/stdlib'), at: 'v1')
    deploy(upstream(File.join(up, 'apache'), 'puppetlabs-apache'), File.join(dir, 'modules/apache'), at: 'v1')
    deploy(File.join(up, 'stdlib'), File.join(dir, 'modules/stale'), at: 'v1')
    deploy(upstream(File.join(up, 'tenant'), 'org-tenant'), File.join(dir, 'data/tenant'))
    metadata(File.join(dir, 'modules/forge'), 'org-forge', version: '2.0.0')
    metadata(File.join(dir, 'modules/oldforge'), 'org-oldforge', version: '1.0.0')
    FileUtils.mkdir_p(File.join(dir, 'site-modules/profile'))
    File.write(File.join(dir, 'Puppetfile'), <<~PF)
      mod 'puppetlabs-stdlib', git: '#{up}/stdlib', tag: 'v1'
      mod 'puppetlabs-apache', git: '#{up}/apache', branch: 'main'
      mod 'org-missing', git: '#{up}/missing', ref: 'v1'
      mod 'org-stale', git: '#{up}/stdlib', tag: 'v9'
      mod 'org-forge', '2.0.0'
      mod 'org-oldforge', '2.0.0'
      mod 'org-tenant', git: '#{up}/tenant', branch: :control_branch, default_branch: 'main', install_path: './data'
    PF
  end

  let(:tmp) { Dir.mktmpdir }

  after(:each) { FileUtils.rm_rf(tmp) }

  it 'joins the modulepath directories with the Puppetfile entries by deploy path' do
    control_repo(tmp)
    inventory = described_class.new(tmp)
    entries   = inventory.entries
    expect(inventory.warnings).to eq([])
    expect(entries.map(&:path)).to eq(%w[data/tenant modules/apache modules/forge modules/missing modules/oldforge modules/stale
                                         modules/stdlib site-modules/profile])
    expect(entries.map { |e| e.declared&.name })
      .to eq(['org-tenant', 'puppetlabs-apache', 'org-forge', 'org-missing', 'org-oldforge', 'org-stale', 'puppetlabs-stdlib', nil])
    expect(entries.map { |e| e.metadata.name })
      .to eq(['org-tenant', 'puppetlabs-apache', 'org-forge', nil, 'org-oldforge', 'puppetlabs-stdlib', 'puppetlabs-stdlib', nil])
    expect(entries.map(&:deployed)).to eq(%i[match differ match absent differ unknown match unknown])
    expect(entries.map(&:found)).to eq([nil, 'v1', nil, nil, '1.0.0', nil, nil, nil])
  end

  it 'finds a module by path, declared name, or metadata name, in either spelling' do
    control_repo(tmp)
    inventory = described_class.new(tmp)
    expect(inventory.find('modules/stdlib')&.path).to eq('modules/stdlib')
    expect(inventory.find('puppetlabs/stdlib')&.path).to eq('modules/stdlib')
    expect(inventory.find('PUPPETLABS-STDLIB')&.path).to eq('modules/stdlib')
    expect(inventory.find('org-stale')&.path).to eq('modules/stale')
    expect(inventory.find('stdlib')&.path).to eq('modules/stdlib')
    expect(inventory.find('nope')).to be_nil
  end

  it 'lists the modulepath directories with a warning when the Puppetfile does not evaluate' do
    control_repo(tmp)
    File.write(File.join(tmp, 'Puppetfile'), "raise 'boom'\n")
    inventory = described_class.new(tmp)
    expect(inventory.entries.map(&:path)).to eq(%w[modules/apache modules/forge modules/oldforge modules/stale modules/stdlib site-modules/profile])
    expect(inventory.entries.map(&:deployed).uniq).to eq([:unknown])
    expect(inventory.warnings).to eq(['Puppetfile: RuntimeError: boom'])
  end
end
