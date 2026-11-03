require 'json'

require 'pupgrade/compile/probe_record'
require 'pupgrade/logging'

module Pupgrade
  module Solve
    # What a `compile` run shows the site using, read from its compile
    # records: the modules that provided any class, defined type, function,
    # resource type, or provider in any node's compile, and the functions
    # each module's own code called from another module.
    class Evidence
      class Error < StandardError; end

      # @return [Set<String>] module directory names seen in use
      attr_reader :used

      # @return [Hash{String => Set<String>}] using module (directory name)
      #   to the modules whose functions its code called
      attr_reader :calls

      # @return [Integer] how many compile records were read
      attr_reader :nodes

      # @param dir [String] a `compile` output directory
      # @raise [Error] when it holds no compile records
      def initialize(dir)
        @used  = Set.new
        @calls = Hash.new { |h, k| h[k] = Set.new }
        @nodes = 0
        ::Pupgrade::Compile::ProbeRecord.paths(File.expand_path(dir)).each do |p|
          Pupgrade.logger.debug("evidence: reading #{p}")
          read(::Pupgrade::Compile::ProbeRecord.read(p))
        end
        Pupgrade.logger.info("evidence: #{@nodes} node(s) from #{File.expand_path(dir)}; #{@used.size} module(s) used")
      rescue ::Pupgrade::Compile::ProbeRecord::Error => e
        raise Error, e.message
      end

      # @param basename [String] a module's directory name
      def used?(basename)
        @used.include?(basename)
      end

      private

      def read(probes)
        @nodes += 1
        %w[classes defined_types types providers_named type_aliases].each do |section|
          (probes[section] || {}).each_value { |v| @used << v['module'] if v.is_a?(Hash) && v['module'] }
        end
        (probes['functions'] || {}).each_value do |f|
          next unless f['module']

          @used << f['module']
          Array(f['sites']).each do |site|
            user = ::Pupgrade::Compile::ProbeRecord.module_of_site(site)
            @calls[user] << f['module'] if user && user != f['module']
          end
        end
      end
    end
  end
end
