module Driftless
  Node = Struct.new(
    :certname, :facts, :trusted,
    keyword_init: true,
  )
end
