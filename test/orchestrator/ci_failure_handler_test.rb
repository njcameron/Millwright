require_relative "test_helper"

class CiFailureHandlerTest < Minitest::Test
  include OrchestratorTestHelper

  def setup
    @tmpdir = Dir.mktmpdir("ci-failure-handler-test")
    @ctx = build_context(@tmpdir)
    @it = @ctx.issue_tracker; @vcs = @ctx.vcs
    @handler = Orchestrator::CiFailureHandler.new(@ctx)
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def with_pr_in_review
    @it.items = [{ number: 42, repo: "user/repo", title: "Test", status: "In review", type: "ISSUE" }]
    @vcs.prs = { ["user/repo", 42] => { number: 99, branch: "42-test" } }
  end

  def test_ci_failure_dispatches_fix
    with_pr_in_review
    @vcs.define_singleton_method(:latest_run_conclusion) { |_repo, _branch| "failure" }
    @vcs.define_singleton_method(:fetch_failed_log) { |_repo, _branch| "Error: test failed\nexpected true, got false" }

    dispatched = []
    @handler.define_singleton_method(:dispatch_ci_fix) do |_issue, _repo, pr_number, pr_branch, _log|
      dispatched << { pr_number: pr_number, pr_branch: pr_branch }
    end

    @handler.call(2)
    assert_equal 1, dispatched.size
    assert_equal 99, dispatched[0][:pr_number]
    assert_equal "42-test", dispatched[0][:pr_branch]
  end

  def test_ci_success_skips_fix
    with_pr_in_review
    @vcs.define_singleton_method(:latest_run_conclusion) { |_repo, _branch| "success" }

    dispatched = []
    @handler.define_singleton_method(:dispatch_ci_fix) do |*args|
      dispatched << args
    end

    @handler.call(2)
    assert_empty dispatched
  end

  def test_ci_pending_skips_fix
    with_pr_in_review
    @vcs.define_singleton_method(:latest_run_conclusion) { |_repo, _branch| nil }

    dispatched = []
    @handler.define_singleton_method(:dispatch_ci_fix) do |*args|
      dispatched << args
    end

    @handler.call(2)
    assert_empty dispatched
  end

  def test_ci_fix_respects_max_retries
    with_pr_in_review
    @vcs.define_singleton_method(:latest_run_conclusion) { |_repo, _branch| "failure" }
    @vcs.define_singleton_method(:fetch_failed_log) { |_repo, _branch| "Error: test failed" }

    File.write(File.join(@ctx.state_dir, "ci_fix_count_99"), "2")

    dispatched = []
    @handler.define_singleton_method(:dispatch_ci_fix) do |*args|
      dispatched << args
    end

    gave_up_calls = []
    @ctx.update_channel.define_singleton_method(:ci_fix_gave_up) do |issue_number, _repo, pr_number, attempts|
      gave_up_calls << { issue_number: issue_number, pr_number: pr_number, attempts: attempts }
    end

    @handler.call(2)
    assert_empty dispatched
    assert_equal 1, gave_up_calls.size
    assert_equal 99, gave_up_calls[0][:pr_number]
  end

  def test_ci_fix_uses_dispatch_lock
    with_pr_in_review
    @vcs.define_singleton_method(:latest_run_conclusion) { |_repo, _branch| "failure" }
    @vcs.define_singleton_method(:fetch_failed_log) { |_repo, _branch| "Error: test failed" }

    @ctx.dispatch_lock.lock("ci-99")

    dispatched = []
    @handler.define_singleton_method(:dispatch_ci_fix) do |*args|
      dispatched << args
    end

    @handler.call(2)
    assert_empty dispatched
  end

  def test_ci_success_resets_fix_count
    with_pr_in_review
    File.write(File.join(@ctx.state_dir, "ci_fix_count_99"), "1")
    @vcs.define_singleton_method(:latest_run_conclusion) { |_repo, _branch| "success" }

    @handler.call(2)
    assert_equal 0, @handler.send(:ci_fix_count, 99)
  end
end
