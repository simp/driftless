module Driftless
  # Metadata about one Hiera data file (YAML under some tier's datadir).
  # Holds the file's path, its extracted top-level keys with source line numbers,
  # and an on-demand memoized raw source string.
  HieraDataFileInfo = Struct.new(:path, :top_level_keys, keyword_init: true) do
    def initialize(source: nil, **kwargs)
      super(**kwargs)
      @source = source
    end

    def source
      @source ||= File.read(path)
    end
  end
end
