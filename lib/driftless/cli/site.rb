require 'driftless/cli/base'
require 'driftless/cli/root'
require 'driftless/config_keys'
require 'driftless/report_data'
require 'driftless/scan_data'
require 'driftless/site'

module Driftless
  module CLI
    # `driftless site`
    #
    # Build the static site from the scan + report data files
    # non-zero exit status means the site was not written
    class Site < Base
      extend ::Driftless::ConfigKeys::DSL

      register_command name: 'site', subcommand_of: Root
      positional '[<scan.json>]'
      desc 'Build the static site from `scan --data-file` output (index.html + data.json)'

      config_key 'site.web_links', type: :hash,
                 example: {
                   'default' => 'gitlab',
                   'remotes' => {
                     'github\.com'       => 'github',
                     'git\.example\.com' => { 'layout' => 'forgejo', 'base_url' => 'https://git.example.com/gitea' },
                   },
                 },
                 about: 'How a git remote maps to a web URL for path:line links. `default` and each ' \
                        '`remotes` entry (a regex matched against the remote URL, first match wins) is a ' \
                        'layout name (gitlab, github, forgejo) or a mapping of layout, base_url, and ' \
                        'template ({base}/{project}/{ref}/{ref_kind}/{path}/{line}). Unmatched remotes ' \
                        'use the layout of a known host, else gitlab'

      def execute(argv)
        reject_extra_args!(argv, max: 1)
        scan_path = File.expand_path(argv.first || ::Driftless::ScanData::DEFAULT_PATH)
        out_dir   = File.expand_path(@options[:output_dir] || File.dirname(scan_path))

        data =
          begin
            ::Driftless::Site::BuildData.assemble(scan:      ::Driftless::ScanData.read(scan_path),
                                                  report:    read_report_beside(scan_path),
                                                  repo_url:  @options[:repo_url],
                                                  web_links: @options[:web_links])
          rescue ::Driftless::JsonDocument::Error, ::Driftless::Site::WebLinks::Error => e
            fatal!("site: #{e.message}", 3)
          end

        ::Driftless::Site.build(data, out_dir).each { |p| puts p }
        exit 0
      end

      protected

      def configure_parser(o)
        o.separator ''
        o.separator 'Input:'
        o.separator '    <scan.json>                      Scan data from `driftless scan --data-file` ' \
                    "(default: #{::Driftless::ScanData::DEFAULT_PATH})"
        o.separator '    A report.json beside it (from `driftless report --data-file`) joins the build.'
        o.separator ''
        o.separator 'Output:'
        o.on('-o', '--output-dir=DIR',
             'Write index.html and data.json here',
             'Default: the directory holding <scan.json>') { |v| @options[:output_dir] = v }
        o.on('--repo-url=URL',
             'Link the control repo\'s path:line here instead of at its',
             'origin remote (site.web_links). A template with {branch},',
             '{sha}, {path}, {line}; without {path}, the GitLab/GitHub',
             'suffix /{path}#L{line} is appended, so',
             'https://host/group/project/-/blob/{branch} is enough there.',
             'A detached checkout uses the sha for {branch}') { |v| @options[:repo_url] = v }
      end

      def config_defaults
        { web_links: ::Driftless.config.dig('site', 'web_links') }
      end

      private

      # Reads the report document sitting beside the scan document, when one
      # does; `report --data-file` writes it there.
      #
      # @return [Hash, nil]
      # @raise [JsonDocument::Error] on an unreadable report document
      def read_report_beside(scan_path)
        path = File.join(File.dirname(scan_path), File.basename(::Driftless::ReportData::DEFAULT_PATH))
        File.exist?(path) ? ::Driftless::ReportData.read(path) : nil
      end
    end
  end
end
