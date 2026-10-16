require 'yaml'

require 'driftless/config_keys'
require 'driftless/inputs/puppetfile'

module Driftless
  module Inputs
    # Reads and writes a branchfile: the branch to follow for each module,
    # for modules whose Puppetfile entry pins a tag or commit. Either a
    # YAML mapping of module name to branch, or a Puppetfile overlay whose
    # `mod` entries carry `:branch`.
    class Branchfile
      extend ConfigKeys::DSL

      config_key 'modules.branchfile', type: :string, default: nil, example: 'branches.yaml',
                 about: 'A file naming the branch to follow per module, relative to the control repo: ' \
                        'YAML of module name to branch, or a Puppetfile overlay of `mod` entries with :branch. ' \
                        '`modules gitlog` reads it for a module given no ref'

      YAML_EXTENSIONS = %w[.yaml .yml].freeze

      # @!attribute [r] exists
      #   @return [Boolean] whether the file was there
      # @!attribute [r] branches
      #   @return [Hash{String => String}] module name, with "/" as "-" and
      #     lowercased, to branch
      # @!attribute [r] warnings
      #   @return [Array<String>] entries that named no branch
      # @!attribute [r] error
      #   @return [String, nil] why the file could not be read
      Result = Data.define(:exists, :branches, :warnings, :error) do
        def exists?
          exists
        end

        # The branch for a module: by its full name in either spelling, else
        # by the last segment, so "stdlib" finds "puppetlabs/stdlib" and the
        # other way round.
        #
        # @param name [String] e.g. "puppetlabs-stdlib" or "stdlib"
        # @return [String, nil]
        def branch_for(name)
          key = name.to_s.tr('/', '-').downcase
          return branches[key] if branches.key?(key)

          short = key.split('-').last
          branches.find { |k, _| k.split('-').last == short }&.last
        end
      end

      # @param path [String]
      # @return [Result]
      def self.load(path)
        return Result.new(exists: false, branches: {}, warnings: [], error: nil) unless File.file?(path)

        YAML_EXTENSIONS.include?(File.extname(path).downcase) ? from_yaml(path) : from_puppetfile(path)
      end

      # Records a module's branch, replacing an entry for the module in
      # either spelling and creating the file when it is absent. A YAML
      # file is rewritten whole; a Puppetfile overlay has one `mod` line
      # replaced or appended, the rest of its text untouched.
      #
      # @param path [String]
      # @param name [String] the module's declared name
      # @param branch [String]
      # @return [String] path
      # @raise [Error] when the file cannot be read as a branchfile
      def self.record(path, name, branch)
        if YAML_EXTENSIONS.include?(File.extname(path).downcase)
          current = load(path)
          raise Error, current.error if current.error

          data = File.file?(path) ? YAML.safe_load(File.read(path), aliases: true, filename: path) || {} : {}
          data.delete_if { |k, _| normalize(k) == normalize(name) }
          File.write(path, YAML.dump(data.merge(name.to_s => branch.to_s)))
        else
          lines = File.file?(path) ? File.readlines(path) : []
          entry = "mod '#{name}', :branch => '#{branch}'\n"
          index = lines.index { |l| (m = l.match(/\A\s*mod\s+['"]([^'"]+)['"]/)) && normalize(m[1]) == normalize(name) }
          index ? lines[index] = entry : lines << entry
          File.write(path, lines.join)
        end
        path
      end

      class Error < StandardError; end

      def self.from_yaml(path)
        data = YAML.safe_load(File.read(path), aliases: true, filename: path)
        return failed(path, "expected a mapping of module name to branch, got #{data.class}") unless data.is_a?(Hash)

        branches = data.to_h { |name, branch| [normalize(name), branch.to_s] }
        Result.new(exists: true, branches: branches, warnings: [], error: nil)
      rescue Psych::SyntaxError, Psych::BadAlias => e
        failed(path, e.message)
      end

      def self.from_puppetfile(path)
        result = Puppetfile.load_file(path)
        return failed(path, result.error) if result.error

        branches = {}
        warnings = []
        result.modules.each do |m|
          if m.ref_type == 'branch' && m.ref.is_a?(String)
            branches[normalize(m.name)] = m.ref
          else
            warnings << "#{path}: #{m.name} names no :branch; ignored"
          end
        end
        Result.new(exists: true, branches: branches, warnings: warnings, error: nil)
      end

      def self.failed(path, message)
        Result.new(exists: true, branches: {}, warnings: [], error: "#{path}: #{message}")
      end

      def self.normalize(name)
        name.to_s.tr('/', '-').downcase
      end
    end
  end
end
