require 'driftless/hierarchy_interpolator'

module Driftless
  HieraTier = Struct.new(
    :name, :datadir, :backend, :path_templates, :interpolation_vars, :multi_path,
    :locator, :source_line,
    keyword_init: true,
  ) do
    alias_method :multi_path?, :multi_path

    # Which Hiera location key declared these templates, :path or :glob.
    def glob?
      locator == :glob
    end

    # The variables one path interpolates, read with the regex
    # HierarchyInterpolator renders by, so the two agree on what a path reads.
    def vars_for(path)
      path.to_s.scan(HierarchyInterpolator::INTERPOLATION_RE).map { |m| m[0].strip }.uniq
    end
  end
end
