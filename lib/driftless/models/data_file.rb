module Driftless
  DataFile = Struct.new(
    :path, :tier, :top_level_keys,
    keyword_init: true,
  )
end
