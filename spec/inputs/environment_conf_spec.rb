require 'spec_helper'
require 'tmpdir'

require 'driftless/inputs/environment_conf'

RSpec.describe Driftless::Inputs::EnvironmentConf do
  def with_conf(contents)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'environment.conf'), contents) if contents
      yield described_class.load(dir)
    end
  end

  describe '.load' do
    it 'returns exists? false when environment.conf is absent' do
      with_conf(nil) do |result|
        expect(result.exists?).to be false
        expect(result.modulepath).to be_nil
        expect(result.manifest).to be_nil
      end
    end

    it 'parses modulepath as a colon-separated list' do
      with_conf("modulepath = site:site-modules:modules:$basemodulepath\n") do |result|
        expect(result.exists?).to be true
        expect(result.modulepath).to eq(%w[site site-modules modules $basemodulepath])
      end
    end

    it 'parses the manifest key' do
      with_conf("manifest = manifests/site.pp\n") do |result|
        expect(result.manifest).to eq('manifests/site.pp')
        expect(result.modulepath).to be_nil
      end
    end

    it 'strips `#` and `;` comments and blank lines' do
      contents = <<~CONF
        # top comment
        modulepath = site   ; trailing comment
        ; whole-line comment
        environment_timeout = 0
      CONF
      with_conf(contents) do |result|
        expect(result.modulepath).to eq(['site'])
      end
    end

    it 'drops empty entries from a modulepath with adjacent colons' do
      with_conf("modulepath = site::modules:\n") do |result|
        expect(result.modulepath).to eq(%w[site modules])
      end
    end

    it 'ignores unknown keys' do
      with_conf("config_version = ./bin/vsn.sh\nmodulepath = site\n") do |result|
        expect(result.modulepath).to eq(['site'])
      end
    end

    it 'returns exists? true even when neither modulepath nor manifest is set' do
      with_conf("environment_timeout = 0\n") do |result|
        expect(result.exists?).to be true
        expect(result.modulepath).to be_nil
        expect(result.manifest).to be_nil
      end
    end
  end
end
