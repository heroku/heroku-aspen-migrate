require 'yaml'
require 'fileutils'

class GemManifest
  class InvalidManifest < StandardError; end

  attr_reader :data, :gems, :extra_gems

  def initialize(data, extra_gems=[])
    raise InvalidManifest, "empty .gems file; 'git rm .gems' if no gems are required" if data.nil?

    @data = data
    @gems = []
    @extra_gems = extra_gems

    parse_gems

    raise InvalidManifest, "empty .gems file; 'git rm .gems' if no gems are required" if @gems.empty?
  end

  def parse_gems
    @gems.clear
    @data.each_line do |line|
      line.strip!
      next if line.empty?

      gem_name, args = line.split(/\s+/, 2)

      gem = {
        'name'    => gem_name,
        'version' => nil,
        'source'  => []
      }

      argv = args.to_s.
        gsub(/["']/, '').                           # remove all quotes
        split(/(?:^|\s)-/).                         # split at opt boundaries
        map { |arg| "-#{arg}".split(/[\s=]+/, 2) }  # split each opt on [= ]

      argv.shift

      nilval_opts = ['--ignore-dependencies']
      argv.each do |opt, val|
        case opt
        when '-v', '--version' ; gem['version'] = val
        when '-s', '--source'  ; gem['source'] << val
        when '--ignore-dependencies' ; gem['ignore-dependencies'] = true
        else
          raise InvalidManifest, "unknown argument: #{opt} for #{gem_name}"
        end
        raise InvalidManifest, "invalid #{opt} for #{gem_name}" if val.nil? && !nilval_opts.include?(opt)
      end

      # add http:// to sources that specify a host only
      gem['source'].map! do |source|
        source = source.strip.sub(/\/+$/, '')
        if source !~ /^https?:\/\//
          "http://#{source}"
        else
          source
        end
      end

      @gems << gem
    end

    @gems += extra_gems
  end

  class Runner
    def initialize(slug)
      @slug = slug
      @source_index = Gem.source_index
    end

    def escape(argument)
      "'%s'" % argument.gsub(/'/, "")
    end

    def run(opts={})
      force = !!opts[:force]

      if !@slug.dot_gems_exists?
        # no .gems file present. remove any gems dir.
        if opts[:force_gems] && opts[:force_gems].size > 0 # we need to install some gems manually
          install_gems('', opts[:force_gems])
        else
          FileUtils.rm_rf("#{@slug.repo_dir.full_path}gems")
        end
      elsif @slug.prev !~ /0{40}/ && `git --git-dir #{@slug.repo_dir.full_path} diff #{@slug.prev} #{@slug.head} -- .gems`.empty? and !force
        # .gems file present but no changes were made.
        # do nothing
      else
        # .gems file present with changes
        data = `git --git-dir #{@slug.repo_dir.full_path} show #{@slug.head}:.gems 2> /dev/null`
        install_gems(data)
      end
      nil
    end

    def install_gems(data, extra_gems = [])
      prepare_build_dir
      begin
        ::RubyBamboo::GemManifest.new(data, extra_gems).gems.each { |gem| install(gem) }
        Utils.message "\n"
      rescue ::RubyBamboo::GemManifest::InvalidManifest => boom
        raise Slug::CompileError, "invalid .gems file: #{boom.message}.\n !     Please see http://devcenter.heroku.com/articles/gems#gem_manifest"
      end
    end

    def prepare_build_dir
      FileUtils.rm_rf(@slug.gems_build_dir.full_path)
      FileUtils.mkdir(@slug.gems_build_dir.full_path)
    end

    def preinstalled?(gem)
      return false unless @slug.is_stack?("aspen")
      return false unless (gem['source'].include?('http://rubygems.org') ||
                           gem['source'].include?('http://gems.rubyforge.org'))

      dep = Gem::Dependency.new(gem['name'], Gem::Requirement.new([gem['version']]))
      !@source_index.search(dep).empty?
    end

    # Install the gem; return true if successful, false otherwise.
    def install(gem)
      version = gem['version'] == '> 0' ? '' : "#{gem['version']} "
      Utils.message "\n"
      if preinstalled?(gem)
        Utils.message "-----> Skipping #{gem['name']} #{version} - this gem is installed by default on Heroku\n"
      else
        proxy =  Utils.slot =~ /codex/ ? "--http-proxy http://localhost:3128" : ""
        command = [
          "export PATH=#{@slug.ruby_path};",
          "export GEM_HOME=#{@slug.gems_build_dir};",
          "gem install",
          escape(gem['name']),
          proxy,
          "--no-ri",
          "--no-rdoc",
          "--bindir=#{@slug.repo_dir.full_path}bin",
          "--version=#{escape(gem['version'])}",
          gem['source'].map {|s| "-s #{escape(s)}"}.join(" "),
          ("--ignore-dependencies" if gem["ignore-dependencies"])
        ].compact.join(" ")
        Utils.message "-----> Installing gem #{gem['name']} #{version}from #{gem['source'].join(", ")}#{" and ignoring dependencies" if gem['ignore-dependencies']}\n"
        exec_gem_install_command(command)
      end
    end

    def exec_gem_install_command(command)
      retval = Utils.spawn_nobuffer(command)
      if retval != 0
        raise Slug::CompileError, "failed to install gem"
      end
    end
  end
end
