# latest_for_ruby.rb

Given a list of gem names, prints `gem 'name', 'version'` for the newest
release on a rubygems server whose `required_ruby_version` accepts a target
Ruby (default 2.7.8). The script uses only the Ruby standard library. It runs
on Ruby 2.7 and newer, and was tested on 2.7.8 (Bundler 2.1.4) and 3.2.11
(Bolt, Bundler 2.4.19).

## Usage

    export SSL_CERT_FILE=/path/to/internal-ca.pem   # or pass --ca-file
    ruby latest_for_ruby.rb -s https://gems.example.internal/ gems.txt > Gemfile.pins

`gems.txt` has one gem name per line. `#` comments and blank lines are
ignored, and lines already written as `gem 'name', ...` are accepted. Names
can also come from stdin. Progress goes to stderr and the `gem` lines go to
stdout. A gem that cannot be pinned is printed as a comment with the reason:

    # gem 'foo' - no release supports Ruby 2.7.8

The exit status is 0 when every gem was pinned (and `--check` passed), 1 when
not, 2 for usage errors, and 3 for server/TLS errors.

The source defaults to `$GEM_SOURCE`, then the first `gem sources` entry.
HTTP proxies are taken from `http_proxy`/`https_proxy` as usual for Net::HTTP.

Common options (`--help` lists all of them):

- `-r 2.7.2` targets a different Ruby version.
- `-p x86_64-linux` also considers that platform's builds (for example,
  nokogiri's native gems, which may have different Ruby requirements from the
  `ruby` platform build). Only `ruby` platform builds count by default.
- `--gemfile` prints a complete Gemfile, including the `source` line.
- `--check` reports whether the pins resolve together (see below).

## How it finds the Ruby requirement

`specs.4.8.gz` supplies the list of released versions (prereleases are
ignored). It has no Ruby requirements, so they come from one of:

1. The compact index, `/info/<name>`. This is one request per gem covering
   all its versions. The script probes it once, on the first gem, and uses it
   when the response looks like an info file (starts with `---`).
2. Otherwise the per-version gemspecs,
   `/quick/Marshal.4.8/<name>-<version>.gemspec.rz`, which `gem install` also
   uses. The script walks versions newest first and stops at the first match.
   A gem whose recent releases all need a newer Ruby costs one request per
   release skipped (rails and puppet took about 70 each on rubygems.org).

If you suspect that the server's compact index omits the `ruby:` field (a
missing field is read as "any Ruby"), compare a run with `--no-compact-index`.

## Slow servers

Responses are cached under `~/.cache/latest_for_ruby/<server>` (`--cache` to
change). Gemspecs are cached permanently. `specs.4.8.gz` and `/info/*` are
reused without a request for `--max-age` seconds (default one day), then
revalidated with a conditional GET when the server sent an ETag or
Last-Modified. `--refresh` revalidates immediately. Each of the `--jobs`
threads (default 4) keeps one connection open. Timeouts, connection resets,
429s, and 5xx responses are retried three times with backoff (2, 4, 8 s).
`--timeout` sets the read timeout (default 120 s).

## Depsolve check (`--check`)

Writes a Gemfile with the pins to a temp dir and runs `bundle lock` there, with
the same Ruby that runs the script. The resolver checks transitive
dependencies too. On failure, Bundler's explanation is printed to stderr.
`--check-verbose` also lists the transitive gems on success.

Bundler checks `required_ruby_version` against the Ruby it is running on
(`Gem.ruby_version`). It ignores a `ruby` line in the Gemfile for this. When
the running Ruby is not the target version, the script loads a small shim via
`RUBYOPT` that makes `Gem.ruby_version` return the target, and says so on
stderr. Your normal Bundler configuration (mirrors, `BUNDLE_SSL_CA_CERT`,
credentials) applies. `--ca-file` is passed on as `BUNDLE_SSL_CA_CERT` and
`SSL_CERT_FILE`.

This check fetches index data for every dependency, so on a slow server it
takes longer than the main run.

## Tests

    ruby test/latest_for_ruby_test.rb

The tests use in-memory fixtures and do not touch the network.
