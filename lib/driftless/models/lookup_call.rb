module Driftless
  # One Hiera lookup found in the codebase, from a `.pp`/`.epp` function call
  # or a `%{...}` interpolation in a data file.
  #
  # @!attribute [rw] key
  #   @return [String] the Hiera key looked up; always a literal
  # @!attribute [rw] function
  #   @return [String] which function made the call: `lookup`, `hiera`, or
  #     (data files only) `alias`
  # @!attribute [rw] file
  #   @return [String] path of the file holding the call
  # @!attribute [rw] line
  #   @return [Integer] 1-indexed line of the call
  # @!attribute [rw] has_default
  #   @return [Boolean] whether the call supplies a default value. Always
  #     false for data-file interpolations, whose syntax cannot carry one
  LookupCall = Struct.new(
    :key, :function, :file, :line, :has_default,
    keyword_init: true,
  ) do
    alias_method :has_default?, :has_default
  end
end
