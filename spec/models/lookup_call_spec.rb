require 'spec_helper'

require 'driftless/models/lookup_call'

RSpec.describe Driftless::LookupCall do
  def call(file, key)
    described_class.new(key: key, function: 'lookup', file: file, line: 1, has_default: false)
  end

  it 'derives the class a manifest defines, nil elsewhere' do
    expect(call('/r/modules/apache/manifests/init.pp', 'x').class_name).to eq('apache')
    expect(call('/r/site-modules/profile/manifests/db/server.pp', 'x').class_name).to eq('profile::db::server')
    expect(call('/r/modules/apache/templates/x.epp', 'x').class_name).to be_nil
    expect(call(nil, 'x').class_name).to be_nil
  end

  it 'is module-local for a module reading its own namespace, not for roles, profiles, or other modules' do
    expect(call('/r/modules/timezone/manifests/init.pp', 'timezone::hwclock_cmd')).to be_module_local
    expect(call('/r/modules/timezone/templates/t.epp', 'timezone::hwclock_cmd')).to be_module_local
    expect(call('/r/modules/timezone/manifests/init.pp', 'apache::port')).not_to be_module_local
    expect(call('/r/site-modules/profile/manifests/web.pp', 'profile::web::packages')).not_to be_module_local
    expect(call('/r/data/common.yaml', 'timezone::x')).not_to be_module_local
    expect(call(nil, 'timezone::x')).not_to be_module_local
  end
end
