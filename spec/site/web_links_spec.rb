require 'spec_helper'

require 'driftless/site/web_links'

RSpec.describe Driftless::Site::WebLinks do
  def template(remote:, ref: 'main', ref_type: 'branch', sha: 'f' * 40, config: nil)
    described_class.template(remote: remote, ref: ref, ref_type: ref_type, sha: sha, config: config)
  end

  describe '.parse_remote' do
    it 'reads scp-like, ssh, and https remotes to host and project' do
      expect(described_class.parse_remote('git@github.com:org/repo.git')).to eq(host: 'github.com', project: 'org/repo')
      expect(described_class.parse_remote('ssh://git@git.example.com:2222/group/sub/proj.git'))
        .to eq(host: 'git.example.com', project: 'group/sub/proj')
      expect(described_class.parse_remote('https://user@git.example.com/group/proj/'))
        .to eq(host: 'git.example.com', project: 'group/proj')
    end

    it 'gives nil for a local path or nothing' do
      expect(described_class.parse_remote('/srv/git/repo.git')).to be_nil
      expect(described_class.parse_remote('../repo')).to be_nil
      expect(described_class.parse_remote(nil)).to be_nil
      expect(described_class.parse_remote('')).to be_nil
    end
  end

  describe '.template' do
    it 'uses the gitlab layout when nothing says otherwise' do
      expect(template(remote: 'git@git.example.com:group/proj.git'))
        .to eq('https://git.example.com/group/proj/-/blob/main/{path}#L{line}')
    end

    it 'knows github.com and codeberg.org by host' do
      expect(template(remote: 'git@github.com:org/repo.git', ref: 'v1', ref_type: 'tag'))
        .to eq('https://github.com/org/repo/blob/v1/{path}#L{line}')
      expect(template(remote: 'https://codeberg.org/org/repo.git', ref: 'v1', ref_type: 'tag'))
        .to eq('https://codeberg.org/org/repo/src/tag/v1/{path}#L{line}')
    end

    it 'links at the sha as a commit when no ref is declared' do
      expect(template(remote: 'https://codeberg.org/org/repo.git', ref: nil, ref_type: nil, sha: 'abc'))
        .to eq('https://codeberg.org/org/repo/src/commit/abc/{path}#L{line}')
      expect(template(remote: 'https://codeberg.org/org/repo.git', ref: nil, ref_type: nil, sha: nil)).to be_nil
    end

    it 'takes the first matching remotes entry, then default, from config' do
      config = {
        'default' => 'github',
        'remotes' => {
          '/gitea\.example\.com/' => { 'layout' => 'forgejo', 'base_url' => 'https://gitea.example.com/git/' },
          'example\.com'          => 'gitlab',
        },
      }
      expect(template(remote: 'git@gitea.example.com:org/repo.git', config: config))
        .to eq('https://gitea.example.com/git/org/repo/src/branch/main/{path}#L{line}')
      expect(template(remote: 'git@git.example.com:org/repo.git', config: config))
        .to eq('https://git.example.com/org/repo/-/blob/main/{path}#L{line}')
      expect(template(remote: 'git@other.org:org/repo.git', config: config))
        .to eq('https://other.org/org/repo/blob/main/{path}#L{line}')
    end

    it 'renders a custom template in place of a layout' do
      config = { 'default' => { 'template' => '{base}/browse/{project}?at={ref}&file={path}&line={line}' } }
      expect(template(remote: 'git@h:p/r.git', config: config))
        .to eq('https://h/browse/p/r?at=main&file={path}&line={line}')
    end

    it 'raises on an unknown layout name' do
      expect { template(remote: 'git@h:p/r.git', config: { 'default' => 'bitbucket' }) }
        .to raise_error(described_class::Error, /unknown layout "bitbucket"/)
    end

    it 'gives nil for a remote that is not a host URL' do
      expect(template(remote: '/srv/git/repo.git')).to be_nil
      expect(template(remote: nil)).to be_nil
    end
  end
end
