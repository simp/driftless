require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'stringio'
require 'json'
require 'yaml'

require 'support/fixture_repo'
require 'pupgrade/cli/solve'
require 'driftless/inputs/puppetfile'

# `solve` on the fixture control repo, whose clones carry the tags of every
# release.
RSpec.describe Pupgrade::CLI::Solve do
  before(:all) do # rubocop:disable RSpec/BeforeAfterAll
    @tmp     = Dir.mktmpdir
    @fixture = Pupgrade::FixtureRepo.build(File.join(@tmp, 'repo'))
  end

  after(:all) { FileUtils.rm_rf(@tmp) } # rubocop:disable RSpec/BeforeAfterAll

  let(:fixture) { @fixture }

  # [exit status, stdout]
  def run(argv, config: ['-c', fixture.config], dir: fixture.dir)
    captured = StringIO.new
    original = $stdout
    $stdout  = captured
    status   = nil
    begin
      described_class.new.run(config + ['-d', dir] + argv)
    rescue SystemExit => e
      status = e.status
    ensure
      $stdout = original
    end
    [status, captured.string]
  end

  def rows(output)
    output.lines.map(&:rstrip).reject { |l| l.start_with?('--') }.map { |l| l.split('|', -1).map(&:strip) }.drop(1).to_h { |r| [r[0], r[1..]] }
  end

  around(:each) do |ex|
    original = Pupgrade.instance_variable_get(:@config)
    ex.run
  ensure
    Pupgrade.instance_variable_set(:@config, original)
  end

  before(:each) { silence_logger }

  it 'finds the set every constraint holds in, says what stops a module short, and moves the rest under a bump' do
    # with nothing asked of the operating systems or Puppet, baseline (one version, needing stdlib < 9) holds stdlib and all behind it
    status, out = run([], config: ['--no-config'])
    expect(status).to eq(1) # unresolvable constraints, not excluded
    table = rows(out)
    expect(table['puppetlabs-stdlib']).to match(['tag v8.6.0', '(current)', '3', a_string_starting_with('solved: every version of baseline depends on stdlib >= 4.13.1, < 9.0.0')])
    expect(table['puppetlabs-apache'].last).to start_with('solved: apache >= 11.0.0 depends on stdlib >= 9.0.0, < 10.0.0; every version of baseline depends on stdlib >= 4.13.1, < 9.0.0')
    expect(table['saz-timezone']).to eq(['tag 6.1.0', '7.0.0', '1', 'newest'])
    # tomcat's ranges a move of stdlib and concat would meet, so they stay in force; baseline holds stdlib, and
    # tomcat, already broken, is the one pinned rather than a module that was intact
    expect(table['puppetlabs-tomcat']).to eq(['tag v7.0.0', '(current)', '1', 'unresolved: needs puppetlabs/stdlib >= 9.0.0 < 10.0.0, but stdlib is 8.6.0; ' \
                                                                              'needs puppetlabs/concat >= 9.0.0 < 10.0.0, but concat is 7.3.0'])
    expect(table).not_to have_key('puppetlabs-facts')
    _, out = run(['--explain', 'stdlib'], config: ['--no-config'])
    # a derivation whose every step adds one leaf reads as the finding and its leaves
    expect(out).to include("\npuppetlabs-stdlib: v8.6.0 (solved: every version of baseline depends on stdlib >= 4.13.1, < 9.0.0)\n" \
                           "  stdlib cannot go past 8.6.0,\n" \
                           "     because every version of baseline depends on stdlib >= 4.13.1, < 9.0.0\n" \
                           "        and no versions satisfy stdlib > 8.6.0, < 9.0.0\n" \
                           "        and baseline is on the modulepath\n")

    # the config asks for RedHat 9, which the old releases do not claim and the new ones do: a constraint a
    # module can meet by moving stays in force, so the set moves past baseline, which fits nowhere
    status, out = run([])
    expect(status).to eq(1)
    table = rows(out)
    expect(table['puppetlabs-stdlib']).to eq(['tag v8.6.0', 'v9.6.0', '3', 'newest'])
    expect(table['acme-baseline']).to match(['branch main', '(current)', '0', a_string_starting_with('unresolved: needs puppetlabs/stdlib >= 4.13.1 < 9.0.0, but stdlib moves to 9.6.0')])
    expect(table['puppetlabs-translate']).to match(['2.2.0 (forge)', '(current)', '0', a_string_starting_with('Forge module; unresolvable: requires puppet >= 4.10.0 < 8.0.0')])
    _, out = run(['--all'])
    expect(rows(out)['puppetlabs-facts']).to eq(['1.4.0 (forge)', '(current)', '0', 'Forge module'])

    overlay = File.join(@tmp, 'Puppetfile.solved')
    status, out = run(['--bump', 'puppetlabs-stdlib', '-o', overlay])
    expect(status).to eq(1)
    table = rows(out)
    expect(table['puppetlabs-stdlib']).to eq(['tag v8.6.0', 'v9.6.0', '3', 'bumped'])
    expect(table['puppetlabs-apache']).to eq(['tag v10.1.1', 'v12.0.0', '2', 'newest'])
    expect(table['puppetlabs-puppetdb']).to eq(['tag v7.13.0', 'v8.1.0', '2', 'newest'])
    expect(table['acme-baseline']).to match(['branch main', '(current)', '0', a_string_starting_with('unresolved: needs puppetlabs/stdlib >= 4.13.1 < 9.0.0, but stdlib moves to 9.6.0')])
    expect(table['puppet-kafka']).to eq(['tag v8.1.0', 'v9.0.0', '1', 'newest; unresolvable: needs puppet/zookeeper >= 1.0.0 < 2.0.0, but zookeeper is not on the modulepath'])
    expect(table['puppetlabs-apt'].last).to eq('newest; unresolvable: supports Ubuntu, Debian, but missing RedHat')

    proposed = Driftless::Inputs::Puppetfile.load_file(overlay)
    expect(proposed.error).to be_nil
    expect(proposed.modules.size).to eq(31)
    stdlib = proposed.modules.find { |m| m.name == 'puppetlabs-stdlib' }
    expect([stdlib.git, stdlib.ref, stdlib.ref_type, stdlib.path]).to eq([File.join(fixture.remotes_dir, 'puppetlabs-stdlib.git'), 'v9.6.0', 'tag', 'modules/stdlib'])
    baseline = proposed.modules.find { |m| m.name == 'acme-baseline' }
    expect(baseline).to be_nil
  end

  it 'moves each module to the fitting version nearest its current one when driven by a bump, and shows all with --all' do
    _, out = run(['--order', 'nearest', '--bump', 'puppetlabs-stdlib', '--all'])
    table = rows(out)
    expect(table['puppetlabs-stdlib']).to eq(['tag v8.6.0', 'v9.6.0', '3', 'bumped'])
    # a nearest fit says what pushed the module off its current version
    expect(table['puppetlabs-concat']).to eq(['tag v7.3.0', 'v9.0.0', '2', 'nearest: concat 7.3.0 supports Ubuntu 18.04, 20.04, but missing Ubuntu 22.04'])
    expect(table['puppetlabs-apache']).to match(['tag v10.1.1', 'v11.0.0', '2', a_string_starting_with('nearest: ')])
    expect(table['puppetlabs-firewall']).to match(['tag v5.0.0', 'v7.0.0', '3', a_string_starting_with('nearest: ')])
    _, out = run(['--order', 'nearest', '--bump', 'puppetlabs-stdlib', '--explain', 'apache'], config: ['--no-config'])
    expect(out).to include("\n  apache cannot stay at 10.1.1,\n     because apache < 11.0.0 depends on stdlib >= 4.13.1, < 9.0.0\n" \
                           "        and stdlib is bumped to 9.6.0 (--bump)\n")
    expect(table['puppetlabs-facts']).to eq(['1.4.0 (forge)', '(current)', '0', 'Forge module'])

    # a hold and a bump are facts; what fits neither is unresolved
    status, out = run(['--order', 'nearest', '--bump', 'puppetlabs-stdlib=v9.0.0', '--hold', 'puppetlabs-concat'])
    expect(status).to eq(1)
    table = rows(out)
    expect(table['puppetlabs-stdlib']).to eq(['tag v8.6.0', 'v9.0.0', '3', 'bumped'])
    expect(table['puppetlabs-concat'][0..2]).to eq(['tag v7.3.0', '(current)', '2'])
    expect(table['puppetlabs-concat'].last).to start_with('held at current: needs puppetlabs/stdlib >= 4.13.1 < 9.0.0, but stdlib moves to 9.0.0')
    expect(table['puppetlabs-apache'].last).to start_with('unresolved: needs puppetlabs/stdlib >= 4.13.1 < 9.0.0, but stdlib moves to 9.0.0')
    # with nothing required of the operating systems or Puppet, the current
    # versions fit and nothing drives a move; only the unresolvable shows
    _, out = run(['--order', 'oldest'], config: ['--no-config']) # the old name of nearest
    table = rows(out)
    expect(table.keys).to eq(%w[puppet-kafka puppetlabs-tomcat])
    expect(table['puppetlabs-tomcat']).to eq(['tag v7.0.0', '(current)', '1', 'unresolved: needs puppetlabs/stdlib >= 9.0.0 < 10.0.0, but stdlib is 8.6.0; ' \
                                                                              'needs puppetlabs/concat >= 9.0.0 < 10.0.0, but concat is 7.3.0'])
  end

  # apache's main is one commit past v12.0.0, its metadata still 12.0.0
  it 'takes the ref a bump names, a branch tip over a tag of its version, and writes it as a branch' do
    branchfile = File.join(@tmp, 'apache-branch.yaml')
    File.write(branchfile, "puppetlabs-apache: main\n")
    overlay = File.join(@tmp, 'apache.pf')
    args    = ['--branchfile', branchfile, '--include-heads', '-o', overlay]
    _, out = run(args + ['--bump', 'puppetlabs-apache=main'], config: ['--no-config'])
    expect(rows(out)['puppetlabs-apache'].first(2)).to eq(['tag v10.1.1', 'main'])
    apache = Driftless::Inputs::Puppetfile.load_file(overlay).modules.find { |m| m.name == 'puppetlabs-apache' }
    expect([apache.ref, apache.ref_type]).to eq(%w[main branch])

    # unbumped, with what holds it back bumped, the tag of that version comes first
    _, out = run(args + ['--bump', 'puppetlabs-stdlib', '--bump', 'puppetlabs-concat'], config: ['--no-config'])
    expect(rows(out)['puppetlabs-apache'][1]).to eq('v12.0.0')
  end

  it 'warns for each clone not at its declaration, naming both refs' do
    clone = File.join(fixture.dir, 'modules/concat')
    system('git', '-C', clone, 'checkout', '-q', '--detach', 'v9.0.0', exception: true)
    allow(Driftless).to receive(:logger).and_call_original
    log = capture_log(level: :warning) { run([], config: ['--no-config']) }
    expect(log).to include("warning: solve: puppetlabs-concat: clone at v9.0.0, Puppetfile declares v7.3.0; the solve starts from the clone\n")
    expect(log).not_to include('puppetlabs-stdlib: clone at')
  ensure
    system('git', '-C', clone, 'checkout', '-q', '--detach', 'v7.3.0', exception: true)
  end

  it 'logs each module\'s choice at info once: the ref, or a Forge module\'s version, and the note' do
    allow(Driftless).to receive(:logger).and_call_original
    log = capture_log(level: :info) { run(['-v'], config: ['--no-config']) }
    expect(log).to include("info: solve: puppetlabs-stdlib: v8.6.0 (solved)\n", "info: solve: puppetlabs-facts: 1.4.0 (Forge module)\n")
    expect(log).not_to include('(current) (')
  end

  it 'takes bumps and holds by any spelling, warns about the ones that name nothing, and explains' do
    allow(Driftless).to receive(:logger).and_call_original
    out = nil
    log = capture_log(level: :warning) do
      _, out = run(['--bump', 'voxpupuli-stdlib=v9.4.0', '--bump', 'nope', '--hold', 'orangutan', '--bump', 'puppetlabs-concat=v99',
                    '--explain', 'stdlib,concat'])
    end
    expect(log.lines.map(&:chomp).grep(/\Awarning:/)).to contain_exactly(
      'warning: solve: --bump puppetlabs-concat=v99: v99 is not a candidate of modules/concat (candidates: v9.0.0, v9.1.0; try --fetch)',
      'warning: solve: --bump nope matches no module',
      'warning: solve: --hold orangutan matches no module',
    )
    main, explain = out.split("\n\n", 2)
    expect(rows(main)['puppetlabs-stdlib']).to eq(['tag v8.6.0', 'v9.4.0', '3', 'bumped'])
    expect(rows(main)['puppetlabs-concat']).to eq(['tag v7.3.0', 'v9.1.0', '2', 'newest'])
    expect(explain).to eq("puppetlabs-stdlib: v9.4.0 (bumped)\n  nothing stood in the way\n\npuppetlabs-concat: v9.1.0 (newest)\n  nothing stood in the way\n")

    _, out = run(['--hold', 'puppetlabs-stdlib', '--bump', 'puppetlabs-firewall=v8.0.0', '--explain', 'puppetdb,firewall'])
    table = rows(out.split("\n\n", 2).first)
    expect(table['puppetlabs-firewall']).to eq(['tag v5.0.0', 'v8.0.0', '3', 'bumped: needs puppetlabs/stdlib >= 9.0.0 < 10.0.0, but stdlib is 8.6.0'])
    expect(table['puppetlabs-puppetdb'].last).to start_with('unresolved: needs puppetlabs/firewall >= 1.1.3 < 6.0.0, but firewall moves to 8.0.0')
    expect(out).to include("\n  no version of puppetdb fits the rest,\n     because puppetdb >= 8.0.0 depends on stdlib >= 9.0.0, < 10.0.0\n",
                           "\n        and firewall is bumped to 8.0.0 (--bump)\n        and stdlib is held at 8.6.0 (--hold)\n")
    # a lever the rest cannot meet is named in the finding, which states its fact
    firewall = out[/\npuppetlabs-firewall: .*?(?=\n\n|\z)/m]
    expect(firewall).to include("\n  firewall cannot be bumped to 8.0.0,\n     because ", "stdlib is held at 8.6.0 (--hold)")
    expect(firewall).not_to include('(--bump)', 'no version of')
  end

  it 'prunes dependency edges to and from modules the evidence shows unused, writes the exclusions the result relies on, and reads them back' do
    evidence = File.join(@tmp, 'catalogs')
    FileUtils.mkdir_p(File.join(evidence, 'web01.example.com'))
    File.write(File.join(evidence, 'web01.example.com/compile.json'), JSON.generate(
      'document'  => 'compile', 'schema_version' => 3,
      'classes'   => { 'redis' => { 'module' => 'redis' }, 'stdlib' => { 'module' => 'stdlib' }, 'yumrepo_core' => { 'module' => 'yumrepo_core' } },
      'functions' => { 'stdlib::shout' => { 'module' => 'stdlib', 'sites' => ['modules/yumrepo_core/manifests/init.pp:3'] } },
    ))
    status, out = run(['--hold', 'puppetlabs-apt'])
    expect(status).to eq(1)
    # redis 8.8.0 does not claim RedHat 9 and its newer releases need the held apt: nothing fits
    expect(rows(out)['puppet-redis']).to match(['tag v8.8.0', '(current)', '2', a_string_starting_with('unresolved: needs puppetlabs/stdlib >= 4.13.1 < 9.0.0, but stdlib moves to 9.6.0')])
    _, out = run(['--hold', 'puppetlabs-apt'], config: ['--no-config'])
    expect(rows(out)['puppet-redis']).to match(['tag v8.8.0', '(current)', '2', a_string_starting_with('solved: redis >= 9.0.0 depends on')])
    expect(rows(out)['puppetlabs-apt']).to match(['tag v8.5.0', '(current)', '2', a_string_starting_with('held at current')])

    exclusions = File.join(@tmp, 'exclusions.yaml')
    allow(Driftless).to receive(:logger).and_call_original
    log = capture_log do
      status, out = run(['--hold', 'puppetlabs-apt', '--compile-cache', evidence, '--prune-unused', '--write-exclusions-file', exclusions])
    end
    expect(status).to eq(1)
    expect(rows(out)['puppet-redis']).to eq(['tag v8.8.0', 'v10.0.0', '2', 'newest'])
    expect(rows(out)['puppetlabs-stdlib']).to eq(['tag v8.6.0', 'v9.6.0', '3', 'newest'])
    written = YAML.safe_load(File.read(exclusions))['modules']
    expect(written['exclude_dependencies']).to eq(['puppetlabs-apt:puppetlabs/stdlib', 'acme-baseline:puppetlabs/stdlib', 'puppetlabs-postgresql:puppetlabs/apt', 'puppet-redis:puppetlabs/apt'])
    expect(written['exclude_requirements']).to eq(['puppetlabs-translate'])
    expect(written['exclude_operatingsystems']).to include('puppetlabs-apt:RedHat *', 'puppetlabs-translate:Ubuntu 22.04', 'simp-simplib:RedHat *')
    expect(log).to include('solve: puppetlabs-yumrepo_core -> stdlib: used, but not a declared dependency')
    expect(log).to include('evidence from 1 node(s)')
    # read back, the file covers everything the result still breaks
    status, out = run(['--hold', 'puppetlabs-apt', '--compile-cache', evidence, '--prune-unused', '--exclusion-file', exclusions])
    expect(status).to eq(0)
    expect(out).not_to include('unresolvable')
    expect(run(['--exclusion-file', File.join(@tmp, 'nope.yaml')]).first).to eq(3)

    _, out = run(['--ignore', 'apt,zookeeper'])
    expect(rows(out)).not_to have_key('puppetlabs-apt')
    expect(rows(out)['puppet-redis'].last).to include('unresolvable: needs puppetlabs/apt >= 9.0.0 < 10.0.0, but apt is not on the modulepath')
    expect(run(['--prune-unused']).first).to eq(2)
    expect(run(['--compile-cache', File.join(@tmp, 'nope')]).first).to eq(3)
    expect(run(['--order', 'sideways']).first).to eq(2)
  end

  # app 1.1.0 and 2.0.0 are each refused for their own reason, so the
  # derivation joins two derived lines and keeps the solver's steps
  it 'explains a branching refusal in the solver\'s steps, closed by the finding, and draws it as nested subgraphs' do
    dir = File.join(@tmp, 'two-branches')
    Pupgrade::ScenarioBuilder.new(File.expand_path('../fixtures/scenarios/two-branches', __dir__)).build(dir)
    _, out = run(['--explain', 'app'], config: ['--no-config'], dir: dir)
    expect(out).to include("\nacme-app: v1.0.0 (solved: ")
    expect(out).to include("\n  Thus, if x >= 0 and app > 1.0.0 then b >= 1.0.0, < 2.0.0.\n",
                           "    and app is held above 1.0.0 (--explain),\n",
                           "  So, because a is on the modulepath\n    and x is on the modulepath,\n    app cannot go past 1.0.0.\n")
    _, out = run(['--explain', 'app', '-g', '-'], config: ['--no-config'], dir: dir)
    graph = out.split("flowchart TB\n", 2).last
    expect(graph).to include('  subgraph r0 ["app cannot go past 1.0.0"]',
                             '    subgraph r0_0 ["every version of x is incompatible with app #gt;= 2.0.0"]',
                             '      r0_x -- "depends on y #gt;= 2.0.0, #lt; 3.0.0" --> r0_y',
                             '    subgraph r0_1 ["app #gt; 1.0.0, #lt; 2.0.0 requires b #gt;= 1.0.0, #lt; 2.0.0"]',
                             '    r0_app_3["app #gt;= 1.1.0, #lt; 2.0.0"]:::subject', '    r0_b["b 1.0.0 (current) · 2.0.0"]:::near', '    r0_a["every version of a"]:::far')
    expect(graph.lines.grep(/\A  linkStyle/).map(&:strip)).to eq(['linkStyle 2,4 stroke:#2e7d32,color:#2e7d32', 'linkStyle 0,1,3 stroke:#c62828,color:#c62828'])
    expect(graph).not_to include('on the modulepath', '(--explain)')
  end

  it 'writes the derivations as a mermaid flowchart with -g: one tree per module stopped short, levers blue, nothing when none' do
    path = File.join(@tmp, 'solve.mmd')
    run(['--explain', 'stdlib,apache', '-g', path], config: ['--no-config'])
    graph = File.read(path)
    expect(graph).to start_with("flowchart TB\n  classDef subject")
    expect(graph.scan(/^  subgraph r\d+ \["(.*)"\]/).flatten).to eq(['stdlib cannot go past 8.6.0', 'apache cannot go past 10.1.1'])
    expect(graph).to include('    r0_baseline -- "depends on stdlib #gt;= 4.13.1, #lt; 9.0.0" --> r0_stdlib',
                             '    r0_fact(["no versions satisfy stdlib #gt; 8.6.0, #lt; 9.0.0"]):::conflict',
                             '    r1_apache_2 -- "depends on stdlib #gt;= 9.0.0, #lt; 10.0.0" --> r1_stdlib',
                             '    r1_stdlib["stdlib 8.6.0 (current) · 9.0.0 · 9.4.0 · 9.6.0"]:::near')
    expect(graph.lines.grep(/\A  linkStyle/).map(&:strip)).to eq(['linkStyle 4 stroke:#2e7d32,color:#2e7d32', 'linkStyle 1,2,3 stroke:#c62828,color:#c62828', 'linkStyle 0 stroke:#9e9e9e,color:#616161'])
    # a lever is a blue fact beside its module
    _, out = run(['--bump', 'puppetlabs-stdlib', '--explain', 'baseline', '-g', '-'], config: ['--no-config'])
    expect(out).to include('  subgraph r0 ["no version of baseline fits the rest"]', '    r0_fact(["stdlib is bumped to 9.6.0 (--bump)"]):::lever',
                           '    r0_baseline["every version of baseline"]:::subject')
    # without --explain every module with a derivation is drawn; a module that moved freely has none
    run(['-g', path], config: ['--no-config'])
    expect(File.read(path).scan(/^  subgraph r\d+ \["(.*)"\]/).flatten).to include('stdlib cannot go past 8.6.0', 'no version of tomcat fits the rest')
    _, out = run(['--explain', 'timezone', '-g', '-'], config: ['--no-config'])
    expect(out).to include("flowchart TB\n", '  %% nothing stood in the way')
  end
end
