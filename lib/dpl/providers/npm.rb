module Dpl
  module Providers
    class Npm < Provider
      gem 'json', '~> 2.2.0'

      full_name 'npm'

      description sq(<<-str)
        tbd
      str

      opt '--api_key KEY', 'npm api key (can be retrieved from your local ~/.npmrc file)', required: true
      opt '--email EMAIL', 'npm email address'
      opt '--access ACCESS', 'access level', enum: %w(public private)
      opt '--registry URL', 'npm registry url'
      opt '--tag TAGS', 'npm distribution tags to add'

      REGISTRY = 'registry.npmjs.org'
      NPMRC = '~/.npmrc'

      msgs version:  'npm version: %{npm_version}',
           login:    'Authenticated with API key %{obfuscated_api_key}'

      cmds registry: 'npm config set registry "%{registry}"',
           deploy:   'npm publish %{publish_opts}'

      errs registry: 'Failed to set registry config',
           deploy:    'Failed pushing to npm'

      def login
        info :version
        info :login
        write_npmrc
        shell :registry, assert: true
      end

      def deploy
        shell :deploy, assert: true
      end

      def finish
        remove_npmrc
      end

      private

        def publish_opts
          opts_for(%i(access tag))
        end

        def write_npmrc
          write_file(npmrc_path, npmrc)
          info "#{NPMRC} size: #{file_size(npmrc_path)}"
        end

        def remove_npmrc
          rm_f npmrc_path
        end

        def npmrc_path
          File.expand_path(NPMRC)
        end

        def npmrc
          if npm_version =~ /^1/
            "_auth = #{api_key}\nemail = #{email}"
          else
            "//#{registry.sub('https://', '').sub(%r(/$), '')}/:_authToken=#{api_key}"
          end
        end

        def registry
          return super if super
          data = package_json
          url = data && data.fetch('publishConfig', {})['registry']
          url ? URI(url).host : REGISTRY
        end

        def package_json
          File.exists?('package.json') ? JSON.parse(File.read('package.json')) : {}
        end
    end
  end
end
