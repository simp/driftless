require 'driftless/cli/base'
require 'driftless/cli/root'
require 'driftless/scan_data'
require 'driftless/site'

module Driftless
  module CLI
    # `driftless site`: build the static site from the scan data document
    # that `driftless scan --data-file` wrote. It runs no
    # scan and takes none of scan's options; its exit status says only
    # whether the site was written.
    class Site < Base
      register_command name: 'site', subcommand_of: Root
      positional '[<scan.json>]'
      desc 'Build the static site from `scan --data-file` output (index.html + data.json)'

      def execute(argv)
        reject_extra_args!(argv, max: 1)
        scan_path = File.expand_path(argv.first || ::Driftless::ScanData::DEFAULT_PATH)
        out_dir   = File.expand_path(@options[:output_dir] || File.dirname(scan_path))

        data =
          begin
            ::Driftless::Site::BuildData.assemble(scan: ::Driftless::ScanData.read(scan_path),
                                                  repo_url: @options[:repo_url])
          rescue ::Driftless::JsonDocument::Error => e
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
        o.separator ''
        o.separator 'Output:'
        o.on('-o', '--output-dir=DIR',
             'Write index.html and data.json here',
             'Default: the directory holding <scan.json>') { |v| @options[:output_dir] = v }
        o.on('--repo-url=URL',
             'Link each path:line to the repo\'s web interface. A template',
             'with {branch}, {sha}, {path}, {line}; without {path}, the',
             'GitLab/GitHub suffix /{path}#L{line} is appended, so',
             'https://host/group/project/-/blob/{branch} is enough there.',
             'A detached checkout uses the sha for {branch}') { |v| @options[:repo_url] = v }
      end
    end
  end
end
