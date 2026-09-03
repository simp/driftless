# Quick and cheap catalog debugging utility while using onceover
# It can save catalogs and extract files from catalogs
#
# Use it by setting ONCEOVER_CATALOG_RAIDER_FILES during a onceover run:
#
# ONCEOVER_CATALOG_RAIDER_FILES=/etc/sssd/sssd.conf,nsswitch.conf,/etc/pam.d/password-auth,/etc/pam.d/system-auth,/etc/pam.d/sshd
#
require 'spec_helper'
require 'onceover/controlrepo'

filepaths_to_raid = ENV['ONCEOVER_CATALOG_RAIDER_FILES'].to_s
skip_reason = 'To enable: define env var ONCEOVER_CATALOG_RAIDER_FILES with a comma-delimited list of file paths to extract'

Onceover::Controlrepo.new.spec_tests do |class_name, node_name, facts, trusted_facts, trusted_external_data, pre_conditions|
  describe class_name, skip: (filepaths_to_raid.empty? ? skip_reason : false) do
    context "on #{node_name}" do
      let(:facts) { facts }
      let(:trusted_facts) { trusted_facts }
      let(:trusted_external_data) { trusted_external_data }
      let(:pre_condition) { pre_conditions }

      # Directory to contain the catalogs and files extracted from each host
      let(:catalog_output_top_dir) { File.join( ENV.fetch('HOME'), '_catalogs') }

      # List of File resource *titles* to extract
      let(:files_to_extract) { filepaths_to_raid.split(',') }

      it 'saves the catalog and extracts requested File contents [CATALOG RAIDER]' do
        require 'yaml'
        require 'json'
        require 'fileutils'

        catalog_output_dir = File.join(catalog_output_top_dir, class_name.tr(':','_'), node_name)

        # quick reusable helper for extracting catalog resources
        write_file = ->(name, content) {
          dest = File.join(catalog_output_dir, name)
          FileUtils.mkdir_p(File.dirname(dest))
          warn "Writing to #{dest}"
          File.write(dest, content)
        }

        write_file.call('resources.yaml', catalogue.resources.to_yaml)
        write_file.call('resources.keys.json', JSON.pretty_generate(catalogue.resource_keys))
        a={}; catalogue.resource_keys.each{|x,y| a[x] ||= []; a[x] << y }
        write_file.call('resources.keys.grouped.json', JSON.pretty_generate(a))
        write_file.call('resources.keys.grouped.yaml', a.to_yaml)

        # extract specific files' *content*
        # (only works on File resources, not concat fragments, inifiles, etc)
        files_to_extract.each do |title|
          res_name = "File[#{title}]"
          res = catalogue.resource(res_name)
          if res
            if res[:content]
              write_file.call(File.join('content', title), res[:content])
            else
              extra = res[:source] ? " (instead, :source points to '#{res[:source]}')" : nil
              warn "WARNING: #{res_name} has no :content defined#{extra}"
            end
          else
            warn "WARNING: #{res_name} not found in catalog; can't save"
          end
        end
        expect(catalogue.resources).not_to be_empty
      end
    end
  end
end
