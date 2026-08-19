module Driftless
  module Inputs
    class EnvironmentConf
      def self.load(repo_dir)
        new(repo_dir).load
      end

      def initialize(repo_dir)
        @path = File.join(repo_dir, 'environment.conf')
      end

      def load
        return Result.new(exists: false) unless File.file?(@path)
        parsed = parse(File.read(@path))
        Result.new(
          exists:     true,
          modulepath: parsed['modulepath']&.split(':')&.map(&:strip)&.reject(&:empty?),
          manifest:   parsed['manifest'],
        )
      end

      private

      # environment.conf is bare `key = value` lines with `#`/`;` comments —
      # no `[sections]`, so full INI parsers overshoot. Values keep whitespace
      # only around commas; drop leading/trailing whitespace per side.
      def parse(source)
        source.each_line.with_object({}) do |line, acc|
          line = line.sub(/[#;].*$/, '').strip
          next if line.empty?
          key, _, val = line.partition('=')
          next if val.empty?
          acc[key.strip] = val.strip
        end
      end

      Result = Struct.new(:exists, :modulepath, :manifest, keyword_init: true) do
        def exists?; 
          exists
        end
      end
    end
  end
end
