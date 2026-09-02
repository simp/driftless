require 'spec_helper'
require 'driftless/detectors/code_unused_modules'

RSpec.describe Driftless::Detectors::CodeUnusedModules do
  before(:each) { Driftless.config = Driftless::Config.new(merged: {}) }

  def puppet_class(fqname)
    mod = fqname.split('::').first
    sub = fqname.include?('::') ? fqname.split('::', 2).last.tr(':', '/').squeeze('/') : 'init'
    Driftless::PuppetClass.new(fqname: fqname, params: [], role: false, profile: false,
                               file: "/repo/site-modules/#{mod}/manifests/#{sub}.pp")
  end

  def corpus_with(classes, classified: nil)
    data = classified.nil? ? {} : { 'classes-for-all-active-nodes' => classified }
    build_corpus(
      puppet_classes: classes.to_h { |c| [c.fqname, c] },
      reported:       Driftless::Reported.new(data: data),
    )
  end

  def classed_node(certname, classes)
    Driftless::Node.new(certname: certname, classes: classes)
  end

  it 'declares the classes report it reads' do
    expect(described_class.requires_reports).to eq(['classes-for-all-active-nodes'])
  end

  it 'emits a single skipped meta finding without the classes report' do
    findings = described_class.new(corpus_with([puppet_class('apache')])).call
    expect(findings.map(&:key)).to eq(['skipped:code:unused-modules'])
  end

  it 'flags a module none of whose classes any node uses' do
    corpus = corpus_with([puppet_class('legacy'), puppet_class('legacy::install')],
                         classified: [classed_node('web1', ['Apache'])])
    findings = described_class.new(corpus).call
    expect(findings.length).to eq(1)
    expect(findings.first.path).to eq('/repo/site-modules/legacy')
    expect(findings.first.meta).to eq(module_name: 'legacy', classes: %w[legacy legacy::install])
  end

  it 'counts a module used when any one of its classes is classified' do
    corpus = corpus_with([puppet_class('apache'), puppet_class('apache::vhost')],
                         classified: [classed_node('web1', ['Apache::Vhost'])])
    expect(described_class.new(corpus).call).to be_empty
  end
end
