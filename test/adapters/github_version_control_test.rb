require "minitest/autorun"
require_relative "../../lib/adapters/github/version_control"
require_relative "contracts/version_control_contract"

class GithubVersionControlTest < Minitest::Test
  include VersionControlContract

  TEST_CONFIG = {
    "factory_username" => "test-bot[bot]",
    "github_app" => {
      "app_id" => 1,
      "installation_id" => 1,
      "bot_user_id" => 99,
      "private_key_path" => "/nonexistent"
    }
  }.freeze

  def build_adapter
    adapter = Adapters::Github::VersionControl.new(TEST_CONFIG.dup)
    # Stub every transport method so the contract runs hermetically.
    adapter.define_singleton_method(:find_pr_for_issue) { |*| nil }
    adapter.define_singleton_method(:pr_review_comments) { |*| [] }
    adapter.define_singleton_method(:pr_issue_comments) { |*| [] }
    adapter.define_singleton_method(:post_review_reply) { |*| }
    adapter.define_singleton_method(:post_pr_comment) { |*| }
    adapter.define_singleton_method(:latest_run_conclusion) { |*| nil }
    adapter.define_singleton_method(:fetch_failed_log) { |*| nil }
    adapter.define_singleton_method(:fetch_authenticated) { |*| nil }
    adapter.define_singleton_method(:worker_token) { "fake-token" }
    adapter
  end
end
