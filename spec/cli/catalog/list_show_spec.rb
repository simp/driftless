require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'stringio'
require 'json'

require 'support/fixture_repo'
require 'pupgrade/cli/catalog'

# `catalog list`, `catalog show`, and `catalog resources` over one compile of the fixture.
RSpec.describe Pupgrade::CLI::Catalog do
  def self.silently
    captured = StringIO.new
    original = $stdout
    $stdout  = captured
    yield
  rescue SystemExit
    nil
  ensure
    $stdout = original
  end

  before(:all) do # rubocop:disable RSpec/BeforeAfterAll
    @tmp      = Dir.mktmpdir
    @fixture  = Pupgrade::FixtureRepo.build(File.join(@tmp, 'repo'))
    @catalogs = File.join(@tmp, 'catalogs')
    self.class.silently { Pupgrade::CLI::Catalog::Compile.new.run(['--no-config', '-d', @fixture.dir, '--factsets', 'factsets', '-o', @catalogs, '--mocks', 'pupgrade/compiler/mocks.yaml']) }
  end

  after(:all) { FileUtils.rm_rf(@tmp) } # rubocop:disable RSpec/BeforeAfterAll

  let(:fixture) { @fixture }

  # [exit status, stdout] of a subcommand run on its own
  def run(argv)
    klass = { 'list' => described_class::List, 'ls' => described_class::List, 'show' => described_class::Show, 'resources' => described_class::Resources }.fetch(argv.first)
    captured = StringIO.new
    original = $stdout
    $stdout  = captured
    status   = nil
    begin
      klass.new.run(['--no-config', '-d', fixture.dir] + argv.drop(1))
    rescue SystemExit => e
      status = e.status
    ensure
      $stdout = original
    end
    [status, captured.string]
  end

  def cells(output)
    output.lines.map(&:rstrip).reject { |l| l.start_with?('--') }.map { |l| l.split('|', -1).map(&:strip) }
  end

  before(:each) { silence_logger }

  it 'lists the compiled nodes with their counts' do
    status, out = run(['list', '--cache-dir', @catalogs])
    expect(status).to eq(0)
    table = cells(out)
    expect(table.first).to eq(%w[certname resources classes warnings mocks leaks missing status compiled])
    expect(table.drop(1).map(&:first)).to eq(%w[db01.example.com web01.example.com])
    expect(table[1][7]).to eq('ok')
    expect(table[1][1].to_i).to be > 0
    expect(table.find { |r| r.first == 'web01.example.com' }.values_at(4, 5, 6)).to eq(%w[1 0 0])
    _, out = run(['ls', '--cache-dir', @catalogs, '--certname', 'web*'])
    expect(cells(out).drop(1).map(&:first)).to eq(['web01.example.com'])
    _, out = run(['ls', '--cache-dir', @catalogs, '--certname', '!web*'])
    expect(cells(out).drop(1).map(&:first)).to eq(['db01.example.com'])
    expect(run(['list', '--cache-dir', File.join(@tmp, 'nope')]).first).to eq(3)
  end

  it 'lists the nodes in the order compile ran their factsets' do
    cache = File.join(@tmp, 'ordered')
    { 'a.example.com' => 'factsets/z/a.json', 'b.example.com' => 'factsets/m/b.json', 'c.example.com' => 'factsets/m/a.json' }.each do |name, factset|
      FileUtils.mkdir_p(File.join(cache, name))
      File.write(File.join(cache, name, 'compile.json'), JSON.generate('document' => 'compile', 'schema_version' => 3, 'status' => 'ok', 'factset' => factset))
    end
    _, out = run(['list', '--cache-dir', cache])
    expect(cells(out).drop(1).map(&:first)).to eq(%w[c.example.com b.example.com a.example.com])
  end

  it 'shows a catalog, a part of it by key path, its keys, and the probes' do
    status, out = run(['show', '--cache-dir', @catalogs, 'web01.example.com'])
    expect(status).to eq(0)
    doc = JSON.parse(out)
    expect(doc['name']).to eq('web01.example.com')

    _, out = run(['show', '--cache-dir', @catalogs, 'resources[0].type', 'web01.example.com'])
    expect(JSON.parse(out)).to eq(doc['resources'][0]['type'])
    _, out = run(['show', '--cache-dir', @catalogs, '-k', '.', 'web01.example.com'])
    expect(JSON.parse(out)).to include('resources', 'classes')
    _, out = run(['show', '--cache-dir', @catalogs, '-k', 'resources', 'web01.example.com'])
    expect(JSON.parse(out)).to eq("#{doc['resources'].size} entries")
    _, out = run(['show', '--cache-dir', @catalogs, '--render-as', 'yaml', 'classes', '*'])
    both = YAML.safe_load(out)
    expect(both.keys).to eq(%w[db01.example.com web01.example.com])
    _, out = run(['show', '--cache-dir', @catalogs, '-p', 'status', 'web01*'])
    expect(JSON.parse(out)).to eq('ok')
    _, out = run(['show', '--cache-dir', @catalogs, '-p', 'mocks[0].command', 'web01*'])
    expect(JSON.parse(out)).to eq('hostname -f')
    _, out = run(['show', '--cache-dir', @catalogs, 'resources[concat::fragment[motd]].type', 'web01.example.com'])
    expect(JSON.parse(out)).to eq('Concat::Fragment')
    _, out = run(['show', '--cache-dir', @catalogs, 'resources[Class[*]]', 'web01.example.com'])
    expect(JSON.parse(out).map { |r| r['type'] }.uniq).to eq(['Class'])
    expect(run(['show', '--cache-dir', @catalogs, 'resources[File[/no/such]]', 'web01.example.com']).first).to eq(1)
    expect(run(['show', '--cache-dir', @catalogs, 'resources[motd]', 'web01.example.com']).first).to eq(1)

    expect(run(['show', '--cache-dir', @catalogs, 'nothing.here', 'web01.example.com']).first).to eq(1)
    expect(run(['show', '--cache-dir', @catalogs, 'nobody']).first).to eq(3)
    expect(run(['show']).first).to eq(2)
  end

  it 'walks a key path whose resource titles hold dots and brackets' do
    doc  = { 'resources' => [{ 'type' => 'File', 'title' => '/etc/modprobe.d/a.conf', 'tags' => ['x'] },
                             { 'type' => 'File', 'title' => '/etc/x[1]', 'tags' => ['y'] }] }
    show = described_class::Show.new
    expect(show.send(:walk, doc, 'resources[File[/etc/modprobe.d/a.conf]].tags[0]')).to eq('x')
    expect(show.send(:walk, doc, 'resources[File[/etc/x[1]]].tags')).to eq(['y'])
    expect(show.send(:walk, doc, 'resources[File[*modprobe*]]').size).to eq(1)
    expect { show.send(:walk, doc, 'resources[File[/etc') }.to raise_error(KeyError, /not closed/)
  end

  it 'lists resources by type and title glob across nodes, shows one whole, and exits 1 when none matches' do
    status, out = run(['resources', '--cache-dir', @catalogs, 'web01.example.com'])
    expect(status).to eq(0)
    table = cells(out)
    expect(table.first).to eq(%w[certname type title source])
    expect(table.drop(1).map { |r| r[1] }).to include('Class', 'Notify')
    _, out = run(['resources', '--cache-dir', @catalogs, 'notify', '*'])
    rows = cells(out).drop(1)
    expect(rows.map(&:first).uniq).to eq(%w[db01.example.com web01.example.com])
    expect(rows.map { |r| r[1] }.uniq).to eq(['Notify'])
    expect(rows.first.last).to match(/\A(site-modules|modules)\/.*\.pp:\d+\z/)
    title = rows.first[2]
    status, out = run(['resources', '--cache-dir', @catalogs, 'NOTIFY', title, 'web01.example.com', '--full'])
    expect(status).to eq(0)
    doc = JSON.parse(out)
    expect(doc.map { |r| [r['type'], r['title'], r['certname']] }).to eq([['Notify', title, 'web01.example.com']])
    _, out = run(['resources', '--cache-dir', @catalogs, 'notify', "#{title[0, 3]}*", 'web01.example.com', '--params'])
    expect(cells(out).first).to eq(%w[certname type title parameters])
    expect(cells(out)[1].last).to include('message')
    _, out = run(['resources', '--cache-dir', @catalogs, "Notify[#{title}]", 'web01.example.com'])
    expect(cells(out).drop(1).map { |r| r[0, 3] }).to eq([['web01.example.com', 'Notify', title]])
    _, out = run(['resources', '--cache-dir', @catalogs, '*not*', 'web01.example.com'])
    expect(cells(out).drop(1).map { |r| r[1] }.uniq).to eq(['Notify'])
    _, out = run(['resources', '--cache-dir', @catalogs, "*ify[#{title[0, 3]}*]", 'web01.example.com'])
    expect(cells(out).drop(1).map { |r| r[0, 3] }).to eq([['web01.example.com', 'Notify', title]])
    # certname magenta, a type cyan, Class dim, the source file cyan with its line dim
    _, out = run(['resources', '--cache-dir', @catalogs, '--color', '--width', '0', 'web01.example.com'])
    lines = out.lines.map(&:chomp)
    expect(lines.find { |l| l.include?('Notify') }).to match(%r{\A\e\[0;35mweb01\.example\.com\e\[0m +\| \e\[0;36mNotify\e\[0m +\| .+\| \e\[0;36m\S+\.pp\e\[0m\e\[2m:\d+\e\[0m\z})
    expect(lines.find { |l| l.include?('Class') }).to include("| \e[2mClass\e[0m")
    expect(run(['resources', '--cache-dir', @catalogs, 'file', '/no/such', 'web01.example.com']).first).to eq(1)
    expect(run(['resources', '--cache-dir', @catalogs, 'nobody']).first).to eq(3)
    expect(run(['resources', '--cache-dir', @catalogs, 'a', 'b', 'c', 'd']).first).to eq(2)
  end
end
