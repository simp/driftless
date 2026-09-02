require 'driftless/hierarchy_interpolator'

module Driftless
  # One hierarchy: entry from hiera.yaml, as HierarchyLoader builds it.
  #
  # @!attribute [rw] name
  #   @return [String] the tier's declared name, '(unnamed)' when absent
  # @!attribute [rw] datadir
  #   @return [String] absolute datadir the templates resolve against
  # @!attribute [rw] backend
  #   @return [Symbol] the data_hash backend, e.g. :yaml_data
  # @!attribute [rw] path_templates
  #   @return [Array<String>] path/glob templates as hiera.yaml spells them
  # @!attribute [rw] interpolation_vars
  #   @return [Array<String>] variables interpolated across all templates, deduped
  # @!attribute [rw] multi_path
  #   @return [Boolean] whether a plural locator (paths:/globs:) declared them
  # @!attribute [rw] locator
  #   @return [Symbol] which location key declared the templates, :path or :glob
  # @!attribute [rw] source_line
  #   @return [Integer, nil] 1-indexed hiera.yaml line of the tier entry
  # @!attribute [rw] template_lines
  #   @return [Hash{String => Integer}, nil] 1-indexed hiera.yaml line per template
  HieraTier = Struct.new(
    :name, :datadir, :backend, :path_templates, :interpolation_vars, :multi_path,
    :locator, :source_line, :template_lines,
    keyword_init: true,
  ) do
    alias_method :multi_path?, :multi_path

    # Which Hiera location key declared these templates, :path or :glob.
    def glob?
      locator == :glob
    end

    # The hiera.yaml line of one template, falling back to the tier's own
    # line when the AST walk could not supply template lines.
    def line_for(template)
      (template_lines || {})[template] || source_line
    end

    # The variables one path interpolates, read with the regex
    # HierarchyInterpolator renders by, so the two agree on what a path reads.
    def vars_for(path)
      path.to_s.scan(HierarchyInterpolator::INTERPOLATION_RE).map { |m| m[0].strip }.uniq
    end
  end
end
