module Driftless
  # Metadata about one Hiera data file (YAML under some tier's datadir).
  # Kept as a Struct rather than {Data} because {#source} memoizes its
  # first-read value into `@source` — Data instances are frozen and cannot
  # accept post-construction ivar assignment.
  #
  # @!attribute [r] path
  #   @return [String] Absolute path to the YAML file on disk.
  # @!attribute [r] top_level_keys
  #   @return [Hash{String => Integer}] Top-level keys mapped to their
  #     1-indexed source line numbers, extracted at load time.
  HieraDataFileInfo = Struct.new(:path, :top_level_keys, keyword_init: true) do
    # @param source [String, nil] If provided, primes the {#source} cache to
    #   avoid an I/O read later. {Inputs::DatadirLoader} uses this because it
    #   already reads the file's source to extract top_level_keys — no reason
    #   to re-read on the first {#source} call.
    def initialize(source: nil, **kwargs)
      super(**kwargs)
      @source = source
    end

    # Raw YAML text of the file. Memoized: reads the file on first call,
    # returns cached value thereafter. Zero I/O when `source:` was passed at
    # construction (as {Inputs::DatadirLoader} does).
    #
    # @return [String] Raw YAML source text.
    def source
      @source ||= File.read(path)
    end
  end
end
