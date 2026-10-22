require 'stringio'

require 'spec_helper'
require 'driftless/cli/table'

RSpec.describe Driftless::CLI::Table do
  let(:table) do
    Class.new do
      include Driftless::CLI::Table

      def initialize(width = nil)
        @options = width ? { width: width } : {}
      end
    end
  end

  def render(width, columns, rows)
    captured = StringIO.new
    original = $stdout
    $stdout  = captured
    table.new(width).print_table(columns, rows)
    captured.string.lines.map(&:rstrip)
  ensure
    $stdout = original
  end

  it 'lays out columns at their widest when nothing limits the width' do
    lines = render(nil, %w[a b], [['x', "two\nlines  here"], %w[longer y]])
    expect(lines).to eq(['a      | b', '-------+---------------', 'x      | two lines here', 'longer | y'])
  end

  it 'narrows the widest column to the limit and wraps its cells at the best break, keeping the punctuation' do
    where = 'nodes: web01.example.com, web02.example.com; hiera: data/common.yaml:12, data/nodes/web01.yaml:3'
    lines = render(60, %w[module where], [['stdlib', where], ['concat', 'nodes: db01.example.com']])
    expect(lines.map(&:length).max).to be <= 60
    expect(lines).to eq([
      'module | where',
      "-------+-#{'-' * 51}",
      'stdlib | nodes: web01.example.com, web02.example.com;',
      '       | hiera: data/common.yaml:12, data/nodes/web01.yaml:3',
      'concat | nodes: db01.example.com',
    ])
  end

  it 'cuts a cell with no break at the width, never below the floor, and leaves width 0 unlimited' do
    long = 'x' * 50
    lines = render(30, %w[a b], [[long, long]])
    expect(lines[2..]).to eq(["#{'x' * 16} | #{'x' * 16}"] * 3 + ['xx               | xx'])
    expect(render(0, %w[a b], [[long, long]])[2]).to eq("#{long} | #{long}")
  end

  it 'wraps painted cells on their visible text and keeps the colour open across lines' do
    red  = "\e[31m"
    cell = "needs stdlib >= 9.0.0 but #{red}stdlib is 8.6.0 and more words here\e[0m"
    lines = render(40, %w[note], [[cell]])
    expect(lines[2..]).to eq(["needs stdlib >= 9.0.0 but #{red}stdlib is\e[0m", "#{red}8.6.0 and more words here\e[0m"])
  end
end
