module Driftless
  LookupCall = Struct.new(
    :key, :file, :line, :has_default,
    keyword_init: true,
  ) do
    alias_method :has_default?, :has_default
  end
end
