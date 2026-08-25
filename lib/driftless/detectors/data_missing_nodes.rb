require 'set'

require 'driftless/detectors/callable'

module Driftless
  module Detectors
    class DataMissingNodes < Callable
      key      'data:paths-for-unreported-nodes'
      severity :warning
      quality  :stale
      about 'Hiera files matching certnames not present in report:all-active-nodes'
      requires_reports 'all-active-nodes'

      NODE_CERTNAME_VARS = %w[trusted.certname facts.fqdn facts.hostname clientcert].freeze

      GLOB_TOKEN_RE = %r{(\*\*/|\*\*|\*|\?|\{[^{}]*\}|\[[^\]]*\])}.freeze

      def call
        if corpus.reported.missing?('all-active-nodes')
          return [skip_meta_finding(reason: 'no report:all-active-nodes data')]
        end

        active_certnames = Array(corpus.reported.report('all-active-nodes')).map(&:certname).to_set
        findings         = []

        corpus.hiera_tiers.each do |tier|
          tier.path_templates.each do |template|
            next unless template_has_certname_var?(template)

            regex = template_to_regex(template, glob: tier.glob?)
            each_matching_file(tier.datadir, template) do |file|
              rel = file.sub(File.join(tier.datadir, ''), '')
              match = rel.match(regex)
              next unless match
              certname = match[:certname]
              next if active_certnames.include?(certname)

              findings << build_finding(
                path:    file,
                message: "#{certname.inspect} was not reported as an active node",
                meta:    { certname: certname, tier: tier.name },
              )
            end
          end
        end
        findings
      end

      private

      def template_has_certname_var?(template)
        NODE_CERTNAME_VARS.any? { |v| template.include?("%{#{v}}") }
      end

      def each_matching_file(datadir, template)
        glob = template.gsub(/%\{[^{}]+\}/, '*')
        Dir[File.join(datadir, glob)].each { |f| yield f }
      end

      # Splitting on %{...} puts each brace of `{%{a},b}` in a different part,
      # so glob_to_regex reads neither as alternation. That template matches no
      # file, and the caller skips a file it cannot match.
      def template_to_regex(template, glob: false)
        parts = template.split(/(%\{[^{}]+\})/)
        regex_str = parts.map { |part|
          if (m = part.match(/\A%\{([^{}]+)\}\z/))
            NODE_CERTNAME_VARS.include?(m[1]) ? '(?<certname>[^/]+)' : '[^/]+'
          elsif glob
            glob_to_regex(part)
          else
            Regexp.escape(part)
          end
        }.join
        Regexp.new("\\A#{regex_str}\\z")
      end

      # Glob metacharacters as Hiera reads them, since a glob tier's template
      # carries them where a path's would be a literal filename. Dir[] has
      # already chosen the files this runs against, so the translation only has
      # to keep the certname capture in the right place.
      def glob_to_regex(part)
        part.split(GLOB_TOKEN_RE).map { |token|
          case token
          when '**/' then '(?:[^/]+/)*'
          when '**'  then '.*'
          when '*'   then '[^/]*'
          when '?'   then '[^/]'
          when /\A\{(.*)\}\z/m
            "(?:#{Regexp.last_match(1).split(',').map { |alt| Regexp.escape(alt) }.join('|')})"
          when /\A\[.*\]\z/m then token
          else Regexp.escape(token)
          end
        }.join
      end
    end
  end
end
