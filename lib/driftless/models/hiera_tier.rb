module Driftless
  HieraTier = Struct.new(
    :name, :datadir, :backend, :path_templates, :interpolation_vars, :multi_path,
    keyword_init: true,
  ) do
    alias_method :multi_path?, :multi_path
  end
end
