require 'date'

namespace :changelog do
  REPO_SLUG = 'op-ct/driftless'

  require 'date'

  desc "Promote Unreleased changes to a new SemVer release in CHANGELOG.md"
  task :release, [:version] do |t, args|
    new_version = args[:version]
    
    if new_version.nil? || new_version.strip.empty?
      abort "ERROR: You must specify a version. Example: rake release"
    end
    
    # Clean semantic version syntax (strips leading 'v' if provided)
    new_version = new_version.sub(/^v/, '')
    unless new_version =~ /^\d+\.\d+\.\d+(-[a-zA-Z0-9.]+)?$/
      abort "ERROR: '#{new_version}' is not a valid Semantic Versioning string."
    end

    changelog_file = "CHANGELOG.md"
    unless File.exist?(changelog_file)
      abort "ERROR: #{changelog_file} not found in the current directory."
    end

    puts "Processing #{changelog_file} for release v#{new_version}..."
    content = File.read(changelog_file)

    # --- 1. Relaxed Footnote Reference Matching ---
    base_url = "https://github.com/#{REPO_SLUG}"
    
    # Match 1: /compare diff tracking (e.g., .../compare/v1.1.2...HEAD)
    comparison_regex = /^\[unreleased\]:\s*#{Regexp.escape(base_url)}\/compare\/v([\d.]+)\.\.\.HEAD$/i
    
    # Match 2: Initial versionless link (`[unreleased]: https://github.com`)
    initial_regex = /^\[unreleased\]:\s*#{Regexp.escape(base_url)}\/?$/i

    previous_version = nil
    matched_regex = nil

    if content =~ comparison_regex
      previous_version = content.scan(comparison_regex).flatten.first
      matched_regex = comparison_regex
    elsif content =~ initial_regex
      matched_regex = initial_regex # Leaves previous_version as nil for initial release
    else
      abort "ERROR: Could not find a valid '[unreleased]' footnote matching your repository URL format."
    end

    today = Date.today.iso8601 # Outputs YYYY-MM-DD

    # --- 2. Update Headers (Promote Unreleased section) ---
    old_header = "## [Unreleased]"
    new_header = "## [Unreleased]\n\n## [#{new_version}] - #{today}"
    
    unless content.include?(old_header)
      abort "ERROR: Could not find '## [Unreleased]' section header in your file."
    end
    content.sub!(old_header, new_header)

    # --- 3. Update Footnotes References ---
    new_unreleased_line = "[unreleased]: #{base_url}/compare/v#{new_version}...HEAD"
    
    # Build historical reference link
    historical_comparison_line = if previous_version
      # Standard tag-to-tag comparison diff string
      "[#{new_version}]: #{base_url}/compare/v#{previous_version}...v#{new_version}"
    else
      # Initial release points directly to its own tag snapshot
      "[#{new_version}]: #{base_url}/releases/tag/v#{new_version}"
    end

    # Replace old unreleased line with the new lookahead and historical link stacked
    content.sub!(matched_regex, "#{new_unreleased_line}\n#{historical_comparison_line}")

    # Write back changes safely
    File.write(changelog_file, content)
    puts "✨✨✨ Success! ✨✨✨ CHANGELOG.md updated successfully."
    puts "   - Promoted Unreleased changes to [#{new_version}] - #{today}"
    if previous_version
      puts "   - Linked diff: v#{previous_version}...v#{new_version}"
    else
      puts "   - Linked initial static release tag: v#{new_version}"
    end
  end
  
end
