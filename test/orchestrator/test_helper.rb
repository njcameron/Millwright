require "minitest/autorun"
require "tmpdir"
require "fileutils"

require_relative "../../lib/orchestrator"
require_relative "../../lib/adapters/github/prompts"
require_relative "../../lib/adapters/github_projects/prompts"
require_relative "../../lib/adapters/slack/prompts"

TEST_CONFIG = {
  "owner" => "testuser",
  "project_number" => 1,
  "project_id" => "PVT_test",
  "max_workers" => 3,
  "max_in_review" => 5,
  "max_ci_fixes" => 2,
  "factory_username" => "test-bot[bot]",
  "slack_webhook" => "https://hooks.slack.com/test",
  "github_app" => {
    "app_id" => 12345,
    "installation_id" => 67890,
    "bot_user_id" => 99999,
    "private_key_path" => "/dev/null"
  },
  "statuses" => {
    "ready" => "Ready",
    "planning" => "cc-planning",
    "planning_approved" => "Planning approved",
    "building" => "In progress",
    "pr" => "In review",
    "done" => "Done"
  }
}.freeze

# Board-state side of the legacy StubGithub.
class StubIssueTracker
  attr_accessor :items, :labels, :issue_bodies

  def initialize
    @items = []
    @labels = {}
    # issue_number => body string
    @issue_bodies = {}
  end

  def issues_by_status(status)
    @items.select { |i| i[:status] == status && i[:type] == "ISSUE" }
  end

  def count_active_workers = 0

  def set_status(_number, _status, repo: nil); end

  def fetch_issue_body(issue_number, repo: nil)
    @issue_bodies.fetch(issue_number, "")
  end

  def flag_for_review?(repo, number)
    (@labels[[repo, number]] || []).any? { |l| l.downcase == "needs review" }
  end

  def mark_flagged_for_review(_repo, _number); end

  def prompts
    @prompts ||= Adapters::GithubProjects::Prompts.new
  end
end

# Repos/PRs/CI side of the legacy StubGithub.
class StubVersionControl
  attr_accessor :review_comments, :issue_comments, :prs, :run_conclusions, :failed_logs, :authenticated_responses

  def initialize
    @review_comments = []
    @issue_comments = []
    @prs = {}
    @run_conclusions = {}
    @failed_logs = {}
    # url => [body, content_type] (or nil to simulate a fetch failure)
    @authenticated_responses = {}
  end

  def find_pr_for_issue(repo, number)
    @prs[[repo, number]]
  end

  def pr_review_comments(_repo, _pr_number) = @review_comments
  def pr_issue_comments(_repo, _pr_number) = @issue_comments

  def post_review_reply(_repo, _pr_number, _comment_id, _body); end
  def post_pr_comment(_repo, _pr_number, _body); end

  def latest_run_conclusion(repo, branch)
    @run_conclusions[[repo, branch]]
  end

  def fetch_failed_log(repo, branch)
    @failed_logs[[repo, branch]]
  end

  # Returns [body, content_type] (or nil) from injected responses, defaulting
  # to nil so tests that don't care about attachments stay hermetic.
  def fetch_authenticated(url)
    @authenticated_responses.fetch(url, nil)
  end

  def worker_env
    { "GH_TOKEN" => "fake-token" }
  end

  def prompts
    @prompts ||= Adapters::Github::Prompts.new
  end
end

class StubUpdateChannel
  def method_missing(*) = nil
  def respond_to_missing?(*) = true

  def worker_env = {}

  def prompts
    @prompts ||= Adapters::Slack::Prompts.new
  end
end
StubNotifier = StubUpdateChannel

module OrchestratorTestHelper
  def build_context(tmpdir, dry_run: false)
    Orchestrator::Context.new(
      config: TEST_CONFIG.dup,
      issue_tracker: StubIssueTracker.new,
      vcs: StubVersionControl.new,
      update_channel: StubUpdateChannel.new,
      dry_run: dry_run,
      state_dir: File.join(tmpdir, "state"),
      logs_dir: File.join(tmpdir, "logs")
    )
  end
end
