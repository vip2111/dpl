require 'net/http'
require 'uri'
require 'find'

module Dpl
  module Providers
    class Bintray < Provider
      gem 'json', '~> 2.2.0'

      description sq(<<-str)
        tbd
      str

      opt '--user USER', 'Bintray user', required: true
      opt '--key KEY', 'Bintray API key', required: true
      opt '--file FILE', 'Path to a descriptor file for the Bintray upload', required: true
      opt '--passphrase PHRASE', 'Passphrase as configured on Bintray (if GPG signing is used)'
      # mentioned in code
      opt '--url URL', default: 'https://api.bintray.com', internal: true

      msgs missing_file:    'Missing descriptor file: %{file}',
           invalid_file:    'Failed to parse descriptor file %{file}',
           create_package:  'Creating package %{package_name}',
           package_attrs:   'Adding attributes for package %{package_name}',
           create_version:  'Creating version %{version_name}',
           version_attrs:   'Adding attributes for version %{version_name}',
           upload_file:     'Uploading file %{source} to %{target}',
           sign_version:    'Signing version %s passphrase',
           publish_version: 'Publishing version %{version_name} of package %{package_name}',
           missing_path:    'Path: %{path} does not exist.',
           unexpected_code: 'Unexpected HTTP response code %s while checking if the %s exists' ,
           request_failed:  '%s %s returned unexpected HTTP response code %s',
           request_success: 'Bintray response: %s %s. %s'

      PATHS = {
        packages:        '/packages/%{subject}/%{repo}',
        package:         '/packages/%{subject}/%{repo}/%{package_name}',
        package_attrs:   '/packages/%{subject}/%{repo}/%{package_name}/attributes',
        versions:        '/packages/%{subject}/%{repo}/%{package_name}/versions',
        version:         '/packages/%{subject}/%{repo}/%{package_name}/versions/%{version_name}',
        version_attrs:   '/packages/%{subject}/%{repo}/%{package_name}/versions/%{version_name}/attributes',
        version_sign:    '/gpg/%{subject}/%{repo}/%{package_name}/versions/%{version_name}',
        version_publish: '/content/%{subject}/%{repo}/%{package_name}/%{version_name}/publish',
        version_file:    '/content/%{subject}/%{repo}/%{package_name}/%{version_name}/%{target}'
      }

      MAP = {
        package: %i(name desc licenses labels vcs_url website_url
          issue_tracker_url public_download_numbers public_stats),
        version: %i(name desc released vcs_tag github_release_notes_file
          github_use_tag_release_notes attributes)
      }

      def install
        require 'json'
      end

      def validate
        error :missing_file unless File.exist?(file)
        # validate that the repo exists, and we have access
      end

      def deploy
        create_package unless package_exists?
        create_version unless version_exists?
        upload_files
        sign_version    if sign_version?
        publish_version if publish_version?
      end

      def package_exists?
        exists?(:package)
      end

      def create_package
        info :create_package
        post(path(:packages), compact(only(package, *MAP[:package])))
        return unless package_attrs
        info :package_attrs
        post(path(:package_attrs), package_attrs)
      end

      def version_exists?
        exists?(:version)
      end

      def create_version
        info :create_version
        post(path(:versions), compact(only(version, *MAP[:version])))
        return unless version_attrs
        info :version_attrs
        post(path(:version_attrs), version_attrs)
      end

      def upload_files
        files.each do |file|
          info :upload_file, source: file.source, target: file.target
          put_file(file.source, path(:version_file, target: file.target), file.params)
        end
      end

      def sign_version
        body = compact(passphrase: passphrase)
        info :sign_version, (passphrase? ? 'with' : 'without')
        post(path(:version_sign), body)
      end

      def publish_version
        info :publish_version
        post(path(:version_publish))
      end

      def files
        return {} unless files = descriptor[:files]
        keys  = %i(path includePattern excludePattern uploadPattern matrixParams)
        files = files.map { |file| file if file[:path] = path_for(file[:includePattern]) }
        files.compact.map { |file| find(*file.values_at(*keys)) }.flatten
      end

      def find(path, includes, excludes, uploads, params)
        paths = Find.find(path).select { |path| File.file?(path) }
        paths = paths.reject { |path| excluded?(path, excludes) }
        paths = paths.map { |path| [path, path.match(/#{includes}/)] }
        paths = paths.select(&:last)
        paths.map { |path, match| Upload.new(path, fmt(uploads, match.captures), params) }
      end

      def fmt(pattern, captures)
        captures.each.with_index.inject(pattern) do |pattern, (capture, ix)|
          pattern.gsub("$#{ix + 1}", capture)
        end
      end

      def excluded?(path, pattern)
        !pattern.to_s.empty? && path.match(/#{pattern}/)
      end

      def path_for(str)
        ix = str.index('(')
        path = ix.to_i == 0 ? str : str[0, ix]
        return path if File.exist?(path)
        warn :missing_path, path: path
        nil
      end

      def exists?(type)
        case code = head(path(type), raise: false, silent: true)
        when 200, 201 then true
        when 404 then false
        else error :unexpected_code, code, type
        end
      end

      def head(path, opts = {})
        req = Net::HTTP::Head.new(path)
        req.basic_auth(user, key)
        request(req, opts)
      end

      def post(path, body = nil)
        req = Net::HTTP::Post.new(path)
        req.add_field('Content-Type', 'application/json')
        req.basic_auth(user, key)
        req.body = JSON.dump(body) if body
        request(req)
      end

      def put_file(source, path, params)
        req = Net::HTTP::Put.new(append_params(path, params))
        req.basic_auth(user, key)
        req.body = IO.read(source)
        request(req)
      end

      def request(req, opts = {})
        res = http.request(req)
        handle(req, res, opts)
        res.code.to_i
      end

      def http
        http = Net::HTTP.new(url.host, url.port)
        http.use_ssl = true
        http
      end

      def append_params(path, params)
        [path, *Array(params).map { |pair| pair.join('=') }].join(';')
      end

      def handle(req, res, opts = { raise: true })
        error :request_failed, req.method, req.uri, res.code if opts[:raise] && !success?(res.code)
        info :request_success, res.code, res.message, parse(res)['message'] unless opts[:silent]
        res.code.to_i
      end

      def success?(code)
        code.to_s[0].to_i == 2
      end

      def descriptor
        @descriptor ||= symbolize(JSON.parse(File.read(file)))
      rescue => e
        error :invalid_file
      end

      def url
        @url ||= URI.parse(super || URL)
      end

      def package
        descriptor[:package]
      end

      def package_name
        package[:name]
      end

      def package_attrs
        package[:attributes]
      end

      def subject
        package[:subject]
      end

      def repo
        package[:repo]
      end

      def version
        descriptor[:version]
      end

      def version_name
        version[:name]
      end

      def version_attrs
        version[:attributes]
      end

      def sign_version?
        version[:gpgSign]
      end

      def publish_version?
        descriptor[:publish]
      end

      def path(resource, args = {})
        interpolate(PATHS[resource], args)
      end

      def parse(json)
        hash = JSON.parse(json)
        hash.is_a?(Hash) ? hash : {}
      rescue
        {}
      end

      def compact(hash)
        hash.reject { |_, value| value.nil? }
      end

      def only(hash, *keys)
        hash.select { |key, _| keys.include?(key) }
      end

      class Upload < Struct.new(:source, :target, :params)
        def eql?(other)
          source == other.source
        end
      end
    end
  end
end
