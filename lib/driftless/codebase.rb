require 'driftless/class_extractor'
require 'driftless/corpus'
require 'driftless/inputs/datadir_loader'
require 'driftless/inputs/epp_parser'
require 'driftless/inputs/hierarchy_loader'
require 'driftless/inputs/manifest_parser'
require 'driftless/inputs/module_data_loader'
require 'driftless/inputs/modulepath_loader'
require 'driftless/inputs/puppetfile'
require 'driftless/logger'
require 'driftless/lookup_calls'
require 'driftless/phases'
require 'driftless/reported'

module Driftless
  # What a control repo's code and data declare: the half of a scan that
  # needs no PuppetDB reports. The hierarchy, every class with its params,
  # the Hiera data files and module data keys, the lookup() calls in
  # manifests, templates, and data values, and the Puppetfile.
  class Codebase
    include Phases

    # What {Codebase.load} returns. The first seven fields are the {Corpus}
    # fields of the same name.
    #
    # @!attribute [r] findings
    #   @return [Array<Finding>] what loading reported: a missing hiera.yaml
    #     or modulepath entry, a manifest or template that did not parse, a
    #     data file that could not be read
    # @!attribute [r] warnings
    #   @return [Array<String>] a Puppetfile that did not evaluate
    Result = Data.define(:hiera_tiers, :puppet_classes, :data_files, :module_data_keys,
                         :code_lookup_calls, :data_lookup_calls, :puppetfile, :findings, :warnings) do
      # @param repo_dir [String] the repo loaded
      # @param reported [Reported] the reports to read beside the code; none
      #   by default
      # @return [Corpus]
      def corpus(repo_dir:, reported: Reported.new)
        Corpus.new(repo_dir: repo_dir, hiera_tiers: hiera_tiers, puppet_classes: puppet_classes,
                   data_files: data_files, module_data_keys: module_data_keys, reported: reported,
                   code_lookup_calls: code_lookup_calls, data_lookup_calls: data_lookup_calls,
                   puppetfile: puppetfile)
      end
    end

    # Where EPP templates are looked for, relative to the repo.
    TEMPLATE_DIRS = %w[site-modules modules].freeze

    # @param repo_dir [String] the control repo environment
    # @return [Result]
    def self.load(repo_dir)
      new(repo_dir).load
    end

    def initialize(repo_dir)
      @repo_dir = repo_dir
    end

    # @return [Result]
    def load
      findings = []
      warnings = []

      hiera_tiers, hl_findings = phase('hierarchy load') { Inputs::HierarchyLoader.load(@repo_dir) }
      findings.concat(hl_findings)
      Driftless.logger.info("Loaded #{hiera_tiers.size} hierarchy tiers")

      manifest_files, mpl_findings = phase('manifest discovery') { Inputs::ModulepathLoader.load(@repo_dir) }
      findings.concat(mpl_findings)
      Driftless.logger.info("Discovered #{manifest_files.size} Puppet manifest files")

      puppetfile = phase('Puppetfile load') { Inputs::Puppetfile.load(@repo_dir) }
      warnings << "Puppetfile not evaluated: #{puppetfile.error}" if puppetfile.error
      Driftless.logger.info("Read #{puppetfile.modules.size} module declarations from the Puppetfile") if puppetfile.exists?

      puppet_classes    = {}
      code_lookup_calls = []
      phase('manifest parsing') do
        manifest_files.each do |path|
          program, errs = Inputs::ManifestParser.parse(path)
          findings.concat(errs)
          next unless program

          ClassExtractor.extract(program: program, file: path).each { |cls| puppet_classes[cls.fqname] = cls }
          code_lookup_calls.concat(LookupCallExtractor.extract(program: program, file: path))
        end
      end
      Driftless.logger.info("Extracted #{puppet_classes.size} classes and #{code_lookup_calls.size} lookup calls from manifests")

      epp_paths = epp_templates
      phase('EPP template scan') do
        epp_paths.each do |path|
          program, errs = Inputs::EppParser.parse(path)
          findings.concat(errs)
          next unless program

          code_lookup_calls.concat(LookupCallExtractor.extract(program: program, file: path))
        end
      end
      Driftless.logger.info("Scanned #{epp_paths.size} EPP templates")

      data_files, dl_findings = phase('data file load') { Inputs::DatadirLoader.load(hiera_tiers) }
      findings.concat(dl_findings)
      Driftless.logger.info("Loaded #{data_files.size} Hiera data files")

      module_data_keys = phase('module data load') do
        Inputs::ModuleDataLoader.load(Inputs::ModulepathLoader.module_dirs(@repo_dir))
      end
      Driftless.logger.info("Loaded #{module_data_keys.size} keys from module data")

      data_lookup_calls = phase('lookup extraction from Hiera data') do
        data_files.select { |df| File.file?(df.path) }
          .flat_map { |df| LookupCallExtractor.extract_from_yaml_values(df.value_lines, df.path) }
      end

      Result.new(hiera_tiers: hiera_tiers, puppet_classes: puppet_classes, data_files: data_files,
                 module_data_keys: module_data_keys, code_lookup_calls: code_lookup_calls,
                 data_lookup_calls: data_lookup_calls, puppetfile: puppetfile,
                 findings: findings, warnings: warnings)
    end

    private

    def epp_templates
      TEMPLATE_DIRS.flat_map do |rel|
        dir = File.join(@repo_dir, rel)
        next [] unless File.directory?(dir)

        Dir[File.join(dir, '*/templates/**/*.epp')]
      end
    end
  end
end
