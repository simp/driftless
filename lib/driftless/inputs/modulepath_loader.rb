require 'driftless/finding'

module Driftless
  module Inputs
    class ModulepathLoader
      DEFAULT_MODULEPATH_DIRS = %w[site-modules modules].freeze
      DEFAULT_BASEMODULEPATH  = %w[
        /etc/puppetlabs/code/modules
        /opt/puppetlabs/puppet/modules
      ].freeze

      def self.load(repo_dir, basemodulepath: DEFAULT_BASEMODULEPATH)
        new(repo_dir, basemodulepath: basemodulepath).load
      end

      def initialize(repo_dir, basemodulepath: DEFAULT_BASEMODULEPATH)
        @repo_dir       = repo_dir
        @basemodulepath = Array(basemodulepath)
      end

      def load
        files    = []
        findings = []

        DEFAULT_MODULEPATH_DIRS.each do |rel|
          dir = File.join(@repo_dir, rel)
          next unless File.directory?(dir)
          files.concat(Dir[File.join(dir, '*/manifests/**/*.pp')])
        end

        @basemodulepath.each do |abs|
          unless File.directory?(abs)
            findings << finding(
              'hierarchy:absolute-modulepath-missing',
              abs,
              "basemodulepath component not present: #{abs}",
            )
            next
          end
          files.concat(Dir[File.join(abs, '*/manifests/**/*.pp')])
        end

        [files.sort.uniq, findings]
      end

      private

      def finding(key, path, message)
        Finding.new(key: key, path: path, line: nil, message: message, meta: {})
      end
    end
  end
end
