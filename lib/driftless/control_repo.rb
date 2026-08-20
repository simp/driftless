require 'driftless/config_keys'

module Driftless
  # The Puppet control repo environment under examination: where it is, and how
  # to recognize one.
  #
  # repo_dir is deliberately absent from driftless.yaml. A user or system config
  # naming a repo would follow the operator between control repos and silently
  # scan the wrong one, so it stays per-invocation (`--repo-dir`).
  class ControlRepo
    extend ConfigKeys::DSL

    withheld_key %w[scan.repo_dir reports.repo_dir puppet.repo_dir],
                 because: 'the repo under examination is per-invocation — a user or system ' \
                          'config naming one would follow you between control repos and ' \
                          'silently scan the wrong one. Use --repo-dir.'

    # A directory is a control repo environment when it carries both of these.
    MARKERS = %w[hiera.yaml environment.conf].freeze

    # Conventional location of the raw-report tree relative to the repo.
    INCOMING_DIRNAME = 'incoming'.freeze

    attr_reader :dir

    def self.markers?(dir)
      MARKERS.all? { |m| File.exist?(File.join(dir, m)) }
    end

    # The control repo at `cwd`, or nil when cwd is not one.
    def self.detect(cwd)
      markers?(cwd) ? new(cwd) : nil
    end

    def initialize(dir)
      @dir = File.expand_path(dir)
    end

    def readable?
      File.directory?(@dir)
    end

    # The conventional report tree inside this repo, or nil when absent.
    def default_incoming_dir
      candidate = File.join(@dir, INCOMING_DIRNAME)
      File.directory?(candidate) ? candidate : nil
    end

    def to_s
      @dir
    end
  end
end
