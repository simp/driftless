require 'stringio'
require 'tmpdir'
require 'fileutils'
require 'json'

require 'spec_helper'
require 'driftless/cli/modules/resolve'

RSpec.describe Driftless::CLI::Modules::Resolve do
  def metadata(dir, data)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, 'metadata.json'), JSON.generate(data))
  end

  # apache needs stdlib < 9 and concat; nginx needs stdlib < 9; stdlib is
  # 9.4.0 and concat is absent.
  def control_repo(dir)
    File.write(File.join(dir, 'hiera.yaml'), "---\nversion: 5\nhierarchy: []\n")
    File.write(File.join(dir, 'environment.conf'), "modulepath = modules\n")
    metadata(File.join(dir, 'modules/apache'),
             'name' => 'puppetlabs-apache', 'version' => '10.0.0',
             'dependencies' => [{ 'name' => 'puppetlabs/stdlib', 'version_requirement' => '>= 4.0.0 < 9.0.0' },
                                { 'name' => 'puppetlabs/concat', 'version_requirement' => '>= 2.0.0' }])
    metadata(File.join(dir, 'modules/nginx'),
             'name' => 'org-nginx', 'version' => '1.0.0',
             'dependencies' => [{ 'name' => 'puppetlabs/stdlib', 'version_requirement' => '< 9.0.0' }],
             'requirements' => [{ 'name' => 'puppet', 'version_requirement' => '< 8.0.0' }])
    metadata(File.join(dir, 'modules/stdlib'), 'name' => 'puppetlabs-stdlib', 'version' => '9.4.0')
    File.write(File.join(dir, 'Puppetfile'), "mod 'puppetlabs-apache', '10.0.0'\nmod 'puppetlabs-stdlib', '9.4.0'\n")
  end

  # [exit status, stdout]
  def run(argv)
    out      = StringIO.new
    original = $stdout
    $stdout  = out
    status   = nil
    begin
      described_class.new.run(argv)
    rescue SystemExit => e
      status = e.status
    ensure
      $stdout = original
    end
    [status, out.string]
  end

  def cells(output)
    output.lines.map(&:rstrip).reject { |l| l.start_with?('--') }.map { |l| l.split('|', -1).map(&:strip) }
  end

  around(:each) do |ex|
    original = Driftless.instance_variable_get(:@config)
    ex.run
  ensure
    Driftless.instance_variable_set(:@config, original)
  end

  before(:each) { silence_driftless_logger }

  it 'tabulates the conflicts and exits 1' do
    Dir.mktmpdir do |dir|
      control_repo(dir)
      status, out = run(['--no-config', '-d', dir])
      expect(status).to eq(1)
      expect(cells(out)).to eq([
        %w[conflict module subject detail],
        ['missing-dependency', 'puppetlabs-apache', 'puppetlabs/concat', 'needs puppetlabs/concat >= 2.0.0; not on the modulepath'],
        ['dependency-version', 'org-nginx', 'puppetlabs/stdlib', 'needs puppetlabs/stdlib < 9.0.0; modules/stdlib is 9.4.0'],
        ['dependency-version', 'puppetlabs-apache', 'puppetlabs/stdlib', 'needs puppetlabs/stdlib >= 4.0.0 < 9.0.0; modules/stdlib is 9.4.0'],
      ])
    end
  end

  it 'orders columns and sorts rows as asked, from flags or config' do
    Dir.mktmpdir do |dir|
      control_repo(dir)
      status, out = run(['--no-config', '-d', dir, '--order', 'module,subject', '--sort-by', 'module'])
      expect(status).to eq(1)
      expect(cells(out).map { |r| r.first(3) }).to eq([
        %w[module subject conflict],
        ['org-nginx', 'puppetlabs/stdlib', 'dependency-version'],
        ['puppetlabs-apache', 'puppetlabs/concat', 'missing-dependency'],
        ['puppetlabs-apache', 'puppetlabs/stdlib', 'dependency-version'],
      ])

      cfg = File.join(dir, 'driftless.yaml')
      File.write(cfg, "modules:\n  resolve_order: [subject]\n  resolve_sort: [subject, module]\n")
      _, out = run(['-c', cfg, '-d', dir])
      expect(cells(out).map { |r| r.first(2) }).to eq([
        %w[subject conflict],
        ['puppetlabs/concat', 'missing-dependency'],
        ['puppetlabs/stdlib', 'dependency-version'],
        ['puppetlabs/stdlib', 'dependency-version'],
      ])
      expect(cells(out).map { |r| r[2] }).to eq(%w[module puppetlabs-apache org-nginx puppetlabs-apache])

      expect(run(['--no-config', '-d', dir, '--order', 'module,detail']).first).to eq(2)
      expect(run(['--no-config', '-d', dir, '--sort-by', 'module,module']).first).to eq(2)
    end
  end

  it 'exits 0 when the config excludes every conflict' do
    Dir.mktmpdir do |dir|
      control_repo(dir)
      cfg = File.join(dir, 'driftless.yaml')
      File.write(cfg, "modules:\n  exclude_dependencies:\n    - puppetlabs-apache\n  exclude_modules:\n    - org-nginx\n")
      status, out = run(['-c', cfg, '-d', dir])
      expect(status).to eq(0)
      expect(out).to eq("(nothing matches)\n")
    end
  end

  it 'marks what a proposed Puppetfile changes' do
    Dir.mktmpdir do |dir|
      control_repo(dir)
      proposed = File.join(dir, 'Puppetfile.new')
      File.write(proposed, "mod 'puppetlabs-stdlib', '8.6.0'\nmod 'puppetlabs-concat', '9.0.0'\nmod 'org-new', '1.0.0'\n")
      status, out = run(['--no-config', '-d', dir, '--propose', proposed])
      expect(status).to eq(0)
      expect(cells(out)).to eq([
        %w[change conflict module subject detail],
        ['-', 'missing-dependency', 'puppetlabs-apache', 'puppetlabs/concat', 'needs puppetlabs/concat >= 2.0.0; not on the modulepath'],
        ['-', 'dependency-version', 'org-nginx', 'puppetlabs/stdlib', 'needs puppetlabs/stdlib < 9.0.0; modules/stdlib is 9.4.0'],
        ['-', 'dependency-version', 'puppetlabs-apache', 'puppetlabs/stdlib', 'needs puppetlabs/stdlib >= 4.0.0 < 9.0.0; modules/stdlib is 9.4.0'],
      ])
    end
  end

  it 'shows only the rows the filters select, and exits on those alone' do
    Dir.mktmpdir do |dir|
      control_repo(dir)
      status, out = run(['--no-config', '-d', dir, '--conflicts', 'missing-dependency'])
      expect(status).to eq(1)
      expect(cells(out).map { |r| r.first(2) }).to eq([%w[conflict module], %w[missing-dependency puppetlabs-apache]])

      status, out = run(['--no-config', '-d', dir, '--skip-conflicts', 'missing-dependency', '--modules', 'PUPPETLABS-*', '--subjects', '*/stdlib'])
      expect(status).to eq(1)
      expect(cells(out).map(&:first)).to eq(%w[conflict dependency-version])

      status, out = run(['--no-config', '-d', dir, '--skip-conflicts', 'missing-dependency,dependency-version'])
      expect([status, out]).to eq([0, "(nothing matches)\n"])

      status, out = run(['--no-config', '-d', dir, '--subjects', 'nothing'])
      expect([status, out]).to eq([0, "(nothing matches)\n"])
    end
  end

  it 'rejects an unknown conflict kind' do
    Dir.mktmpdir do |dir|
      control_repo(dir)
      status, = run(['--no-config', '-d', dir, '--conflicts', 'missing-deps'])
      expect(status).to eq(2)
    end
  end

  it 'resolves as if ignored modules were removed, with or without a proposal' do
    Dir.mktmpdir do |dir|
      control_repo(dir)
      status, out = run(['--no-config', '-d', dir, '--ignore', 'PUPPETLABS/STDLIB'])
      expect(status).to eq(1)
      expect(cells(out).map { |r| r.first(4) }).to eq([
        %w[change conflict module subject],
        ['+', 'missing-dependency', 'org-nginx', 'puppetlabs/stdlib'],
        ['', 'missing-dependency', 'puppetlabs-apache', 'puppetlabs/concat'],
        ['+', 'missing-dependency', 'puppetlabs-apache', 'puppetlabs/stdlib'],
        ['-', 'dependency-version', 'org-nginx', 'puppetlabs/stdlib'],
        ['-', 'dependency-version', 'puppetlabs-apache', 'puppetlabs/stdlib'],
      ])

      proposed = File.join(dir, 'Puppetfile.new')
      File.write(proposed, "mod 'puppetlabs-concat', '9.0.0'\n")
      status, out = run(['--no-config', '-d', dir, '--propose', proposed, '--ignore', 'modules/nginx,modules/apache'])
      expect(status).to eq(0)
      expect(cells(out).map { |r| r.first(3) }).to eq([
        %w[change conflict module],
        ['-', 'missing-dependency', 'puppetlabs-apache'],
        ['-', 'dependency-version', 'org-nginx'],
        ['-', 'dependency-version', 'puppetlabs-apache'],
      ])
    end
  end

  it 'reports modules the configured Puppet requirement excludes, and refuses one that does not parse' do
    Dir.mktmpdir do |dir|
      control_repo(dir)
      cfg = File.join(dir, 'driftless.yaml')
      File.write(cfg, "modules:\n  requirements:\n    puppet: '>= 8.0.0'\n")
      status, out = run(['-c', cfg, '-d', dir, '--conflicts', 'puppet-version'])
      expect(status).to eq(1)
      expect(cells(out).last).to eq(['puppet-version', 'org-nginx', 'puppet', 'requires puppet < 8.0.0; no version in common with the control repo (>= 8.0.0)'])

      File.write(cfg, "modules:\n  requirements:\n    puppet: banana\n")
      expect(run(['-c', cfg, '-d', dir]).first).to eq(2)
    end
  end

  it 'takes exclusions from flags, added to the config lists' do
    Dir.mktmpdir do |dir|
      control_repo(dir)
      status, out = run(['--no-config', '-d', dir, '--exclude-deps', '*:*/concat', '--exclude-modules', 'org-nginx'])
      expect(status).to eq(1)
      expect(cells(out).map { |r| r.first(2) }).to eq([%w[conflict module], %w[dependency-version puppetlabs-apache]])

      cfg = File.join(dir, 'driftless.yaml')
      File.write(cfg, "modules:\n  exclude_dependencies:\n    - '*:*/concat'\n")
      status, out = run(['-c', cfg, '-d', dir, '--exclude-dependencies', 'puppetlabs-apache:*/stdlib', '--exclude-modules', 'ORG-*'])
      expect([status, out]).to eq([0, "(nothing matches)\n"])
    end
  end

  it 'summarises one row per module with --summary, after the filters' do
    Dir.mktmpdir do |dir|
      control_repo(dir)
      status, out = run(['--no-config', '-d', dir, '--summary'])
      expect(status).to eq(1)
      expect(cells(out)).to eq([
        %w[module missing-dependency dependency-version puppet-version operatingsystem total],
        %w[org-nginx 0 1 0 0 1],
        %w[puppetlabs-apache 1 1 0 0 2],
      ])
      _, out = run(['--no-config', '-d', dir, '--summary', '--skip-conflicts', 'dependency-version'])
      expect(cells(out).map(&:first)).to eq(%w[module puppetlabs-apache])
      _, out = run(['--no-config', '-d', dir, '--summary', '--ignore', 'puppetlabs/stdlib'])
      expect(cells(out).map { |r| [r[0], r[1]] }).to eq([%w[module missing-dependency], %w[org-nginx 1], %w[puppetlabs-apache 2]])
    end
  end

  it 'fails on a proposed Puppetfile that cannot be read' do
    Dir.mktmpdir do |dir|
      control_repo(dir)
      status, = run(['--no-config', '-d', dir, '--propose', File.join(dir, 'nope')])
      expect(status).to eq(2)
    end
  end
end
