require "json"
require "open3"
require "net/http"
require "uri"
require_relative "../version_control"
require_relative "../github_projects/app_token"
require_relative "prompts"

module Adapters
  module Github
    # Concrete VersionControl backed by GitHub repos + the `gh` CLI.
    # Also exposes the worker env (GH_TOKEN + git author/committer) since
    # the same App token authenticates both Ruby-side `gh` and the worker's
    # `git push` / `gh` invocations.
    class VersionControl < Adapters::VersionControl
      def initialize(config)
        @config = config
        @prompts = Adapters::Github::Prompts.new
        app = config["github_app"] || {}
        if app["private_key_path"] && File.exist?(app["private_key_path"])
          @app_token = Adapters::GithubProjects::AppToken.new(
            app_id: app["app_id"],
            installation_id: app["installation_id"],
            private_key_path: app["private_key_path"]
          )
        end
      end

      def prompts
        @prompts
      end

      def find_pr_for_issue(repo, issue_number)
        output, status = Open3.capture2(
          "gh", "pr", "list", "-R", repo,
          "--json", "number,headRefName",
          "--jq", ".[] | select(.headRefName | test(\"^#{issue_number}-|^issue-#{issue_number}$\")) | {number, branch: .headRefName}"
        )
        return nil unless status.success?
        line = output.strip
        return nil if line.empty?
        data = JSON.parse(line)
        { number: data["number"], branch: data["branch"] }
      end

      def pr_review_comments(repo, pr_number)
        output, status = Open3.capture2(
          "gh", "api", "repos/#{repo}/pulls/#{pr_number}/comments",
          "--paginate"
        )
        return [] unless status.success?
        JSON.parse(output).map do |c|
          {
            id: c["id"],
            author: c.dig("user", "login") || "",
            body: c["body"] || "",
            in_reply_to_id: c["in_reply_to_id"],
            path: c["path"],
            type: :review
          }
        end
      end

      def pr_issue_comments(repo, pr_number)
        output, status = Open3.capture2(
          "gh", "api", "repos/#{repo}/issues/#{pr_number}/comments",
          "--paginate"
        )
        return [] unless status.success?
        JSON.parse(output).map do |c|
          {
            id: c["id"],
            author: c.dig("user", "login") || "",
            body: c["body"] || "",
            type: :issue
          }
        end
      end

      def post_review_reply(repo, pr_number, comment_id, body)
        env = { "GH_TOKEN" => worker_token }
        run_gh!(
          env,
          "gh", "api", "repos/#{repo}/pulls/#{pr_number}/comments",
          "-f", "body=#{body}", "-F", "in_reply_to=#{comment_id}"
        )
      end

      def post_pr_comment(repo, pr_number, body)
        env = { "GH_TOKEN" => worker_token }
        run_gh!(
          env,
          "gh", "pr", "comment", pr_number.to_s, "-R", repo, "--body", body
        )
      end

      def latest_run_conclusion(repo, branch)
        output, status = Open3.capture2(
          "gh", "run", "list", "-R", repo, "--branch", branch,
          "--json", "conclusion,status", "-L", "1"
        )
        return nil unless status.success?

        runs = JSON.parse(output)
        return nil if runs.empty?

        run = runs.first
        return nil if run["status"] != "completed"
        run["conclusion"]
      end

      def fetch_failed_log(repo, branch)
        output, status = Open3.capture2(
          "gh", "run", "list", "-R", repo, "--branch", branch,
          "--json", "databaseId,status,conclusion", "-L", "1"
        )
        return nil unless status.success?

        runs = JSON.parse(output)
        return nil if runs.empty?

        run_id = runs.first["databaseId"]

        log_output, log_status = Open3.capture2(
          "gh", "run", "view", run_id.to_s, "-R", repo, "--log-failed"
        )
        return nil unless log_status.success?

        log_output.length > 20_000 ? log_output[-20_000..] : log_output
      end

      # Authenticated GET (uses the same App token that authenticates `gh`).
      # Replaces the `gh auth token` backtick + curl in the dispatcher.
      # Returns [body, content_type] on success, or nil on failure. The
      # content type lets callers derive a filename for extensionless URLs
      # (e.g. /user-attachments/assets/<uuid> image attachments).
      def fetch_authenticated(url)
        uri = URI(url)
        req = Net::HTTP::Get.new(uri)
        req["Authorization"] = "token #{worker_token}"

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == "https")
        resp = http.request(req)
        resp.is_a?(Net::HTTPSuccess) ? [resp.body, resp["content-type"]] : nil
      end

      # Env hash merged into the worker's spawn environment so `git push`,
      # `gh` and friends authenticate as the bot and commit with bot identity.
      def worker_env
        bot_name = @config["factory_username"]
        bot_email = "#{@config.dig("github_app", "bot_user_id")}+#{bot_name}@users.noreply.github.com"
        {
          "GH_TOKEN" => worker_token,
          "GIT_AUTHOR_NAME" => bot_name,
          "GIT_AUTHOR_EMAIL" => bot_email,
          "GIT_COMMITTER_NAME" => bot_name,
          "GIT_COMMITTER_EMAIL" => bot_email
        }
      end

      private

      def worker_token
        @app_token ? @app_token.generate : ENV["GH_TOKEN"].to_s
      end

      # Runs a `gh` command, capturing stderr, and raises on non-zero exit so
      # callers can surface the failure instead of it being silently swallowed
      # (capture2 dropped stderr + ignored status, letting e.g. a 403
      # "Resource not accessible by integration" leak to the process stderr and
      # look like success). The raised message carries gh's stderr.
      def run_gh!(env, *cmd)
        stdout, stderr, status = Open3.capture3(env, *cmd)
        unless status.success?
          detail = stderr.strip.empty? ? stdout.strip : stderr.strip
          raise "gh #{cmd[1]} failed (exit #{status.exitstatus}): #{detail}"
        end
        stdout
      end
    end
  end
end
