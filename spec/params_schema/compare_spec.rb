require 'spec_helper'

require 'driftless/params_schema/compare'

RSpec.describe Driftless::ParamsSchema::Compare do
  def doc(classes, git: nil, deployments: {})
    { 'repo' => { 'git' => git, 'deployments' => deployments }, 'classes' => classes }
  end

  def cls(file, params)
    { 'file' => file, 'params' => params.transform_values { |t, d| { 'type' => t, 'default' => d } } }
  end

  it 'lists repo revision and deployment differences' do
    from = doc({}, git: { 'sha' => 'a' * 40, 'branch' => 'main' },
                   deployments: { 'modules/a' => { 'ref' => 'v1', 'sha' => 'b' * 40 }, 'modules/gone' => { 'ref' => 'v1', 'sha' => nil } })
    to   = doc({}, git: { 'sha' => 'c' * 40, 'branch' => 'main' },
                   deployments: { 'modules/a' => { 'ref' => 'v2', 'sha' => 'd' * 40 }, 'modules/new' => { 'ref' => 'main', 'sha' => nil } })
    expect(described_class.repo_changes(from, to)).to eq([
      "control repo: #{'a' * 12} (main) -> #{'c' * 12} (main)",
      "modules/a: v1 #{'b' * 12} -> v2 #{'d' * 12}",
      'modules/gone: v1 -> (absent)',
      'modules/new: (absent) -> main',
    ])
    expect(described_class.repo_changes(from, from)).to eq([])
  end

  it 'lists classes and params added, removed, retyped, and redefaulted' do
    from = doc({ 'apache' => cls('a.pp', 'port' => %w[Integer 80], 'old' => ['String', nil], 'same' => [nil, nil]),
                 'gone'   => cls('g.pp', 'x' => [nil, nil]) })
    to   = doc({ 'apache' => cls('a.pp', 'port' => %w[Stdlib::Port 8080], 'new' => %w[Boolean true], 'same' => [nil, nil]),
                 'added'  => cls('n.pp', 'y' => [nil, nil], 'z' => [nil, nil]) })
    changes = described_class.class_changes(from, to)
    expect(changes.map { |c| [c.kind, c.class_name, c.param, c.detail] }).to eq([
      ['class-added', 'added', nil, '2 params in n.pp'],
      ['type-changed', 'apache', 'port', 'Integer -> Stdlib::Port'],
      ['default-changed', 'apache', 'port', '80 -> 8080'],
      ['param-removed', 'apache', 'old', 'was String = (required)'],
      ['param-added', 'apache', 'new', 'Boolean = true'],
      ['class-removed', 'gone', nil, 'was in g.pp'],
    ])
    expect(described_class.class_changes(from, from)).to eq([])
  end
end
