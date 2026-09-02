require 'fileutils'
require 'json'
require 'stringio'
require 'tmpdir'

require 'spec_helper'
require 'driftless/cli/report'

RSpec.describe Driftless::CLI::Report do
  before(:each) { Driftless.config = Driftless::Config.new(merged: {}) }

  def write_report(dir, report, collector, session, rows)
    report_dir = File.join(dir, report)
    FileUtils.mkdir_p(report_dir)
    File.write(File.join(report_dir, "#{collector}--#{session}.json"), JSON.generate(rows))
  end

  def nodes_row(certname, env: 'production')
    { 'certname' => certname, 'catalog_environment' => env }
  end

  def class_row(certname, title, env: 'production')
    { 'certname' => certname, 'title' => title, 'environment' => env }
  end

  def build_fleet_fixture(dir)
    write_report(dir, 'all-active-nodes', 'east', 'T01',
                 [nodes_row('web1'), nodes_row('web2')])
    write_report(dir, 'all-active-nodes', 'west', 'T01',
                 [nodes_row('db1', env: 'staging')])
    write_report(dir, 'classes-for-all-active-nodes', 'east', 'T01',
                 [class_row('web1', 'Profile::Web'), class_row('web2', 'Profile::Web'),
                  class_row('web2', 'Role::Web')])
    write_report(dir, 'classes-for-all-active-nodes', 'west', 'T01',
                 [class_row('db1', 'Profile::Db', env: 'staging')])
  end

  # Runs execute (not run, so @options stand in for parsed flags), capturing
  # [exit status, stdout].
  def run_cli(argv = [], **options)
    cli = described_class.new(parent_options: {})
    cli.instance_variable_set(:@options, { environments: %w[production staging] }.merge(options))
    status = nil
    out    = StringIO.new
    err    = StringIO.new
    orig_out = $stdout
    orig_err = $stderr
    $stdout = out
    $stderr = err
    begin
      cli.execute(argv)
    rescue SystemExit => e
      status = e.status
    ensure
      $stdout = orig_out
      $stderr = orig_err
    end
    [status, out.string]
  end

  def run_cli_on_fleet_fixture(argv = [], **options)
    Dir.mktmpdir do |dir|
      build_fleet_fixture(dir)
      return run_cli(argv, incoming_dir: dir, **options)
    end
  end

  it 'prints all four category tables by default and exits 0' do
    status, out = run_cli_on_fleet_fixture
    expect(status).to eq(0)
    expect(out.lines.map(&:chomp)).to include('modules', 'roles', 'profiles', 'classes')
    expect(out).to match(/^  profile::web \| {5}2$/)
  end

  it 'narrows to the categories given, prefix-matched' do
    status, out = run_cli_on_fleet_fixture(['rol'])
    expect(status).to eq(0)
    expect(out).to include('roles')
    expect(out).not_to include('profiles')
  end

  it 'rejects an unknown category' do
    status = nil
    log = capture_log { status, = run_cli_on_fleet_fixture(['bogus']) }
    expect(status).to eq(2)
    expect(log).to include('does not match')
  end

  it 'adds breakdown columns for --group-by collector' do
    _status, out = run_cli_on_fleet_fixture(['classes'], group_by: ['collector'])
    expect(out).to match(/^  class {8}\| nodes \| east \| west$/)
    expect(out).to match(/^  profile::web \| {5}2 \| {4}2 \| {4}0$/)
  end

  it 'resolves a --group-by prefix (env)' do
    _status, out = run_cli_on_fleet_fixture(['classes'], group_by: ['env'])
    expect(out).to include('production').and include('staging')
  end

  it 'accepts both group-bys at once' do
    _status, out = run_cli_on_fleet_fixture(['classes'], group_by: %w[coll env])
    expect(out).to match(/east \| west \| production \| staging$/)
  end

  it 'rejects an unresolvable --group-by term' do
    status = nil
    log = capture_log { status, = run_cli_on_fleet_fixture([], group_by: ['bogus']) }
    expect(status).to eq(2)
    expect(log).to include('--group-by')
  end

  it 'sorts by node count, reversed, with --sort-by number:reversed' do
    _status, out = run_cli_on_fleet_fixture(['classes'], sort_by: 'number:reversed')
    names = out.lines.grep(/::/).map { |l| l.split('|').first.strip }
    expect(names.first).to eq('profile::web')
  end

  it 'resolves --sort-by prefixes (num:rev)' do
    _status, out = run_cli_on_fleet_fixture(['classes'], sort_by: 'num:rev')
    expect(out.lines.grep(/::/).first).to include('profile::web')
  end

  it 'shows only names matching any --show regex' do
    _status, out = run_cli_on_fleet_fixture(['classes'], show: ['db', '/role/'])
    expect(out).to include('profile::db').and include('role::web')
    expect(out).not_to include('profile::web')
  end

  it 'rejects an invalid --show regex' do
    status, = run_cli_on_fleet_fixture([], show: ['('])
    expect(status).to eq(2)
  end

  it 'filters rows by --show-count' do
    _status, out = run_cli_on_fleet_fixture(['classes'], show_count: '>1')
    expect(out).to include('profile::web')
    expect(out).not_to include('role::web')
  end

  it 'prints (nothing matches) when a filter empties a table' do
    _status, out = run_cli_on_fleet_fixture(['classes'], show_count: '>99')
    expect(out).to include('(nothing matches)')
  end

  it 'rejects an unparseable --show-count' do
    status, = run_cli_on_fleet_fixture([], show_count: 'lots')
    expect(status).to eq(2)
  end

  it 'writes the report document when data_file is set' do
    Dir.mktmpdir do |dir|
      build_fleet_fixture(dir)
      out_path = File.join(dir, 'out', 'report.json')
      status, = run_cli(['classes'], incoming_dir: dir, data_file: out_path)
      expect(status).to eq(0)
      data = JSON.parse(File.read(out_path))
      expect(data['document']).to eq('report')
      expect(data['utilization']['classes'])
        .to include(hash_including('name' => 'profile::web', 'nodes' => 2))
      expect(data['nodes']['total']).to eq(3)
      expect(data['sessions'].map { |s| s['collector'] }).to eq(%w[east west])
    end
  end

  it 'fatals on a tree without the classes report' do
    Dir.mktmpdir do |dir|
      write_report(dir, 'all-active-nodes', 'east', 'T01', [nodes_row('web1')])
      status = nil
      log = capture_log do
        status, = run_cli([], incoming_dir: dir, environments: ['production'])
      end
      expect(status).to eq(2)
      expect(log).to include('classes-for-all-active-nodes')
    end
  end

  it 'requires puppet.environments' do
    status = nil
    log = capture_log { status, = run_cli_on_fleet_fixture([], environments: nil) }
    expect(status).to eq(2)
    expect(log).to include('puppet.environments')
  end

  it 'exits 3 on an unreadable incoming dir' do
    status = nil
    log = capture_log { status, = run_cli([], incoming_dir: '/nonexistent') }
    expect(status).to eq(3)
    expect(log).to include('not readable')
  end
end
