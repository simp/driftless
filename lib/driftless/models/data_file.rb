module Driftless
  DataFile = Struct.new(
    :path, :tier, :top_level_keys, :key_lines,
    keyword_init: true,
  )
end
