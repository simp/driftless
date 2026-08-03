require 'spec_helper'

require 'driftless/class_extractor'
require 'driftless/inputs/manifest_parser'

RSpec.describe Driftless::ClassExtractor do
  def fixture(name)
    File.expand_path("fixtures/manifests/#{name}", __dir__)
  end

  describe '.extract' do
    let(:program) { Driftless::Inputs::ManifestParser.parse(fixture('classes.pp'))[0] }
    let(:classes) { described_class.extract(program: program, file: fixture('classes.pp')) }

    it 'extracts every HostClassDefinition with its fully-qualified name' do
      expect(classes.map(&:fqname)).to include(
        'profile::example',
        'role::web',
        'basename::role::nested',
        'util::helpers',
      )
    end

    it 'extracts ResourceTypeDefinition (defined types) alongside classes' do
      expect(classes.map(&:fqname)).to include('profile::vhost')
    end

    it 'records the source file on every extracted class' do
      expect(classes).to all(have_attributes(file: fixture('classes.pp')))
    end

    context 'role/profile detection' do
      it 'flags role::* classes as role?' do
        expect(classes.find { |c| c.fqname == 'role::web' }.role?).to be true
      end

      it 'flags namespaced ::role:: classes as role?' do
        expect(classes.find { |c| c.fqname == 'basename::role::nested' }.role?).to be true
      end

      it 'flags profile::* classes as profile?' do
        expect(classes.find { |c| c.fqname == 'profile::example' }.profile?).to be true
      end

      it 'does NOT flag non-role/non-profile classes' do
        util = classes.find { |c| c.fqname == 'util::helpers' }
        expect(util.role?).to be false
        expect(util.profile?).to be false
      end

      it 'a class named profile::* is NOT also role, and vice versa' do
        expect(classes.find { |c| c.fqname == 'role::web' }.profile?).to be false
        expect(classes.find { |c| c.fqname == 'profile::example' }.role?).to be false
      end
    end

    context 'parameter extraction' do
      let(:example) { classes.find { |c| c.fqname == 'profile::example' } }

      it 'extracts parameter names in source order' do
        expect(example.params.map(&:name)).to eq(%w[vhost ssl untyped_param])
      end

      it 'captures type_expr for typed params (nil for untyped)' do
        types = example.params.each_with_object({}) { |p, h| h[p.name] = p.type_expr }
        expect(types['vhost']).not_to be_nil
        expect(types['ssl']).not_to be_nil
        expect(types['untyped_param']).to be_nil
      end

      it 'captures default_expr when a param has a default' do
        by_name = example.params.each_with_object({}) { |p, h| h[p.name] = p }
        expect(by_name['vhost'].default_expr).not_to be_nil
        expect(by_name['ssl'].default_expr).not_to be_nil
      end
    end
  end
end
