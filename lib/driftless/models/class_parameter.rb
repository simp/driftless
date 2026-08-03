module Driftless
  ClassParameter = Struct.new(
    :name, :default_expr, :type_expr,
    keyword_init: true,
  )
end
