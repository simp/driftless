# frozen_string_literal: true

require 'minitest/autorun'
require 'stringio'
require_relative '../latest_for_ruby'

class LatestForRubyTest < Minitest::Test
  L = LatestForRuby
  TARGET = Gem::Version.new('2.7.8')

  # Serves fixtures by path, counting requests.
  class StubFetcher
    attr_reader :paths

    def initialize(files)
      @files = files
      @paths = []
    end

    def get(path, _policy)
      @paths << path
      @files[path]
    end
  end

  def specs_gz(entries)
    io = StringIO.new
    gz = Zlib::GzipWriter.new(io)
    gz.write(Marshal.dump(entries.map { |n, v, p| [n, Gem::Version.new(v), p || 'ruby'] }))
    gz.close
    io.string
  end

  def gemspec_rz(name, version, ruby_req, platform = 'ruby')
    spec = Gem::Specification.new do |s|
      s.name = name
      s.version = version
      s.platform = platform
      s.summary = 'x'
      s.authors = ['x']
      s.files = []
      s.required_ruby_version = ruby_req
    end
    Zlib::Deflate.deflate(Marshal.dump(spec))
  end

  def log
    @log ||= []
    ->(m) { @log << m }
  end

  def index(entries, names)
    L::SpecsIndex.load(specs_gz(entries), names.to_set)
  end

  def no_platforms
    L::PlatformFilter.new([])
  end

  def test_parse_names
    text = "# list\nfoo\n  bar  # comment\n\ngem 'baz', '~> 1'\ngem(\"qux\")\nfoo\n"
    assert_equal %w[foo bar baz qux], L.parse_names(text)
  end

  def test_specs_index_skips_prereleases_and_unwanted
    idx = index([['a', '1.0'], ['a', '2.0.pre'], ['b', '1.0'], ['a', '1.1', 'x86_64-linux']], %w[a])
    assert_equal %w[a], idx.keys
    assert_equal({ Gem::Version.new('1.0') => ['ruby'], Gem::Version.new('1.1') => ['x86_64-linux'] }, idx['a'])
  end

  def test_specs_index_accepts_already_decompressed_data
    raw = Marshal.dump([['a', Gem::Version.new('1.0'), 'ruby']])
    assert_equal [Gem::Version.new('1.0')], L::SpecsIndex.load(raw, Set['a'])['a'].keys
  end

  def test_compact_index_requirement_parsing
    body = "---\n" \
           "1.0 |checksum:aa\n" \
           "2.0 dep:>= 1&< 2,other:> 0|checksum:bb,ruby:>= 2.5&< 3.0,rubygems:>= 2\n" \
           "3.0 |checksum:cc,ruby:>= 3.0\n" \
           "3.0-x86_64-linux |checksum:dd,ruby:>= 2.7, < 3.3.dev\n"
    info = L::CompactIndexSource.parse(body)
    assert_equal Gem::Requirement.default, info[[Gem::Version.new('1.0'), 'ruby']]
    assert_equal Gem::Requirement.new('>= 2.5', '< 3.0'), info[[Gem::Version.new('2.0'), 'ruby']]
    assert_equal Gem::Requirement.new('>= 3.0'), info[[Gem::Version.new('3.0'), 'ruby']]
    assert_equal Gem::Requirement.new('>= 2.7', '< 3.3.dev'), info[[Gem::Version.new('3.0'), 'x86_64-linux']]
  end

  def test_compact_index_picks_newest_compatible
    idx = index([%w[a 1.0], %w[a 2.0], %w[a 3.0]], %w[a])
    f = StubFetcher.new('info/a' => "---\n1.0 |ruby:>= 2.0\n2.0 |ruby:>= 2.5\n3.0 |ruby:>= 3.0\n")
    src = L::CompactIndexSource.new(L::QuickMarshalSource.new)
    assert_equal Gem::Version.new('2.0'), src.pick(f, 'a', idx['a'], no_platforms, TARGET, log)
    assert_equal ['info/a'], f.paths
  end

  def test_compact_index_platform_variant
    idx = index([%w[n 3.0], ['n', '3.0', 'x86_64-linux'], %w[n 2.0]], %w[n])
    body = "---\n2.0 |ruby:>= 2.5\n3.0 |ruby:>= 3.0\n3.0-x86_64-linux |ruby:>= 2.7&< 3.3.dev\n"
    src = L::CompactIndexSource.new(L::QuickMarshalSource.new)
    assert_equal Gem::Version.new('2.0'), src.pick(StubFetcher.new('info/n' => body), 'n', idx['n'], no_platforms, TARGET, log)
    linux = L::PlatformFilter.new(['x86_64-linux'])
    assert_equal Gem::Version.new('3.0'), src.pick(StubFetcher.new('info/n' => body), 'n', idx['n'], linux, TARGET, log)
  end

  def test_compact_index_version_missing_from_info_asks_gemspec
    idx = index([%w[a 1.0], %w[a 2.0]], %w[a])
    f = StubFetcher.new('info/a' => "---\n1.0 |\n",
                        'quick/Marshal.4.8/a-2.0.gemspec.rz' => gemspec_rz('a', '2.0', '>= 2.3'))
    src = L::CompactIndexSource.new(L::QuickMarshalSource.new)
    assert_equal Gem::Version.new('2.0'), src.pick(f, 'a', idx['a'], no_platforms, TARGET, log)
  end

  def test_falls_back_to_quick_when_info_missing
    idx = index([%w[a 1.0], %w[a 2.0]], %w[a])
    f = StubFetcher.new('quick/Marshal.4.8/a-2.0.gemspec.rz' => gemspec_rz('a', '2.0', '>= 3.1'),
                        'quick/Marshal.4.8/a-1.0.gemspec.rz' => gemspec_rz('a', '1.0', '>= 2.4'))
    src = L::CompactIndexSource.new(L::QuickMarshalSource.new)
    assert_equal Gem::Version.new('1.0'), src.pick(f, 'a', idx['a'], no_platforms, TARGET, log)
  end

  def test_quick_walks_newest_first_and_stops
    idx = index([%w[a 1.0], %w[a 2.0], %w[a 3.0]], %w[a])
    f = StubFetcher.new('quick/Marshal.4.8/a-3.0.gemspec.rz' => gemspec_rz('a', '3.0', '>= 3.0'),
                        'quick/Marshal.4.8/a-2.0.gemspec.rz' => gemspec_rz('a', '2.0', '>= 2.7'),
                        'quick/Marshal.4.8/a-1.0.gemspec.rz' => gemspec_rz('a', '1.0', '>= 2.0'))
    assert_equal Gem::Version.new('2.0'), L::QuickMarshalSource.new.pick(f, 'a', idx['a'], no_platforms, TARGET, log)
    assert_equal %w[quick/Marshal.4.8/a-3.0.gemspec.rz quick/Marshal.4.8/a-2.0.gemspec.rz], f.paths
  end

  def test_quick_platform_file_name
    idx = index([['n', '1.0', 'x86_64-linux']], %w[n])
    f = StubFetcher.new('quick/Marshal.4.8/n-1.0-x86_64-linux.gemspec.rz' => gemspec_rz('n', '1.0', '>= 2.6', 'x86_64-linux'))
    assert_nil L::QuickMarshalSource.new.pick(f, 'n', idx['n'], no_platforms, TARGET, log)
    assert_equal Gem::Version.new('1.0'),
                 L::QuickMarshalSource.new.pick(f, 'n', idx['n'], L::PlatformFilter.new(['x86_64-linux']), TARGET, log)
  end

  def test_no_compatible_version
    idx = index([%w[a 1.0]], %w[a])
    f = StubFetcher.new('info/a' => "---\n1.0 |ruby:>= 3.0\n")
    assert_nil L::CompactIndexSource.new(L::QuickMarshalSource.new).pick(f, 'a', idx['a'], no_platforms, TARGET, log)
  end

  def test_gemfile_text
    assert_equal "source 'https://x/'\n\ngem 'a', '1.0'\n",
                 L.gemfile_text('https://x/', [['a', Gem::Version.new('1.0')]])
  end
end
