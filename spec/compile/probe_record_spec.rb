require 'spec_helper'
require 'tmpdir'
require 'json'

require 'pupgrade/compile/probe_record'

RSpec.describe Pupgrade::Compile::ProbeRecord do
  def write(dir, data)
    path = File.join(dir, 'compile.json')
    File.write(path, data.is_a?(String) ? data : JSON.generate(data))
    path
  end

  it 'reads a record of its own schema and refuses any other' do
    Dir.mktmpdir do |dir|
      good = write(dir, 'document' => 'compile', 'schema_version' => described_class::SCHEMA_VERSION, 'certname' => 'a')
      expect(described_class.read(good)['certname']).to eq('a')

      newer = write(dir, 'document' => 'compile', 'schema_version' => described_class::SCHEMA_VERSION + 1)
      expect { described_class.read(newer) }.to raise_error(described_class::Error, /schema 4 is newer than this pupgrade reads \(3\); compile again/)
      older = write(dir, 'document' => 'compile', 'schema_version' => 1)
      expect { described_class.read(older) }.to raise_error(described_class::Error, /schema 1 is older/)
      other = write(dir, 'document' => 'catalog', 'schema_version' => 1)
      expect { described_class.read(other) }.to raise_error(described_class::Error, /not a compile record \(document "catalog"\)/)
      broken = write(dir, '{')
      expect { described_class.read(broken) }.to raise_error(described_class::Error, /compile\.json: /)
      expect { described_class.read(File.join(dir, 'nope.json')) }.to raise_error(described_class::Error, /no such file/)
    end
  end

  it 'names an older pupgrade when a node has probes.json and no compile.json' do
    Dir.mktmpdir do |dir|
      node = File.join(dir, 'web01')
      Dir.mkdir(node)
      expect { described_class.paths(dir) }.to raise_error(described_class::Error, %r{no <certname>/compile\.json})
      File.write(File.join(node, 'probes.json'), '{}')
      expect { described_class.paths(dir) }.to raise_error(described_class::Error, %r{web01/probes\.json was written by an older pupgrade; compile again})
      expect { described_class.read(File.join(node, 'compile.json')) }.to raise_error(described_class::Error, /older pupgrade/)
      File.write(File.join(node, 'compile.json'), JSON.generate('document' => 'compile', 'schema_version' => described_class::SCHEMA_VERSION))
      expect(described_class.paths(dir)).to eq([File.join(node, 'compile.json')])
    end
  end
end
