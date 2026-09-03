require 'net/http'
require 'uri'
require 'json'
require 'optparse'
require 'cgi'

# CLI parsing
# --------------------------------------
options = {
  url: nil,
  token: nil,
  group_id: nil,
  image: nil,
  update_group: false,
  update_direct: false,
  update_recursive: false,
  filter: nil,  
}

opt_parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby gitlab_mass_icon_updater.rb [options]"
  opts.separator ""
  opts.separator "Required options:"

  opts.on("-u", "--url URL", "Your GitLab instance URL (e.g., https://example.com)") do |v|
    options[:url] = v
  end

  opts.on("-t", "--token TOKEN", "Your GitLab Personal Access Token (Requires API read/write scope)") do |v|
    options[:token] = v
  end

  opts.on("-g", "--group ID", "The path or numeric ID of the group") do |v|
    options[:group_id] = v
  end

  opts.on("-i", "--image PATH", "Path to the local icon image file (.png, .jpg, max 200KB)") do |v|
    options[:image] = v
  end

  opts.separator ""
  opts.separator "Action flags (Choose at least one):"

  opts.on("--group-icon", "Update the icon of the parent root group itself") do
    options[:update_group] = true
  end

  opts.on("--direct-projects", "Update icons for projects directly sitting under this group") do
    options[:update_direct] = true
  end

  opts.on("--recursive", "Recursively update icons for ALL projects inside any subgroups") do
    options[:update_recursive] = true
  end

""
  opts.separator "Optional filters:"

  opts.on("-f", "--filter REGEX", "Only update projects matching this Regex pattern (matches against path_with_namespace)") do |v|
    begin
      options[:filter] = Regexp.compile(v)
    rescue RegexpError => e
      puts "❌ Error: Invalid Regular Expression pattern '#{v}': #{e.message}"
      exit 1
    end
	end

  opts.separator ""
  opts.separator "Common options:"
  opts.on_tail("-h", "--help", "Show this help message and exit") do
    puts opts
    exit
  end
end

begin
  opt_parser.parse!(ARGV)
rescue OptionParser::ParseError => e
  puts "❌ Error: #{e.message}"
  puts opt_parser
  exit 1
end

# --- Validation Checks ---
missing = []
missing << "--url (-u)" if options[:url].nil?
missing << "--token (-t)" if options[:token].nil?
missing << "--group (-g)" if options[:group_id].nil?
missing << "--image (-i)" if options[:image].nil?

unless missing.empty?
  puts "❌ Error: Missing required arguments: #{missing.join(', ')}"
  puts opt_parser
  exit 1
end

unless File.exist?(options[:image])
  puts "❌ Error: The image file at '#{options[:image]}' does not exist."
  exit 1
end

unless options[:update_group] || options[:update_direct] || options[:update_recursive]
  puts "❌ Error: You must select at least one action flag (--group-icon, --direct-projects, or --recursive)."
  puts opt_parser
  exit 1
end

# Map back to variables for internal script logic
GITLAB_URL         = options[:url].chomp('/')
PRIVATE_TOKEN      = options[:token]
ROOT_GROUP_ID      = ((options[:group_id] =~ /\A\d+\z/) ? options[:group_id].to_i : CGI.escape(options[:group_id]))
IMAGE_PATH         = options[:image]
UPDATE_GROUP_ICON  = options[:update_group]
UPDATE_DIRECT      = options[:update_direct]
UPDATE_RECURSIVELY = options[:update_recursive]
REGEX_FILTER       = options[:filter]

# Functions
# --------------------------------------

