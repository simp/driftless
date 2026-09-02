module Driftless
  module Site
    # Link templates into a git host's web interface, from a remote URL and
    # the `site.web_links` config.
    module WebLinks
      class Error < StandardError; end

      # Named URL layouts. `{base}` is https:// plus the remote's host (or the
      # config entry's base_url), `{project}` the remote's path without .git,
      # `{ref}` the ref linked at, `{ref_kind}` branch, tag, or commit.
      LAYOUTS = {
        'gitlab'   => '{base}/{project}/-/blob/{ref}/{path}#L{line}',
        'github'   => '{base}/{project}/blob/{ref}/{path}#L{line}',
        'forgejo' => '{base}/{project}/src/{ref_kind}/{ref}/{path}#L{line}',
      }.freeze

      # Layout by host when no config entry matches the remote.
      HOST_LAYOUTS = {
        'github.com'   => 'github',
        'codeberg.org' => 'forgejo',
      }.freeze

      FALLBACK_LAYOUT = 'gitlab'.freeze

      # `user@host:path` remotes; `[^/]` keeps a local path from matching.
      SCP_LIKE = %r{\A(?:[^@/]+@)?(?<host>[^:/]+):(?<project>[^/].*)\z}.freeze
      URL      = %r{\A(?:ssh|git|https?)://(?:[^@/]+@)?(?<host>[^:/]+)(?::\d+)?/(?<project>.+)\z}.freeze

      module_function

      # The template for one repo, with `{path}` and `{line}` left for the page.
      #
      # @param remote [String, nil] the git remote URL
      # @param ref [String, nil] the ref to link at; the sha stands in when nil
      # @param ref_type [String, nil] "branch", "tag", "commit", or "ref"
      # @param sha [String, nil]
      # @param config [Hash, nil] `site.web_links`
      # @return [String, nil] nil when the remote is absent or not a host URL,
      #   or when neither ref nor sha is known
      # @raise [Error] on a config entry naming an unknown layout
      def template(remote:, ref:, ref_type:, sha:, config:)
        parsed = parse_remote(remote)
        return nil unless parsed

        at = ref || sha
        return nil unless at

        entry  = entry_for(remote, parsed[:host], config)
        layout = entry['template'] || LAYOUTS[entry['layout']]
        raise Error, "site.web_links: unknown layout #{entry['layout'].inspect} for #{remote}" unless layout

        base = entry['base_url'] ? entry['base_url'].to_s.sub(%r{/+\z}, '') : "https://#{parsed[:host]}"
        layout.gsub('{base}', base).gsub('{project}', parsed[:project])
          .gsub('{ref}', at).gsub('{ref_kind}', ref ? ref_kind(ref_type) : 'commit')
      end

      # @return [Hash{host:, project:}, nil]
      def parse_remote(remote)
        return nil if remote.nil? || remote.empty?

        m = URL.match(remote) || SCP_LIKE.match(remote)
        return nil unless m

        project = m[:project].sub(%r{\A/+}, '').sub(%r{/+\z}, '').sub(/\.git\z/, '')
        project.empty? ? nil : { host: m[:host], project: project }
      end

      # The config entry for a remote, normalized to a Hash with `layout`,
      # `base_url`, `template` keys: the first `remotes` pattern that matches,
      # else `default`, else the host's known layout, else gitlab.
      def entry_for(remote, host, config)
        config ||= {}
        remotes = config['remotes'] || {}
        pattern = remotes.keys.find { |p| Regexp.new(p.to_s.sub(%r{\A/(.*)/\z}, '\1')).match?(remote) }
        return normalize(remotes[pattern]) if pattern
        return normalize(config['default']) if config['default']

        { 'layout' => HOST_LAYOUTS.fetch(host, FALLBACK_LAYOUT) }
      end

      def normalize(entry)
        entry.is_a?(Hash) ? entry.transform_keys(&:to_s) : { 'layout' => entry.to_s }
      end

      def ref_kind(ref_type)
        %w[tag commit].include?(ref_type) ? ref_type : 'branch'
      end
    end
  end
end
