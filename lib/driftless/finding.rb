module Driftless
  Finding = Struct.new(
    :key, :path, :line, :message, :meta,
    keyword_init: true,
  )
end
