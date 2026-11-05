variable(:tenant) { |node| node['site'] == 'example' ? 'blue' : nil }
mock(/\Ahostname/) { |node, _m| node['site'] == 'nowhere' ? "ruby.example.com\n" : nil }
