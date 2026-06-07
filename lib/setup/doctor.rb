require "yaml"
require "open3"
require "json"
require "openssl"
require_relative "../adapters/github_projects/app_token"
require_relative "../adapters/slack/update_channel"

module Setup
  # Read-only preflight for a Millwright install. Verifies the environment,
  # config.yml, GitHub App credentials, project board, and (optionally) the
  # Slack webhook, then reports pass/fail/warn/skip with remediation hints.
  #
  # Verification ONLY — never writes config, never mutates the board, never
  # installs cron. The single non-read-only action is the Slack test post,
  # which `--no-slack` suppresses. Both the `setup-millwright` skill and the
  # README agent pullout key off its exit code (0 == all green).
  #
  # IO seams (gh/network/bundler) are isolated in small probe methods so tests
  # can stub them via dependency injection without hitting real services.
  class Doctor
    MIN_RUBY = "3.2.0".freeze
    REQUIRED_STATUSES = %w[ready planning planning_approved building pr done].freeze

    # config key paths that must be present and non-placeholder.
    REQUIRED_KEYS = [
      %w[owner],
      %w[project_number],
      %w[project_id],
      %w[factory_username],
      %w[github_app app_id],
      %w[github_app installation_id],
      %w[github_app bot_user_id],
      %w[github_app private_key_path],
      *REQUIRED_STATUSES.map { |s| ["statuses", s] }
    ].freeze

    # Ordered check registry. Each entry maps to a check_<name> method.
    CHECKS = %i[
      ruby_version
      bundler
      claude_cli
      config_file
      required_keys
      private_key
      gh_auth
      github_app_token
      board_statuses
      slack_webhook
    ].freeze

    SYMBOLS = { pass: "✓", fail: "✗", warn: "!", skip: "–" }.freeze

    Result = Struct.new(:check, :status, :detail, :hint, keyword_init: true) do
      def to_h
        { check: check.to_s, status: status.to_s, detail: detail, hint: hint }
      end
    end

    # Builds a Doctor for a repo, loading config.yml and capturing any YAML
    # syntax error so check_config_file can report it cleanly.
    def self.for_repo(repo_root, skip_slack: false)
      path = File.join(repo_root, "config.yml")
      config = nil
      config_error = nil
      if File.exist?(path)
        begin
          config = YAML.load_file(path)
        rescue Psych::SyntaxError => e
          config_error = e.message
        end
      end
      new(repo_root: repo_root, config: config, config_error: config_error, skip_slack: skip_slack)
    end

    def initialize(repo_root:, config:, config_error: nil, skip_slack: false)
      @repo_root = repo_root
      @config = config
      @config_error = config_error
      @skip_slack = skip_slack
    end

    # Runs the checks (optionally a single one) and returns [Result].
    def run(only: nil)
      checks = only ? CHECKS.select { |c| c == only.to_s.to_sym } : CHECKS
      checks.map { |name| send("check_#{name}") }
    end

    def success?(results)
      results.none? { |r| r.status == :fail }
    end

    # ---- report formatting (pure; unit-tested directly) ----

    def format_report(results)
      lines = ["Millwright preflight (bin/doctor)", ""]
      results.each do |r|
        lines << "#{SYMBOLS[r.status]} #{r.check}: #{scrub(r.detail)}"
        lines << "    ↳ #{scrub(r.hint)}" if r.hint && (r.status == :fail || r.status == :warn)
      end
      lines << ""
      counts = results.group_by(&:status).transform_values(&:size)
      lines << "#{counts.fetch(:pass, 0)} passed, #{counts.fetch(:fail, 0)} failed, " \
               "#{counts.fetch(:warn, 0)} warning(s), #{counts.fetch(:skip, 0)} skipped"
      lines << (success?(results) ? "All checks green ✅" : "Some checks failed ❌")
      lines.join("\n")
    end

    def format_json(results)
      JSON.pretty_generate(results.map { |r| r.to_h.transform_values { |v| v.is_a?(String) ? scrub(v) : v } })
    end

    # Replaces anything that looks like a secret with a placeholder. Detail
    # strings are built secret-free by construction; this is a belt-and-braces
    # net so an exception message can never leak a token, pem, or webhook URL.
    def scrub(text)
      return text unless text.is_a?(String)
      out = text.dup
      out.gsub!(webhook_url, "[redacted-webhook]") if webhook_url && !webhook_url.empty?
      out.gsub!(/gh[posru]_[A-Za-z0-9]{20,}/, "[redacted-token]")
      out.gsub!(/-----BEGIN[^-]+PRIVATE KEY-----.*?-----END[^-]+PRIVATE KEY-----/m, "[redacted-key]")
      out
    end

    # ---- checks ----

    def check_ruby_version
      if Gem::Version.new(RUBY_VERSION) >= Gem::Version.new(MIN_RUBY)
        pass(:ruby_version, "Ruby #{RUBY_VERSION} (>= #{MIN_RUBY}).")
      else
        fail(:ruby_version, "Ruby #{RUBY_VERSION} is below the required #{MIN_RUBY}.",
             "Install Ruby #{MIN_RUBY}+ (see .ruby-version).")
      end
    end

    def check_bundler
      out, ok = bundler_status
      if ok
        pass(:bundler, "Bundler dependencies satisfied.")
      else
        fail(:bundler, "Bundler dependencies are not satisfied. #{out.lines.first&.strip}".strip,
             "Run: bundle install")
      end
    end

    def check_claude_cli
      bin = @config&.dig("coding_agent", "bin") || "claude"
      path = which(bin)
      if path
        pass(:claude_cli, "Coding agent found: #{path}")
      else
        warn(:claude_cli, "`#{bin}` not found on PATH.",
             "Install the Claude CLI or set coding_agent.bin to an absolute path. " \
             "Note: cron runs with a minimal PATH (see README).")
      end
    end

    def check_config_file
      if @config_error
        return fail(:config_file, "config.yml is not valid YAML.", "Fix the syntax: #{@config_error}")
      end
      if @config.nil?
        return fail(:config_file, "config.yml not found at the repo root.",
                    "Copy config.example.yml to config.yml and fill it in — or run the setup-millwright skill.")
      end
      pass(:config_file, "config.yml present and parsed.")
    end

    def check_required_keys
      return skip_no_config(:required_keys) unless config_ready?

      problems = REQUIRED_KEYS.each_with_object([]) do |path, acc|
        value = @config.dig(*path)
        label = path.join(".")
        if value.nil?
          acc << "#{label} (missing)"
        elsif placeholder?(value)
          acc << "#{label} (placeholder)"
        end
      end

      if problems.empty?
        pass(:required_keys, "All required config keys present.")
      else
        fail(:required_keys, "Missing or placeholder keys: #{problems.join(", ")}.",
             "Fill these in config.yml (the setup-millwright skill can do this for you).")
      end
    end

    def check_private_key
      return skip_no_config(:private_key) unless config_ready?

      raw = @config.dig("github_app", "private_key_path")
      return fail(:private_key, "github_app.private_key_path is not set.", "Point it at your App's .pem file.") if raw.nil?

      path = File.absolute_path?(raw) ? raw : File.join(@repo_root, raw)
      unless File.exist?(path) && File.readable?(path)
        return fail(:private_key, "Private key not found or unreadable at #{path}.",
                    "Download the App's .pem and place it there (chmod 600).")
      end

      begin
        OpenSSL::PKey::RSA.new(File.read(path))
      rescue StandardError => e
        return fail(:private_key, "Private key at #{path} could not be parsed as RSA.", "Re-download the .pem: #{e.message}")
      end

      if bare_relative?(raw)
        warn(:private_key, "Private key OK, but private_key_path is a bare relative path.",
             "Cron cd's into the repo, so this works — but an absolute path is safer.")
      else
        pass(:private_key, "Private key present and valid (#{path}).")
      end
    end

    def check_gh_auth
      out, ok = gh_auth_result
      return fail(:gh_auth, "gh is not authenticated.", "Run: gh auth login") unless ok

      scopes = out[/Token scopes:.*/i].to_s
      if scopes.downcase.include?("project")
        pass(:gh_auth, "gh authenticated with project scope.")
      else
        warn(:gh_auth, "gh authenticated, but the 'project' scope was not detected.",
             "Run: gh auth refresh -s project (the board check below is authoritative).")
      end
    end

    def check_github_app_token
      return skip_no_config(:github_app_token) unless config_ready?
      return skip(:github_app_token, "Skipped — fix the private key first.") unless private_key_usable?

      begin
        token = generate_app_token
        ok = token.is_a?(String) && !token.empty?
        ok ? pass(:github_app_token, "GitHub App installation token issued successfully.")
           : fail(:github_app_token, "Token exchange returned no token.", "Re-check app_id / installation_id / private key.")
      rescue StandardError => e
        hint = case e.message
               when /401/ then "401 — bad private key or app_id."
               when /404/ then "404 — bad installation_id (is the App installed on your repos?)."
               else "Check app_id, installation_id, and the .pem are mutually consistent."
               end
        fail(:github_app_token, "GitHub App token exchange failed.", "#{hint} (#{scrub(e.message)})")
      end
    end

    def check_board_statuses
      return skip_no_config(:board_statuses) unless config_ready?

      board = fetch_board_options
      unless board
        return fail(:board_statuses, "Could not read the project board's Status field.",
                    "Check owner / project_number / project_id and gh project scope. Is this an org-owned project?")
      end

      configured = REQUIRED_STATUSES.map { |s| @config.dig("statuses", s).to_s }
      names = board[:names].map { |n| n.to_s.downcase }
      missing = configured.reject { |s| names.include?(s.downcase) }

      if missing.empty?
        pass(:board_statuses, "All six status columns present on the #{board[:owner_type]}-owned board.")
      else
        fail(:board_statuses, "Configured statuses with no matching board column: #{missing.join(", ")}.",
             "Rename the board columns or fix statuses.* to match exactly (case-insensitive).")
      end
    end

    def check_slack_webhook
      return skip(:slack_webhook, "Skipped (--no-slack).") if @skip_slack
      if webhook_url.nil? || webhook_url.empty? || placeholder?(webhook_url)
        return skip(:slack_webhook, "No Slack webhook configured — notifications disabled (optional).")
      end

      begin
        resp = slack_test_response
        code = resp.respond_to?(:code) ? resp.code.to_i : 0
        if code.between?(200, 299)
          pass(:slack_webhook, "Posted a test message to Slack (HTTP #{code}).")
        else
          fail(:slack_webhook, "Slack webhook returned HTTP #{code}.", "Check the webhook URL is current and not revoked.")
        end
      rescue StandardError => e
        fail(:slack_webhook, "Slack test post failed.", scrub(e.message))
      end
    end

    private

    # ---- IO probes (overridden in tests) ----

    def bundler_status
      Open3.capture2e("bundle", "check")
    rescue StandardError => e
      [e.message, false]
    end

    def gh_auth_result
      Open3.capture2e("gh", "auth", "status")
    rescue StandardError => e
      [e.message, false]
    end

    def generate_app_token
      app = @config["github_app"]
      Adapters::GithubProjects::AppToken.new(
        app_id: app["app_id"],
        installation_id: app["installation_id"],
        private_key_path: absolute_key_path
      ).generate
    end

    # Tries a user-owned project, then falls back to an org-owned one. The
    # orchestrator's own status query hardcodes user(login:) and silently
    # returns null for org projects (a latent bug — see docs/specs); doctor
    # handles both so a fresh org user gets a clear answer.
    def fetch_board_options
      %w[user organization].each do |owner_type|
        query = <<~GRAPHQL
          query($owner: String!, $number: Int!) {
            #{owner_type}(login: $owner) {
              projectV2(number: $number) {
                field(name: "Status") {
                  ... on ProjectV2SingleSelectField { options { name } }
                }
              }
            }
          }
        GRAPHQL
        # capture3 so gh's own stderr (e.g. "Could not resolve to a User")
        # doesn't leak into doctor's output; we only parse stdout.
        out, _err, st = Open3.capture3(
          "gh", "api", "graphql",
          "-f", "query=#{query}",
          "-f", "owner=#{@config["owner"]}",
          "-F", "number=#{@config["project_number"]}"
        )
        next unless st.success?
        field = JSON.parse(out).dig("data", owner_type, "projectV2", "field")
        return { names: field["options"].map { |o| o["name"] }, owner_type: owner_type } if field && field["options"]
      end
      nil
    rescue StandardError
      nil
    end

    def slack_test_response
      Adapters::Slack::UpdateChannel.new(@config).test_post
    end

    # ---- helpers ----

    def config_ready?
      @config_error.nil? && !@config.nil?
    end

    def private_key_usable?
      raw = @config.dig("github_app", "private_key_path")
      return false if raw.nil?
      File.exist?(absolute_key_path)
    end

    def absolute_key_path
      raw = @config.dig("github_app", "private_key_path").to_s
      File.absolute_path?(raw) ? raw : File.join(@repo_root, raw)
    end

    def webhook_url
      @webhook_url ||= ENV["SLACK_WEBHOOK"] || @config&.dig("slack_webhook")
    end

    def which(bin)
      return bin if bin.include?("/") && File.executable?(bin)
      ENV["PATH"].to_s.split(File::PATH_SEPARATOR).map { |d| File.join(d, bin) }.find { |p| File.executable?(p) }
    end

    def placeholder?(value)
      case value
      when String then value.strip.empty? || value.include?("<") || value.include?("your-")
      when Integer then value.zero?
      when nil then true
      else false
      end
    end

    def bare_relative?(path)
      !File.absolute_path?(path) && !path.to_s.start_with?(".")
    end

    def pass(check, detail)  = Result.new(check: check, status: :pass, detail: detail)
    def fail(check, detail, hint = nil) = Result.new(check: check, status: :fail, detail: detail, hint: hint)
    def warn(check, detail, hint = nil) = Result.new(check: check, status: :warn, detail: detail, hint: hint)
    def skip(check, detail)  = Result.new(check: check, status: :skip, detail: detail)

    def skip_no_config(check)
      skip(check, "Skipped — config.yml must be present and valid first.")
    end
  end
end

# CLI entrypoint
if __FILE__ == $PROGRAM_NAME
  repo_root = File.expand_path("../..", __dir__)
  json = ARGV.include?("--json")
  no_slack = ARGV.include?("--no-slack")
  only = (idx = ARGV.index("--only")) ? ARGV[idx + 1] : nil

  doctor = Setup::Doctor.for_repo(repo_root, skip_slack: no_slack)
  results = doctor.run(only: only)

  puts(json ? doctor.format_json(results) : doctor.format_report(results))
  exit(doctor.success?(results) ? 0 : 1)
end
