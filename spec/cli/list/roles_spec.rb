require 'stringio'
require 'tmpdir'
require 'fileutils'

require 'spec_helper'
require 'driftless/cli/list/roles'

RSpec.describe Driftless::CLI::List::Roles do
  def control_repo(dir)
    File.write(File.join(dir, 'hiera.yaml'), "---\nversion: 5\nhierarchy: []\n")
    File.write(File.join(dir, 'environment.conf'), "modulepath = site-modules:modules\n")
    FileUtils.mkdir_p(File.join(dir, 'site-modules/role/manifests'))
    FileUtils.mkdir_p(File.join(dir, 'site-modules/profile/manifests'))
    File.write(File.join(dir, 'site-modules/role/manifests/web.pp'), "class role::web { }\n")
    File.write(File.join(dir, 'site-modules/role/manifests/db.pp'), "class role::db { }\n")
    File.write(File.join(dir, 'site-modules/profile/manifests/base.pp'), "class profile::base { }\n")
  end

  def run(argv)
    out      = StringIO.new
    original = $stdout
    $stdout  = out
    begin
      described_class.new.run(argv)
    rescue SystemExit
      nil
    ensure
      $stdout = original
    end
    out.string
  end

  around(:each) do |ex|
    original = Driftless.instance_variable_get(:@config)
    ex.run
  ensure
    Driftless.instance_variable_set(:@config, original)
  end

  before(:each) { silence_driftless_logger }

  it 'lists each role class with the manifest defining it, relative to the repo' do
    Dir.mktmpdir do |dir|
      control_repo(dir)
      lines = run(['--no-config', '-d', dir]).lines.map(&:rstrip)
      expect(lines).to eq([
        'role      | file',
        '----------+-----------------------------------',
        'role::db  | site-modules/role/manifests/db.pp',
        'role::web | site-modules/role/manifests/web.pp',
      ])
    end
  end

  it 'says so when the repo defines no roles' do
    Dir.mktmpdir do |dir|
      control_repo(dir)
      FileUtils.rm_rf(File.join(dir, 'site-modules/role'))
      expect(run(['--no-config', '-d', dir])).to eq("(nothing matches)\n")
    end
  end
end
