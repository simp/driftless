  def parse_puppetfile(puppetfile, default_moduledir)
    pdsl = PuppetfileDSLReader.new(puppetfile, default_moduledir)
    pdsl.to_puppetfile
  end

  class PuppetfileDSL
    # A barebones implementation of the Puppetfile DSL
    @lines = []
    def initialize(librarian)
      @librarian = librarian
    end

    def mod(name, args = nil)
      warn("== Puppetfile:  #{__method__.to_s} : name='#{name}'" ) if @verbose
      @librarian.add_module(name, args)
    end

    def forge(location)
      warn("== Puppetfile:  #{__method__.to_s} : location='#{location}'" ) if @verbose
      @librarian.set_forge(location)
    end

    def moduledir(location)
      warn("== Puppetfile:  #{__method__.to_s} : location='#{location}'" ) if @verbose
      @librarian.set_moduledir(location)
    end

    def method_missing(method, *args)
      raise NoMethodError, _("unrecognized declaration '%{method}'") % {method: method}
    end
  end


  class PuppetfileDSLReader

    attr_reader :modules
    attr_reader :module_dirs

    def initialize(puppetfile, default_moduledir = nil)
      @module_dir = nil
      @module_dirs = []
      @modules = {}

      puppetfile_data = File.read(puppetfile)
      dsl = PuppetfileDSL.new(self)

      if default_moduledir
        puppetfile_data = "moduledir '#{default_moduledir}'  # <-- default_moduledir, added by PuppetfileDSLReader\n\n#{puppetfile_data}"
      end
      dsl.instance_eval(puppetfile_data, File.expand_path(puppetfile) )
    end

    def self.from_puppetfile(path)
      self.new(File.read(path))
    end

    def add_module(name, args)
      rel_path = File.join(@module_dir,name)
      #warn( "  -- PuppetfileDSLReader.add_module(name: '#{name}', args: #{args.inspect})")

      if args.is_a?(Hash) && install_path = args.fetch(:install_path,false)
        install_path = install_path
      else
        install_path = @module_dir
      end

      mod_type = nil
      opts = {}
      if args.is_a?(Hash)
        opts = args.dup
      elsif args.to_s.empty? || args.to_s =~ /\A(\d+\.\d\+\.\d\+|latest)\z/
        if args.to_s =~ /\A\d+\.\d+\.\d+\z/ ||  args.to_s.to_sym == :latest
          opts[:version] = args
        end
      end

      # emulate r10k's namespace-chopping tendencies
      mod_rel_path = File.join(File.dirname(rel_path),  rel_path.split(%r{[-/]}).last)

      info = {
        :name         => name,
        :rel_path     => rel_path,
        :mod_rel_path => mod_rel_path,
        # repos basename, also the second half of the `org-mod_name` convention
        :mod_name     => File.basename(mod_rel_path),
        :install_path => install_path,
        :opts => opts,
      }

      if info.key? :git
        info[:repo_name] = File.basename(args[:git], '.git')
      end
      @modules[rel_path]=info
    end

    def set_forge(location)
    end

    def set_moduledir(location)
      @module_dirs << location
      @module_dir = location
    end

    def each
      @modules.each
    end
    
    def to_puppetfile_v(v)
      return(v) if v.is_a?(Symbol)
      return("'#{v}'") if v.is_a?(String)
      v
    end

    def to_puppetfile_mod(mod_name, opts)
      (
        ["mod '#{mod_name}'" ] + 
        opts.map{ |k,v| "  :#{k} => #{to_puppetfile_v(v)}" }
      ).join(",\n")+"\n"
    end

    def to_puppetfile
      m = @modules.group_by { |k,v| v[:install_path] }
      m.map do |moduledir,modules|
        pf_mods = modules.to_h.map { |mod_name,v|
          to_puppetfile_mod(v[:name],v[:opts])
        }.join("\n")+"\n"

        unless modules.to_h.all? {|k,v| v[:opts][:install_path] }
          pf_mods = "moduledir #{to_puppetfile_v moduledir}\n\n" + pf_mods
        end
        pf_mods
      end
    end
  end

puppetfile =   ARGV.first || 'Puppetfile'
default_moduledir = File.join(Dir.pwd, 'modules')
puts parse_puppetfile(puppetfile, default_moduledir)
