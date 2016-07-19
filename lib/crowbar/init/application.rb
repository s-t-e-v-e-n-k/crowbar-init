#
# Copyright 2016, SUSE Linux GmbH
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require "sinatra/base"
require "sinatra/json"
require "sinatra/reloader"
require "haml"
require "tilt/haml"
require "json"
require "uri"
require "net/http"
require "sass"
require "sprockets"
require "sprockets-helpers"
require "bootstrap-sass"
require "font-awesome-sass"

require "chef"

module Crowbar
  module Init
    #
    # Sinatra based web application
    #
    class Application < Sinatra::Base
      set :root, File.expand_path("../../../..", __FILE__)
      set :bind, "0.0.0.0"
      set :logging, true
      set :haml, format: :html5, attr_wrapper: "\""

      set :sprockets, Sprockets::Environment.new(root)
      set :assets_prefix, "/assets"
      set :digest_assets, false

      configure do
        logpath = if settings.environment == :development
          "#{settings.root}/log/#{settings.environment}.log"
        else
          "/var/log/crowbar/crowbar-init-#{settings.environment}.log"
        end
        logfile = File.new(logpath, "a+")
        logfile.sync = true
        use Rack::CommonLogger, logfile

        sprockets.append_path File.join(root, "assets", "stylesheets")
        sprockets.append_path File.join(root, "vendor", "assets", "stylesheets")

        sprockets.append_path File.join(root, "assets", "javascripts")
        sprockets.append_path File.join(root, "vendor", "assets", "javascripts")

        Sprockets::Helpers.configure do |config|
          config.environment = sprockets
          config.prefix = assets_prefix
          config.digest = digest_assets
          config.public_path = public_folder
          config.debug = true if development?
        end
      end

      configure :development do
        register Sinatra::Reloader
      end

      helpers do
        include Sprockets::Helpers

        def chef_config_path
          Pathname.new("#{settings.root}/chef")
        end

        def chef(attributes)
          Chef::Config[:solo] = true
          Chef::Config.from_file("#{chef_config_path}/solo.rb")
          client = Chef::Client.new(
            attributes,
            override_runlist: ["recipe[postgresql]"]
          )
          logger.debug("Running chef solo with: #{client.inspect}")
          client.run
        end

        def installer_url
          "http://localhost:3000/installer/installer"
        end

        def status_url
          "#{installer_url}/status.json"
        end

        def symlink_apache_to(name)
          crowbar_apache_conf = "#{crowbar_apache_path}/crowbar.conf"
          crowbar_apache_conf_partial = "crowbar-#{name}.conf.partial"

          logger.debug(
            "Creating symbolic link for #{crowbar_apache_conf} to #{crowbar_apache_conf_partial}"
          )
          system(
            "sudo",
            "ln",
            "-sf",
            crowbar_apache_conf_partial,
            crowbar_apache_conf
          )
        end

        def reload_apache
          logger.debug("Reloading apache")
          system(
            "sudo",
            "systemctl",
            "reload",
            "apache2.service"
          )
        end

        def crowbar_apache_path
          "/etc/apache2/conf.d/crowbar"
        end

        def cleanup_db
          logger.debug("Creating and migrating crowbar database")
          Dir.chdir("/opt/dell/crowbar_framework") do
            system(
              "RAILS_ENV=production",
              "bin/rake",
              "db:cleanup"
            )
          end
        end

        def crowbar_service(action)
          logger.debug("#{action.capitalize}ing crowbar service")
          system(
            "sudo",
            "systemctl",
            action.to_s,
            "crowbar.service"
          )
        end

        def crowbar_status(request_type = :html)
          uri = if request_type == :html
            URI.parse(installer_url)
          else
            URI.parse(status_url)
          end

          res = Net::HTTP.new(
            uri.host,
            uri.port
          ).request(
            Net::HTTP::Get.new(
              uri.request_uri
            )
          )

          body = if request_type == :html
            res.body
          else
            JSON.parse(res.body)
          end

          {
            code: res.code,
            body: body
          }
        rescue
          {
            code: 500,
            body: nil
          }
        end

        def wait_for_crowbar
          logger.debug("Waiting for crowbar to become available")
          sleep 1 until crowbar_status[:body]
          sleep 1 until crowbar_status[:body].include? "installer-installers"

          # apache takes some time to perform the final switch
          # TODO: implement a busyloop
          sleep 15
        end
      end

      get "/" do
        haml :index
      end

      post "/init" do
        cleanup_db
        crowbar_service(:start)
        symlink_apache_to(:rails)
        reload_apache
        wait_for_crowbar

        redirect "/installer/installer"
      end

      post "/reset" do
        crowbar_service(:stop)
        cleanup_db
        symlink_apache_to(:sinatra)
        reload_apache

        redirect "/"
      end

      get "/status" do
        json crowbar_status(:json)
      end

      post "/database/new" do
        attributes = {
          postgresql: {
            username: params[:username],
            password: params[:password]
          },
          run_list: ["recipe[postgresql]"]
        }

        logger.debug("Creating Crowbar database")
        if chef(attributes)
          json(
            code: 200,
            body: nil
          )
        else
          json(
            code: 500,
            body: {
              error: "Could not create database. Please have a look at /var/log/chef/solo.log"
            }
          )
        end
      end

      post "/database/connect" do
        attributes = {
          postgresql: {
            username: params[:username],
            password: params[:password],
            host: params[:host],
            port: params[:port]
          },
          run_list: ["recipe[postgresql]"]
        }

        logger.debug("Connecting Crowbar to external database")
        if chef(attributes)
          json(
            code: 200,
            body: nil
          )
        else
          json(
            code: 500,
            body: {
              error: "Could not connect to database. Please have a look at /var/log/chef/solo.log"
            }
          )
        end
      end

      get "/assets/*" do
        settings.sprockets.call(
          env.merge(
            "PATH_INFO" => params[:splat].first
          )
        )
      end
    end
  end
end
