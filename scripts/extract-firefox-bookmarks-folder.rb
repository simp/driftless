#!/usr/bin/env ruby
# Extract a Firefox bookmark folder by name and write Netscape HTML for import.

require 'json'
require 'cgi'

TYPE_BOOKMARK = 1
TYPE_FOLDER   = 2

def find_folder(node, title)
  return node if node[:typeCode] == TYPE_FOLDER && node[:title] == title
  node[:children]&.each do |child|
    found = find_folder(child, title)
    return found if found
  end
  nil
end

def secs(usec) = usec.to_i / 1_000_000
def esc(value) = CGI.escapeHTML(value.to_s)

def render(node, depth = 1)
  pad = '    ' * depth

  case node[:typeCode]
  when TYPE_FOLDER
    children = node.fetch(:children, []).map { render(_1, depth + 1) }
    [
      %(#{pad}<DT><H3 ADD_DATE="#{secs(node[:dateAdded])}" LAST_MODIFIED="#{secs(node[:lastModified])}">#{esc(node[:title])}</H3>),
      "#{pad}<DL><p>",
      *children,
      "#{pad}</DL><p>",
    ].join("\n")
  when TYPE_BOOKMARK
    attrs = {
      HREF:        node[:uri],
      ADD_DATE:    secs(node[:dateAdded]),
      SHORTCUTURL: node[:keyword],
      TAGS:        node[:tags],
    }.compact.map { |k, v| %(#{k}="#{esc(v)}") }.join(' ')
    title = node[:title].to_s
    title = node[:uri].to_s if title.empty?
    %(#{pad}<DT><A #{attrs}>#{esc(title)}</A>)
  end
end

abort "Usage: #{$0} <bookmarks.json> <folder-title> [output.html]" if ARGV.size < 2

json_path, folder_title, out_path = ARGV
out_path ||= "#{folder_title}.html"

data   = JSON.parse(File.read(json_path), symbolize_names: true)
folder = find_folder(data, folder_title) or abort "Error: folder '#{folder_title}' not found."

File.write(out_path, <<~HTML)
  <!DOCTYPE NETSCAPE-Bookmark-file-1>
  <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
  <TITLE>Bookmarks</TITLE>
  <H1>Bookmarks</H1>

  <DL><p>
  #{render(folder)}
  </DL><p>
HTML

puts "Wrote #{out_path}"
