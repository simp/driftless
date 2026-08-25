require 'psych'

module Driftless
  # Metadata about one Hiera data file (YAML under some tier's datadir).
  # Kept as a Struct rather than {Data} because {#source} and {#value_lines}
  # memoize their first-read value into ivars — Data instances are frozen
  # and cannot accept post-construction ivar assignment.
  #
  # @!attribute [rw] path
  #   @return [String] Absolute path to the YAML file on disk.
  # @!attribute [rw] top_level_keys
  #   @return [Hash{String => Integer}] Top-level keys mapped to their
  #     1-indexed source line numbers, extracted at load time.
  HieraDataFileInfo = Struct.new(:path, :top_level_keys, keyword_init: true) do
    # @param source [String, nil] If provided, primes the {#source} cache to
    #   avoid an I/O read later. {Inputs::DatadirLoader} uses this because it
    #   already reads the file's source to extract top_level_keys — no reason
    #   to re-read on the first {#source} call.
    # @param value_lines [Array<Array(String, Integer)>, nil] If provided,
    #   primes the {#value_lines} cache to avoid a second parse later.
    def initialize(source: nil, value_lines: nil, **kwargs)
      super(**kwargs)
      @source      = source
      @value_lines = value_lines
    end

    # Raw YAML text of the file. Memoized: reads the file on first call,
    # returns cached value thereafter. Zero I/O when `source:` was passed at
    # construction (as {Inputs::DatadirLoader} does).
    #
    # @return [String] Raw YAML source text.
    def source
      @source ||= File.read(path)
    end

    # Every line of every scalar value in the file, paired with its 1-indexed
    # source line; mapping keys are not included. Memoized: parses {#source}
    # on first call unless `value_lines:` was passed at construction.
    #
    # @return [Array<Array(String, Integer)>]
    def value_lines
      @value_lines ||= self.class.value_lines_from(Psych.parse_stream(source, filename: path))
    end

    # Line numbers are exact for single-line and literal (`|`) scalars; the
    # parser folds the line breaks of folded (`>`) and multi-line quoted
    # scalars, so their lines all report the scalar's first source line.
    #
    # @param stream [Psych::Nodes::Stream]
    # @return [Array<Array(String, Integer)>] `[text, lineno]` per scalar value line.
    def self.value_lines_from(stream)
      out = []
      stream.children.each { |doc| collect_value_lines(doc.root, out) }
      out
    end

    BLOCK_STYLES = [Psych::Nodes::Scalar::LITERAL, Psych::Nodes::Scalar::FOLDED].freeze

    def self.collect_value_lines(node, out)
      case node
      when Psych::Nodes::Scalar
        first = node.start_line + 1
        first += 1 if BLOCK_STYLES.include?(node.style)
        node.value.each_line.with_index(first) { |text, lineno| out << [text, lineno] }
      when Psych::Nodes::Mapping
        node.children.each_slice(2) { |_key, value| collect_value_lines(value, out) }
      when Psych::Nodes::Sequence
        node.children.each { |child| collect_value_lines(child, out) }
      end
    end
    private_class_method :collect_value_lines
  end
end
