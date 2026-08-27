require 'erb'
require 'fileutils'
require 'json'

require 'driftless/site/build_data'

module Driftless
  # Builds the static site from {Site::BuildData}: one self-contained
  # `index.html` (stylesheet, script, and the build data all inlined, so the
  # page opens from file://, a downloaded artifact, or any static host) and
  # the same data beside it as `data.json` for other tooling.
  module Site
    TEMPLATE_DIR = File.expand_path('site/templates', __dir__)
    INDEX_FILE   = 'index.html'.freeze
    DATA_FILE    = 'data.json'.freeze

    # id of the <script type="application/json"> element carrying the data.
    DATA_ELEMENT_ID = 'driftless-data'.freeze

    module_function

    # Writes the site into dir, creating it as needed.
    #
    # @param data [Hash] from {BuildData.assemble}
    # @param dir [String] output directory
    # @return [Array<String>] the paths written, index first
    def build(data, dir)
      FileUtils.mkdir_p(dir)
      index_path = File.join(dir, INDEX_FILE)
      data_path  = BuildData.write(data, File.join(dir, DATA_FILE))
      File.write(index_path, render(data))
      [index_path, data_path]
    end

    # The complete index.html for data.
    def render(data)
      Page.new(data).render
    end

    # The JSON escape for `<` (backslash, u, 0, 0, 3, c), spelled from the
    # codepoint so no source-level backslash escape is involved.
    ESCAPED_LT = "#{92.chr}u003c".freeze

    # JSON safe to place inside a <script> element: every `<` is written as
    # {ESCAPED_LT}, which JSON.parse reads back as `<`, so no value can close
    # the element (`</script>`) or open a comment (`<!--`).
    def embed_json(data)
      JSON.generate(data).gsub('<', ESCAPED_LT)
    end

    # The binding the index template renders against.
    class Page
      include ERB::Util

      attr_reader :data

      def initialize(data)
        @data = data
      end

      def render
        ERB.new(template('index.html.erb'), trim_mode: '-').result(binding)
      end

      def title
        dir = data.dig('repo', 'dir')
        dir ? "driftless — #{File.basename(dir)}" : 'driftless'
      end

      def embedded_json
        Site.embed_json(data)
      end

      # "branch @ sha", or "-" when the repo is not under git.
      def revision
        git = data.dig('repo', 'git')
        git ? [git['branch'], git['sha']].compact.join(' @ ') : '-'
      end

      def environment_list
        list = data.fetch('environments', [])
        list.empty? ? '-' : list.join(', ')
      end

      def data_element_id
        DATA_ELEMENT_ID
      end

      def stylesheet
        template('site.css')
      end

      def script
        template('site.js')
      end

      def findings
        data.fetch('findings', [])
      end

      # "path:line", "path", or "-" — as the text writer renders a location.
      def location(finding)
        path = finding['path']
        return '-' unless path
        finding['line'] ? "#{path}:#{finding['line']}" : path
      end

      private

      def template(name)
        File.read(File.join(TEMPLATE_DIR, name))
      end
    end
  end
end
