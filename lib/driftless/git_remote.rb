require 'digest'
require 'fileutils'
require 'open3'
require 'tmpdir'

module Driftless
  # Reads one file from a git remote at a ref without keeping a clone: a
  # depth-1 fetch into a scratch repository, then `cat-file`. A read at a
  # tag or commit may be cached under `cache_dir`; a branch is fetched every
  # time.
  class GitRemote
    class Error < StandardError; end

    # @return [String] `$XDG_CACHE_HOME/driftless/git-remote`, or its
    #   `~/.cache` equivalent
    def self.default_cache_dir
      File.join(ENV['XDG_CACHE_HOME'] || File.join(Dir.home, '.cache'), 'driftless', 'git-remote')
    end

    # @param url [String] anything `git fetch` accepts
    # @param cache_dir [String, nil] nil disables the cache
    def initialize(url, cache_dir: self.class.default_cache_dir)
      @url       = url
      @cache_dir = cache_dir
    end

    # @param ref [String] tag, branch, or sha
    # @param path [String] the file's path inside the repository
    # @param immutable [Boolean] whether ref names a fixed commit, so the
    #   read may be served from and saved to the cache
    # @return [String] the file's contents
    # @raise [Error] when git is absent, the fetch fails, or the file is not
    #   there at that ref
    def read_file(ref, path, immutable: false)
      cache = cache_path(ref, path) if immutable && @cache_dir
      return File.read(cache) if cache && File.file?(cache)

      contents = Dir.mktmpdir('driftless-git-remote') do |tmp|
        run(tmp, 'init', '-q')
        run(tmp, 'fetch', '-q', '--depth', '1', @url, ref)
        run(tmp, 'cat-file', '-p', "FETCH_HEAD:#{path}")
      end
      if cache
        FileUtils.mkdir_p(File.dirname(cache))
        File.write(cache, contents)
      end
      contents
    end

    private

    def cache_path(ref, path)
      File.join(@cache_dir, Digest::SHA256.hexdigest([@url, ref, path].join("\n"))[0, 32] + File.extname(path))
    end

    def run(dir, *args)
      out, err, status = Open3.capture3({ 'GIT_TERMINAL_PROMPT' => '0' }, 'git', '-C', dir, *args)
      return out if status.success?

      line = err.lines.find { |l| l.start_with?('fatal:') } || err.lines.last
      raise Error, "#{@url}: git #{args.first}: #{line.to_s.strip}"
    rescue Errno::ENOENT
      raise Error, 'git is not installed'
    end
  end
end
