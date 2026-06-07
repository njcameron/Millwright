require "openssl"
require "json"
require "base64"
require "net/http"
require "uri"
require "time"

module Adapters
  module GithubProjects
    # Generates short-lived installation tokens for a GitHub App.
    # Internal helper used by the GitHub adapters; not exposed in the
    # public adapter interface (worker auth flows through VCS#worker_env).
    class AppToken
      def initialize(app_id:, installation_id:, private_key_path:)
        @app_id = app_id
        @installation_id = installation_id
        @private_key = OpenSSL::PKey::RSA.new(File.read(private_key_path))
      end

      def generate
        jwt = build_jwt
        uri = URI("https://api.github.com/app/installations/#{@installation_id}/access_tokens")
        req = Net::HTTP::Post.new(uri)
        req["Authorization"] = "Bearer #{jwt}"
        req["Accept"] = "application/vnd.github+json"

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        resp = http.request(req)

        unless resp.is_a?(Net::HTTPSuccess)
          raise "Failed to generate installation token: #{resp.code} #{resp.body}"
        end

        JSON.parse(resp.body)["token"]
      end

      private

      def build_jwt
        now = Time.now.to_i
        payload = { iat: now - 60, exp: now + (10 * 60), iss: @app_id }
        header = { alg: "RS256", typ: "JWT" }

        segments = [
          base64url(JSON.generate(header)),
          base64url(JSON.generate(payload))
        ]
        signing_input = segments.join(".")
        signature = @private_key.sign(OpenSSL::Digest::SHA256.new, signing_input)
        segments << base64url(signature)
        segments.join(".")
      end

      def base64url(data)
        Base64.urlsafe_encode64(data, padding: false)
      end
    end
  end
end
