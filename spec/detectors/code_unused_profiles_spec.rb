require 'spec_helper'
require 'driftless/detectors/code_unused_profiles'

RSpec.describe Driftless::Detectors::CodeUnusedProfiles do
  before(:each) { Driftless.config = Driftless::Config.new(merged: {}) }

  def puppet_class(fqname, role: false, profile: false)
    Driftless::PuppetClass.new(
      fqname: fqname, params: [], role: role, profile: profile,
      file: "/repo/site-modules/#{fqname.split('::').first}/manifests/init.pp",
    )
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
    findings = described_class.new(corpus_with([puppet_class('profile::base', profile: true)])).call
    expect(findings.map(&:key)).to eq(['skipped:code:unused-profiles'])
  end

  it 'flags a profile class no node is classified with' do
    corpus = corpus_with([puppet_class('profile::legacy', profile: true)],
                         classified: [classed_node('web1', ['Role::Web'])])
    findings = described_class.new(corpus).call
    expect(findings.map { |f| f.meta[:class_name] }).to eq(['profile::legacy'])
  end

  it 'stays silent for a profile classified under its PuppetDB (capitalized) title' do
    corpus = corpus_with([puppet_class('profile::base', profile: true)],
                         classified: [classed_node('web1', ['Profile::Base'])])
    expect(described_class.new(corpus).call).to be_empty
  end

  it 'ignores non-profile classes' do
    corpus = corpus_with([puppet_class('role::web', role: true), puppet_class('apache')],
                         classified: [classed_node('web1', [])])
    expect(described_class.new(corpus).call).to be_empty
  end

  it 'honors exclude_classes globs' do
    Driftless.config = Driftless::Config.new(
      merged: { 'detectors' => { 'code:unused-profiles' => { 'exclude_classes' => ['profile::legacy*'] } } },
    )
    corpus = corpus_with([puppet_class('profile::legacy', profile: true)],
                         classified: [classed_node('web1', [])])
    expect(described_class.new(corpus).call).to be_empty
  end
end
