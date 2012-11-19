require "aspen/gem_manifest"
require "heroku/client/pgbackups"
require "heroku/command/base"
require "tmpdir"

# aspen migration
#
class Heroku::Command::Aspen < Heroku::Command::Base

  # aspen:migrate
  #
  # migrate an aspen app
  #
  def migrate
    error "Run this migration from Ruby 1.8.7" unless %x{bundle exec ruby -v} =~ /1.8.7/

    original_app = app

    new_app = "#{original_app}-cedar"
    new_config = cedar_config(original_app)

    needs_db_migration = false

    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        action("Creating Cedar app #{new_app}") do
          api.post_app(:name => new_app, :stack => "cedar")
        end
        action("Discovering database addon") do
          cfg = api.get_config_vars(original_app).body
          att_name = cfg.keys.detect do |key|
            next(false) if key == "DATABASE_URL"
            next(false) if key == "SHARED_DATABASE_URL"
            cfg[key] == cfg["DATABASE_URL"]
          end.to_s.gsub(/_URL$/, "")
          if att_name != ""
            error "Unable to determine which database is in use" unless att_name =~ /^HEROKU_POSTGRESQL/
            addon = api.get_addons(original_app).body.detect { |addon| addon["attachment_name"] == att_name }
            new_db = api.post_addon(new_app, addon["name"]).body["message"].match(/Attached as (.*)\n/)[1]
            status addon["name"]
            needs_db_migration = att_name
            api.put_config_vars new_app, "DATABASE_URL" => api.get_config_vars(new_app).body[new_db]
          else
            status "No database detected"
          end
        end
        action("Verifying pgbackups installation") do
          pgb = api.get_addons(original_app).body.detect { |addon| addon["name"] =~ /^pgbackups:/ }
          api.post_addon original_app, "pgbackups:plus" unless pgb
        end
        action("Adding addons to Cedar app") do
          api.get_addons(original_app).body.each do |addon|
            next if addon["name"] =~ /^heroku-postgresql:/
            next if addon["name"] =~ /^shared-database:/
            api.post_addon new_app, addon["name"]
          end
        end
        if needs_db_migration
          transfer = nil
          action("Creating database backup from #{original_app}") do
            pgb = Heroku::Client::Pgbackups.new(api.get_config_vars(original_app).body["PGBACKUPS_URL"])
            transfer = pgb.create_transfer(api.get_config_vars(original_app).body["#{needs_db_migration}_URL"], needs_db_migration, nil, "BACKUP", :expire => "true")
            error transfer["errors"].values.flatten.join("\n") if transfer["errors"]
            loop do
              transfer = pgb.get_transfer(transfer["id"])
              error transfer["errors"].values.flatten.join("\n") if transfer["errors"]
              break if transfer["finished_at"]
              sleep 1
              print "."
            end
            print " "
          end
          action("Restoring database backup to #{new_app}") do
            pgb = Heroku::Client::Pgbackups.new(api.get_config_vars(new_app).body["PGBACKUPS_URL"])
            transfer = pgb.create_transfer(transfer["public_url"], "EXTERNAL_BACKUP", api.get_config_vars(new_app).body["DATABASE_URL"], "DATABASE_URL")
            error transfer["errors"].values.flatten.join("\n") if transfer["errors"]
            loop do
              transfer = pgb.get_transfer(transfer["id"])
              error transfer["errors"].values.flatten.join("\n") if transfer["errors"]
              break if transfer["finished_at"]
              sleep 1
              print "."
            end
            print " "
          end
        end
        action("Copying config") do
          new_config = {}
          api.get_config_vars(original_app).body.each do |key, val|
            next if aspen_config_vars.include?(key)
            next if key =~ /^HEROKU_POSTGRESQL_/
            next if key == "DATABASE_URL"
            new_config[key] = val
          end
          api.put_config_vars new_app, new_config
        end
        action("Cloning original app into temp dir") do
          %x{ git clone git@heroku.com:#{original_app}.git . 2>&1 }
        end
        gemfile = File.read("#{File.dirname(__FILE__)}/data/Gemfile.aspen")
        gems = []
        if File.exists?(".gems")
          action("Converting .gems manifest") do
            gems = GemManifest.new(File.read(".gems")).parse_gems.map do |gem|
              gemfile.gsub! /^gem "#{gem["name"]}".*$\n/, ""
              line = "gem \"#{gem["name"]}\""
              line += ", \"#{gem["version"]}\"" if gem["version"]
              line
            end
          end
        end
        action("Converting gems to bundler") do
          puts
          File.open("Gemfile", "w") do |file|
            gemfile.gsub!("%%RUBY%%", RUBY_VERSION)
            gemfile.gsub!("%%GEMS%%", gems.join("\n"))
            file.print gemfile
          end
          system %{ bundle install }
          error "Bundler Error" unless $?.exitstatus.zero?
          %x{ git add Gemfile Gemfile.lock }
          %x{ git commit -m "add Gemfile" }
        end
        action("Pushing to Cedar app") do
          %x{ git remote add cedar git@heroku.com:#{new_app}.git 2>&1 }
          system "git push cedar master"
        end
      end
    end

    from = app
  end

private

  def aspen_config_vars
    %w( APP_NAME COMMIT_HASH CONSOLE_AUTH LAST_GIT_BY STACK URL )
  end

  def cedar_config(app)
    {}
  end

end