# Simple helper to handle API requests and pagination
def gitlab_api_request(url_string, method: :get, form_data: nil)
  uri = URI.parse(url_string)
  http = Net::HTTP.new(uri.hostname, uri.port)
  http.use_ssl = (uri.scheme == 'https')

  request = case method
            when :get  then Net::HTTP::Get.new(uri)
            when :put  then Net::HTTP::Put.new(uri)
            end

  request['PRIVATE-TOKEN'] = PRIVATE_TOKEN
  request.set_form(form_data, 'multipart/form-data') if form_data

  response = http.request(request)
  
  if response.code.start_with?('2')
    return response
  else
    puts "⚠️ API Error [#{response.code}]: #{response.body}"
    return nil
  end
end

# Extract the 'next' page URL from GitLab's pagination Link headers
def get_next_page_url(response)
  return nil unless response && response['link']
  links = response['link'].split(',')
  next_link = links.find { |link| link.include?('rel="next"') }
  return nil unless next_link
  next_link.match(/<([^>]+)>/)&.captures&.first
end

# Multi-page fetching loop
def fetch_all_pages(initial_url)
  results = []
  current_url = initial_url

  while current_url
    response = gitlab_api_request(current_url, method: :get)
    break unless response
    
    results.concat(JSON.parse(response.body))
    current_url = get_next_page_url(response)
  end
  results
end

# Updates the icon for a specific project or group endpoint
def upload_avatar(endpoint_url, label)
  file_name = File.basename(IMAGE_PATH)
  content_type = file_name.downcase.end_with?('.png') ? 'image/png' : 'image/jpeg'
  
  form_data = [
    ['avatar', File.open(IMAGE_PATH), { filename: file_name, content_type: content_type }]
  ]

  puts "🚀 Updating icon for #{label}..."
  response = gitlab_api_request(endpoint_url, method: :put, form_data: form_data)
  if response
    puts "✅ Successfully updated #{label}"
  end
end

# Helper to filter project lists by regex if defined
def filter_projects(project_list)
  return project_list unless REGEX_FILTER

  project_list.select do |project|
    path = project['path_with_namespace']
    matches = REGEX_FILTER.match?(path)
    puts "⏭️ Skipping project (Regex Mismatch): #{path}" unless matches
    matches
  end
end


# Main program
# --------------------------------------

# 1. Update the Main Group Icon
if UPDATE_GROUP_ICON
  group_url = "#{GITLAB_URL}/api/v4/groups/#{ROOT_GROUP_ID}"
  upload_avatar(group_url, "Group (ID: #{ROOT_GROUP_ID})")
end

# 2. Update Direct Projects
if UPDATE_DIRECT
  puts "\n🔍 Fetching projects directly under group #{ROOT_GROUP_ID}..."
  projects_url = "#{GITLAB_URL}/api/v4/groups/#{ROOT_GROUP_ID}/projects?include_subgroups=false&per_page=50"
  projects = fetch_all_pages(projects_url)
  
  filtered_direct = filter_projects(projects)

  filtered_direct.each do |project|
    project_url = "#{GITLAB_URL}/api/v4/projects/#{project['id']}"
    upload_avatar(project_url, "Project: #{project['path_with_namespace']}")
  end
end

# 3. Update Recursively via Subgroups
if UPDATE_RECURSIVELY
  puts "\n🔍 Fetching all projects recursively within subgroups..."
  all_projects_url = "#{GITLAB_URL}/api/v4/groups/#{ROOT_GROUP_ID}/projects?include_subgroups=true&per_page=50"
  all_projects = fetch_all_pages(all_projects_url)

  # Filter out projects we already updated if step 2 was active
  projects_to_update = if UPDATE_DIRECT
    all_projects.reject { |p| p['namespace']['id'].to_s == ROOT_GROUP_ID.to_s }
  else
    all_projects
  end

  filtered_recursive = filter_projects(projects_to_update)

  if filtered_recursive.empty?
    puts "No matching subgroup projects found to update."
  else
    filtered_recursive.each do |project|
      project_url = "#{GITLAB_URL}/api/v4/projects/#{project['id']}"
      upload_avatar(project_url, "Subgroup Project: #{project['path_with_namespace']}")
    end
  end
end

puts "\n✨ Script execution finished!"
