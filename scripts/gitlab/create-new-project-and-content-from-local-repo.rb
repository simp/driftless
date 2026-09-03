require 'uri'
require 'net/http'
require 'json'
require 'cgi'
require 'open3' # Standard library to safely run system commands

# Ensure correct command-line arguments are provided
if ARGV.length < 1
  puts "Usage: ruby create_and_push_repo.rb <repo-name> <local-repo-path> <group-path> [visibility]"
  puts "Example: ruby create_and_push_repo.rb my-app ./local-project my-org/engineering public"
  exit 1
end

	# Helper method to make authenticated GET requests
	def gitlab_get(url_string, token)
		uri = URI(url_string)
		http = Net::HTTP.new(uri.host, uri.port)
		http.use_ssl = (uri.scheme == 'https')
		
		request = Net::HTTP::Get.new(uri.request_uri, { 'PRIVATE-TOKEN' => token })
		http.request(request)
	end

	# Helper to run local terminal commands inside a directory
	def run_command(cmd, dir)
		stdout, stderr, status = Open3.capture3(cmd, chdir: dir)
		unless status.success?
			puts "❌ Local command failed: #{cmd}"
			puts "Error output:\n#{stderr}"
			exit 1
		end
		stdout
	end

# Configuration from CLI and Environment
#repo_name       = ARGV[0]
VISIBILITY      = 'private'
GITLAB_TOKEN    = ENV['GITLAB_CI_SIMP_MIRROR_TOKEN'] || ENV['GITLAB_TOKEN'] || 'YOUR_PERSONAL_ACCESS_TOKEN'
GITLAB_HOST     = ENV['GITLAB_HOST'] || 'https://gitlab.example.com'
	group_path      = 'puppet-testing/simp'
	# --- STEP 2: Look up the Namespace ID ---
	encoded_path = CGI.escape(group_path)
	group_url = "#{GITLAB_HOST}/api/v4/groups/#{encoded_path}"

	puts "🔍 Looking up group: '#{group_path}'..."
	group_response = gitlab_get(group_url, GITLAB_TOKEN)

	unless group_response.is_a?(Net::HTTPSuccess)
		puts "❌ Error finding group: #{group_response.code} #{group_response.message}"
		exit 1
	end

	group_data = JSON.parse(group_response.body)
	namespace_id = group_data['id']
	puts "✅ Found! Group ID is #{namespace_id}."

ARGV.each do |arg|

	local_repo_path = File.expand_path(arg) # Resolves relative paths like './'
	url = `git -C #{local_repo_path} remote get-url origin`.chomp.sub(/\.git\z/, '')
	repo_name = url.sub(%r{\A.*/},'')

	puts "url: #{url}, repo_name: #{repo_name}"

	# --- STEP 1: Validate Local Repository Path ---
	unless Dir.exist?(local_repo_path) && Dir.exist?(File.join(local_repo_path, '.git'))
		puts "❌ Error: The directory '#{local_repo_path}' is not a valid git repository."
		exit 1
	end


	# --- STEP 3: Check if a repository already exists in this group ---
	check_url = "#{GITLAB_HOST}/api/v4/groups/#{namespace_id}/projects?search=#{CGI.escape(repo_name)}"
	puts "🔍 Checking if repository '#{repo_name}' already exists in this group..."
	check_response = gitlab_get(check_url, GITLAB_TOKEN)

	if check_response.is_a?(Net::HTTPSuccess)
		existing_projects = JSON.parse(check_response.body)
		conflict = existing_projects.any? { |p| p['path'].downcase == repo_name.downcase }
		
		if conflict
			puts "❌ Aborting: A repository named '#{repo_name}' already exists in this group!"
			next
		end
		puts "✅ Name is available."
	else
		puts "⚠️ Warning: Could not verify repository existence. Proceeding anyway..."
	end

	# --- STEP 4: Create the GitLab repository ---
	projects_uri = URI("#{GITLAB_HOST}/api/v4/projects")
	http = Net::HTTP.new(projects_uri.host, projects_uri.port)
	http.use_ssl = (projects_uri.scheme == 'https')

	create_request = Net::HTTP::Post.new(projects_uri.path, {
		'Content-Type' => 'application/json',
		'PRIVATE-TOKEN' => GITLAB_TOKEN
	})

	create_request.body = {
		name: repo_name,
		visibility: VISIBILITY,
		namespace_id: namespace_id
	}.to_json

	puts "🚀 Creating GitLab repository '#{repo_name}'..."
	create_response = http.request(create_request)

	unless create_response.is_a?(Net::HTTPSuccess)
		puts "\n❌ Failed to create repository: #{create_response.code} #{create_response.message}"
		puts create_response.body
		exit 1
	end

	json_response = JSON.parse(create_response.body)
	ssh_url = json_response['ssh_url_to_repo']
	web_url = json_response['web_url']
	puts "🎉 Success! GitLab repository provisioned."
	puts "🌐 Web URL: #{web_url}"

	# --- STEP 5: Push Local Git Repo to GitLab ---
	puts "\n📦 Setting up local Git tracking..."

	# Check if a remote named 'gitlab' already exists, and clean it up if it does
	existing_remotes = run_command("git remote", local_repo_path).split("\n")
	if existing_remotes.include?('gitlab')
		puts "⚠️ Existing 'gitlab' remote detected. Updating its URL..."
		run_command("git remote set-url gitlab #{ssh_url}", local_repo_path)
	else
		run_command("git remote add gitlab #{ssh_url}", local_repo_path)
	end

	# Push all local branches, references, and tags seamlessly
	puts "⬆️  Pushing all branches to GitLab..."
	run_command("git push gitlab --all", local_repo_path)

	puts "🏷️  Pushing all tags to GitLab..."
	run_command("git push gitlab --tags", local_repo_path)

	puts "\n✨ Complete automation finished successfully!"

end
