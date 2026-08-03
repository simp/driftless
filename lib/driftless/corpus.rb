module Driftless
  Corpus = Struct.new(
    :repo, :hiera_tiers, :puppet_classes, :data_files, :reported, :lookup_calls, :log,
    keyword_init: true,
  )
end
