require "minitest/autorun"
require_relative "../../lib/adapters/github/version_control"
require_relative "contracts/version_control_contract"

class GithubVersionControlTest < Minitest::Test
  include VersionControlContract

  def fake_status(ok, code)
    s = Object.new
    s.define_singleton_method(:success?) { ok }
    s.define_singleton_method(:exitstatus) { code }
    s
  end

  # Swap Open3.capture3 for a canned result for the duration of the block,
  # restoring the original afterward. Avoids minitest/mock (not available here).
  def with_capture3(result)
    original = Open3.method(:capture3)
    quietly { Open3.define_singleton_method(:capture3) { |*| result } }
    yield
  ensure
    quietly { Open3.define_singleton_method(:capture3, original) }
  end

  # Run a block with redefinition warnings suppressed.
  def quietly
    verbose = $VERBOSE
    $VERBOSE = nil
    yield
  ensure
    $VERBOSE = verbose
  end

  def real_adapter
    adapter = Adapters::Github::VersionControl.new(TEST_CONFIG.dup)
    adapter.define_singleton_method(:worker_token) { "fake-token" }
    adapter
  end

  # Regression: a failed `gh` comment post used to be silently swallowed
  # (capture2 ignored exit status and dropped stderr), so a 403 looked like
  # success. It must now raise, carrying gh's stderr, so callers can surface it.
  def test_post_pr_comment_raises_on_gh_failure
    adapter = real_adapter
    stderr = "GraphQL: Resource not accessible by integration (addComment)"
    with_capture3(["", stderr, fake_status(false, 1)]) do
      err = assert_raises(RuntimeError) { adapter.post_pr_comment("u/r", 5, "hi") }
      assert_match(/Resource not accessible by integration/, err.message)
    end
  end

  def test_post_review_reply_raises_on_gh_failure
    adapter = real_adapter
    with_capture3(["", "boom", fake_status(false, 1)]) do
      assert_raises(RuntimeError) { adapter.post_review_reply("u/r", 5, 99, "hi") }
    end
  end

  def test_post_pr_comment_returns_stdout_on_success
    adapter = real_adapter
    with_capture3(["posted", "", fake_status(true, 0)]) do
      assert_equal "posted", adapter.post_pr_comment("u/r", 5, "hi")
    end
  end

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
