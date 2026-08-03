module Driftless
  PuppetClass = Struct.new(
    :fqname, :file, :params, :role, :profile,
    keyword_init: true,
  ) do
    alias_method :role?, :role
    alias_method :profile?, :profile
  end
end
