require 'spec_helper'
require 'json'
require 'tmpdir'

require 'driftless/site'
require 'driftless/finding'
require 'driftless/reported'

RSpec.describe Driftless::Site do
  def finding(message: 'gone', path: 'data/nodes/x.yaml', line: nil, key: 'data:missing-nodes')
    Driftless::Finding.new(key: key, path: path, line: line, message: message, meta: { certname: 'x' })
  end

  def build_data(findings: [], warnings: [])
    Driftless::Site::BuildData.assemble(
      findings:     findings,
      corpus:       build_corpus(repo_dir: '/srv/control-repo', reported: Driftless::Reported.new(data: {})),
      warnings:     warnings,
      environments: ['production'],
      summary_dir:  nil,
      now:          Time.utc(2026, 8, 26, 12, 0, 0),
    )
  end

  # The JSON between the data element's tags.
  def embedded(html)
    html[%r{<script id="driftless-data" type="application/json">(.*?)</script>}m, 1]
  end

  describe '.build' do
    it 'writes index.html and data.json into the directory, creating it' do
      Dir.mktmpdir do |dir|
        out   = File.join(dir, 'nested', 'public')
        paths = described_class.build(build_data, out)
        expect(paths).to eq([File.join(out, 'index.html'), File.join(out, 'data.json')])
        expect(paths).to all(satisfy { |p| File.file?(p) })
      end
    end

    it 'writes the build data verbatim as data.json' do
      Dir.mktmpdir do |dir|
        data = build_data(findings: [finding(line: 3)], warnings: ['w'])
        described_class.build(data, dir)
        expect(JSON.parse(File.read(File.join(dir, 'data.json')))).to eq(JSON.parse(JSON.generate(data)))
      end
    end
  end

  describe '.render' do
    it 'embeds the build data so the page can parse it back' do
      data = build_data(findings: [finding(line: 3)], warnings: ['w'])
      html = described_class.render(data)
      expect(JSON.parse(embedded(html))).to eq(JSON.parse(JSON.generate(data)))
    end

    it 'keeps a message containing </script> or <!-- inside the data element' do
      data = build_data(findings: [finding(message: 'a </script><!-- b')])
      blob = embedded(described_class.render(data))
      lt = described_class::ESCAPED_LT
      expect(blob).not_to include('<')
      expect(blob).to include("#{lt}/script>#{lt}!-- b")
      expect(JSON.parse(blob)['findings'].first['message']).to eq('a </script><!-- b')
    end

    it 'inlines the stylesheet and script' do
      html = described_class.render(build_data)
      expect(html).to include('<style>').and include('prefers-color-scheme')
      expect(html).to include("document.getElementById('driftless-data')")
      expect(html).not_to match(/<link[^>]+href|<script[^>]+src/)
    end

    it 'names the repo in the title and header' do
      html = described_class.render(build_data)
      expect(html).to include('<title>driftless — control-repo</title>')
      expect(html).to include('/srv/control-repo')
    end

    it 'lists each finding in the noscript table, HTML-escaped' do
      data = build_data(findings: [finding(message: 'value <b>bold</b>', line: 7), finding(path: nil, message: 'structural')])
      html = described_class.render(data)
      noscript = html[%r{<noscript>(.*?)</noscript>}m, 1]
      expect(noscript).to include('data/nodes/x.yaml:7')
      expect(noscript).to include('value &lt;b&gt;bold&lt;/b&gt;')
      expect(noscript).not_to include('<b>bold</b>')
      expect(noscript).to include('<td>-</td>')
    end

    it 'says so in the noscript block when there are no findings' do
      noscript = described_class.render(build_data)[%r{<noscript>(.*?)</noscript>}m, 1]
      expect(noscript).to include('no findings')
      expect(noscript).not_to include('<table>')
    end
  end

  describe '.embed_json' do
    it 'escapes every < as its JSON unicode escape and nothing else' do
      json = described_class.embed_json('k' => '<a> & "b"')
      expect(json).to eq(%({"k":"#{described_class::ESCAPED_LT}a> & \\"b\\""}))
      expect(described_class::ESCAPED_LT).to eq(%w[\\ u003c].join)
      expect(described_class::ESCAPED_LT.length).to eq(6)
    end
  end
end
