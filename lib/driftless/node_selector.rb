require 'driftless/reported'
require 'driftless/scan_error'
require 'driftless/utilization'

module Driftless
  # Picks nodes by role, environment, collector, OS, and certname.
  #
  # Every criterion is a list; a node passes a criterion when it matches any
  # entry, and passes the selector when it passes every criterion given. A
  # node matching any exclusion glob is dropped whatever else it matches.
  class NodeSelector
    CLASSES_REPORT = 'classes-for-all-active-nodes'.freeze

    attr_reader :roles, :environments, :collectors, :os, :certname_globs, :exclude_certname_globs

    # @param roles [Array<String>] role class fqnames, File.fnmatch globs,
    #   case-insensitive
    # @param environments [Array<String>] exact environment names
    # @param collectors [Array<String>] exact collector names
    # @param os [Array<String>] matched case-insensitively against the
    #   `os.name` and `os.family` facts
    # @param certname_globs [Array<String>] File.fnmatch globs
    # @param exclude_certname_globs [Array<String>] File.fnmatch globs; a
    #   node matching any is dropped
    def initialize(roles: [], environments: [], collectors: [], os: [], certname_globs: [],
                   exclude_certname_globs: [])
      @roles                  = Array(roles)
      @environments           = Array(environments)
      @collectors             = Array(collectors)
      @os                     = Array(os)
      @certname_globs         = Array(certname_globs)
      @exclude_certname_globs = Array(exclude_certname_globs)
    end

    def empty?
      [roles, environments, collectors, os, certname_globs, exclude_certname_globs].all?(&:empty?)
    end

    # @param nodes [Array<Node>] rows of any node report
    # @param reported [Reported] where the classes report is read from when
    #   roles are given
    # @return [Array<Node>] the nodes passing every criterion, in input order
    # @raise [ScanError] when roles are given and the classes report is absent
    def select(nodes, reported)
      roles_of = roles_by_certname(reported)
      nodes.select do |node|
        certname = node.certname.to_s
        exclude_certname_globs.none? { |g| File.fnmatch?(g, certname) } &&
          match_any?(certname_globs) { |g| File.fnmatch?(g, certname) } &&
          match_any?(environments) { |e| e == node.environment } &&
          match_any?(collectors) { |c| c == node.collector } &&
          match_any?(os) { |o| os_names(node).include?(o.downcase) } &&
          match_any?(roles) { |r| roles_of.fetch(node.certname, []).any? { |n| File.fnmatch?(r.downcase, n) } }
      end
    end

    # The roles each node is classified with, from the classes report.
    #
    # @return [Hash{String => Array<String>}] certname => downcased role fqnames
    def roles_by_certname(reported)
      return {} if roles.empty?
      if reported.missing?(CLASSES_REPORT)
        raise ScanError, "selecting by role needs the #{CLASSES_REPORT} report, which is not loaded"
      end
      reported.report(CLASSES_REPORT).to_h do |node|
        [node.certname, Utilization.names(node, 'roles')]
      end
    end

    private

    # An empty criterion passes everything.
    def match_any?(values)
      values.empty? || values.any? { |v| yield(v) }
    end

    def os_names(node)
      [node.fact('os.name'), node.fact('os.family')].compact.map { |v| v.to_s.downcase }
    end
  end
end
