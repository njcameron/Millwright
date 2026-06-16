require_relative "test_helper"

class StatusTransitionsTest < Minitest::Test
  include OrchestratorTestHelper

  def setup
    @tmpdir = Dir.mktmpdir("status-transitions-test")
    @ctx = build_context(@tmpdir)
    @it = @ctx.issue_tracker
    @vcs = @ctx.vcs
    @transitions = Orchestrator::StatusTransitions.new(@ctx)
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def test_label_triggers_planning_transition
    @it.items = [{ number: 42, repo: "user/repo", title: "Test", status: "In progress", type: "ISSUE" }]
    @it.labels = { ["user/repo", 42] => ["needs review"] }

    statuses_set = []
    @it.define_singleton_method(:set_status) { |n, s, repo: nil| statuses_set << [n, s, repo] }

    @transitions.call
    assert_equal [[42, "cc-planning", "user/repo"]], statuses_set
  end

  def test_open_pr_triggers_in_review_transition
    @it.items = [{ number: 42, repo: "user/repo", title: "Test", status: "In progress", type: "ISSUE" }]
    @vcs.prs = { ["user/repo", 42] => { number: 99, branch: "42-test" } }

    statuses_set = []
    @it.define_singleton_method(:set_status) { |n, s, repo: nil| statuses_set << [n, s, repo] }

    @transitions.call
    assert_equal [[42, "In review", "user/repo"]], statuses_set
  end

  def test_no_transition_when_no_label_or_pr
    @it.items = [{ number: 42, repo: "user/repo", title: "Test", status: "In progress", type: "ISSUE" }]

    statuses_set = []
    @it.define_singleton_method(:set_status) { |n, s, repo: nil| statuses_set << [n, s, repo] }

    @transitions.call
    assert_empty statuses_set
  end

  def test_transition_unlocks_dispatch
    @it.items = [{ number: 42, repo: "user/repo", title: "Test", status: "In progress", type: "ISSUE" }]
    @it.labels = { ["user/repo", 42] => ["needs review"] }
    @it.define_singleton_method(:set_status) { |_, _, repo: nil| true }

    @ctx.dispatch_lock.lock(42)
    assert @ctx.dispatch_lock.locked?(42)

    @transitions.call
    refute @ctx.dispatch_lock.locked?(42)
  end

  def test_pr_transition_unlocks_both_issue_and_pr
    @it.items = [{ number: 42, repo: "user/repo", title: "Test", status: "In progress", type: "ISSUE" }]
    @vcs.prs = { ["user/repo", 42] => { number: 99, branch: "42-test" } }
    @it.define_singleton_method(:set_status) { |_, _, repo: nil| true }

    @ctx.dispatch_lock.lock(42)
    @ctx.dispatch_lock.lock("pr-99")

    @transitions.call
    refute @ctx.dispatch_lock.locked?(42)
    refute @ctx.dispatch_lock.locked?("pr-99")
  end

  # Regression for #3: a failed board move (set_status → false, e.g. the card
  # isn't in the project snapshot) must be surfaced as an error, NOT logged as
  # a successful "moved to cc-planning" while the card silently stays put.
  def test_planning_move_failure_is_surfaced_not_silent
    recorder = RecordingUpdateChannel.new
    ctx = build_context(@tmpdir, update_channel: recorder)
    it = ctx.issue_tracker
    it.items = [{ number: 42, repo: "user/repo", title: "Test", status: "In progress", type: "ISSUE" }]
    it.labels = { ["user/repo", 42] => ["needs review"] }
    it.define_singleton_method(:set_status) { |_, _, repo: nil| false }

    ctx.dispatch_lock.lock(42)
    Orchestrator::StatusTransitions.new(ctx).call

    assert_equal 1, recorder.errors.size
    assert_match(/cc-planning/, recorder.errors.first[:message])
    # The lock stays held so the issue isn't treated as cleanly handed off.
    assert ctx.dispatch_lock.locked?(42)
  end

  def test_review_move_failure_is_surfaced_not_silent
    recorder = RecordingUpdateChannel.new
    ctx = build_context(@tmpdir, update_channel: recorder)
    it = ctx.issue_tracker
    it.items = [{ number: 42, repo: "user/repo", title: "Test", status: "In progress", type: "ISSUE" }]
    ctx.vcs.prs = { ["user/repo", 42] => { number: 99, branch: "42-test" } }
    it.define_singleton_method(:set_status) { |_, _, repo: nil| false }

    Orchestrator::StatusTransitions.new(ctx).call

    assert_equal 1, recorder.errors.size
    assert_match(/In review/, recorder.errors.first[:message])
  end
end
