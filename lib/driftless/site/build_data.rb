require 'time'

require 'driftless/version'
require 'driftless/json_document'
require 'driftless/logger'
require 'driftless/site/web_links'

module Driftless
  # The static site `driftless site` builds from the other commands' documents.
  module Site
    # The data one site build consumes: the scan document and, when present,
    # the report document, munged into a single JSON-ready Hash. The two must
    # describe the same collector sessions; {assemble} refuses otherwise.
    # Embedded in index.html and written beside it as data.json.
    module BuildData
      DOCUMENT       = 'site'.freeze
      SCHEMA_VERSION = 1

      module_function

      # @param scan [Hash] a document from {ScanData.read}
      # @param report [Hash, nil] a document from {ReportData.read}, when
      #   `report --data-file` wrote one; it contributes `utilization` and
      #   `nodes`, and must agree with scan on sessions
      # @param repo_url [String, nil] the control repo's link template, given
      #   by hand; see {web_template}
      # @param web_links [Hash, nil] the `site.web_links` config, for
      #   templates derived from remotes; see {WebLinks}
      # @param now [Time] stamp for `generated_at`; injectable for specs
      # @raise [JsonDocument::Error] when scan and report disagree
      # @raise [WebLinks::Error] on a web_links entry naming an unknown layout
      def assemble(scan:, report: nil, repo_url: nil, web_links: nil, now: Time.now)
        check_agreement!(scan, report) if report
        {
          'document'          => DOCUMENT,
          'schema_version'    => SCHEMA_VERSION,
          'generated_at'      => now.utc.iso8601,
          'driftless_version' => VERSION,
          'sources'           => { 'scan' => stamp(scan), 'report' => report && stamp(report) },
          'repo'              => repo_with_links(scan['repo'] || {}, repo_url, web_links),
          'environments'      => scan.fetch('environments', []),
          'overrides'         => scan.fetch('overrides', {}),
          'sessions'          => scan.fetch('sessions', []),
          'nodes'             => (report && report['nodes']) || scan['nodes'],
          'findings'          => scan.fetch('findings', []),
          'utilization'       => report && report['utilization'],
          'warnings'          => scan.fetch('warnings', []),
        }
      end

      def write(data, path)
        JsonDocument.write(data, path)
      end

      # @raise [JsonDocument::Error]
      def read(path)
        JsonDocument.read(path, document: DOCUMENT, schema_version: SCHEMA_VERSION)
      end

      # The scan document's repo with a `web` link template on it and on each
      # deployment: where the page links a path:line under that repo, or nil.
      #
      # @param repo_url [String, nil] overrides the control repo's derived
      #   template
      def repo_with_links(repo, repo_url, config)
        deployments = (repo['deployments'] || {}).to_h do |path, d|
          [path, d.merge('web' => WebLinks.template(remote: d['remote'], ref: d['ref'], ref_type: d['ref_type'],
                                                    sha: d['sha'], config: config))]
        end
        repo.merge('web' => control_web(repo_url, repo['git'], config), 'deployments' => deployments)
      end

      # The control repo's template: from repo_url when given, else derived
      # from its remote at its branch (the sha on a detached checkout).
      def control_web(repo_url, git, config)
        return web_template(repo_url, git) if repo_url && !repo_url.strip.empty?
        return nil unless git

        branch = (git['branch'] == 'HEAD') ? nil : git['branch']
        WebLinks.template(remote: git['remote'], ref: branch, ref_type: 'branch', sha: git['sha'], config: config)
      end

      # The link template `--repo-url` gives for a file in the control repo's
      # web interface. Four variables: `{branch}` and `{sha}` are filled here
      # from the scan document's revision; `{path}` and `{line}` are left for
      # the page to fill per finding. A template without `{path}` gets
      # `/{path}#L{line}` appended — the GitLab/GitHub layout — so the common
      # case is just the blob base, `https://host/group/project/-/blob/{branch}`.
      #
      # A detached checkout (CI) reports its branch as "HEAD", which no host
      # resolves, so `{branch}` falls back to the sha. With no revision to
      # fill from, there is no usable link and `web` is null.
      def web_template(repo_url, git)
        return nil if repo_url.nil? || repo_url.strip.empty?

        url = repo_url.strip
        url = "#{url.sub(%r{/+\z}, '')}/{path}#L{line}" unless url.include?('{path}')
        return url unless url.include?('{branch}') || url.include?('{sha}')

        sha    = git && git['sha']
        branch = git && git['branch']
        branch = sha if branch.nil? || branch == 'HEAD'
        unless sha
          Driftless.logger.warn('site: --repo-url uses {branch} or {sha}, but the scan document carries no git revision; not linking')
          return nil
        end
        url.gsub('{branch}', branch).gsub('{sha}', sha)
      end

      # When and by which version a source document was written.
      def stamp(doc)
        { 'generated_at' => doc['generated_at'], 'driftless_version' => doc['driftless_version'] }
      end

      # Two documents agree when they read the same (collector, session_id)
      # pairs: the session is the transactional unit, so anything else means
      # the incoming tree changed between the two runs.
      def check_agreement!(scan, report)
        a = session_keys(scan)
        b = session_keys(report)
        return if a == b

        raise JsonDocument::Error,
              'scan and report data disagree on sessions: ' \
              "scan read #{format_sessions(a - b)}, report read #{format_sessions(b - a)}"
      end

      def session_keys(doc)
        doc.fetch('sessions', []).map { |s| [s['collector'], s['session_id']] }.sort
      end

      def format_sessions(keys)
        keys.empty? ? 'nothing the other did not' : keys.map { |c, id| "#{c}@#{id}" }.join(', ')
      end
    end
  end
end
