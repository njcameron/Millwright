require_relative "test_helper"

class PlanCommentHandlerTest < Minitest::Test
  include OrchestratorTestHelper

  def setup
    @tmpdir = Dir.mktmpdir("plan-comment-handler-test")
    @ctx = build_context(@tmpdir)
    @it = @ctx.issue_tracker
    @vcs = @ctx.vcs
    @handler = Orchestrator::PlanCommentHandler.new(@ctx)
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  # --- find_unaddressed_comments -------------------------------------------

  def test_feedback_after_plan_is_unaddressed
    @vcs.issue_comments = [
      { id: 1, author: "test-bot[bot]", body: "## Plan: do the thing", type: :issue },
      { id: 2, author: "human", body: "Make it a standalone account", type: :issue }
    ]

    result = @handler.find_unaddressed_comments("user/repo", 530, "test-bot[bot]")
    assert_equal 1, result.size
    assert_equal "Make it a standalone account", result[0][:body]
  end

  def test_feedback_addressed_by_later_bot_comment
    @vcs.issue_comments = [
      { id: 1, author: "test-bot[bot]", body: "## Plan", type: :issue },
      { id: 2, author: "human", body: "tweak this", type: :issue },
      { id: 3, author: "test-bot[bot]", body: "## Revised plan", type: :issue }
    ]

    result = @handler.find_unaddressed_comments("user/repo", 530, "test-bot[bot]")
    assert_empty result
  end

  def test_new_feedback_after_revision_is_unaddressed
    @vcs.issue_comments = [
      { id: 1, author: "test-bot[bot]", body: "## Plan", type: :issue },
      { id: 2, author: "human", body: "tweak this", type: :issue },
      { id: 3, author: "test-bot[bot]", body: "## Revised plan", type: :issue },
      { id: 4, author: "human", body: "also handle the empty case", type: :issue }
    ]

    result = @handler.find_unaddressed_comments("user/repo", 530, "test-bot[bot]")
    assert_equal 1, result.size
    assert_equal "also handle the empty case", result[0][:body]
  end

  def test_bot_only_comments_are_never_unaddressed
    @vcs.issue_comments = [
      { id: 1, author: "test-bot[bot]", body: "## Plan", type: :issue }
    ]

    assert_empty @handler.find_unaddressed_comments("user/repo", 530, "test-bot[bot]")
  end

  def test_claude_mention_is_ignored
    @vcs.issue_comments = [
      { id: 1, author: "test-bot[bot]", body: "## Plan", type: :issue },
      { id: 2, author: "human", body: "@claude please handle this differently", type: :issue }
    ]

    assert_empty @handler.find_unaddressed_comments("user/repo", 530, "test-bot[bot]")
  end

  def test_ignored_bot_author_is_skipped
    @vcs.issue_comments = [
      { id: 1, author: "test-bot[bot]", body: "## Plan", type: :issue },
      { id: 2, author: "cloudflare-workers-and-pages", body: "Preview ready", type: :issue }
    ]

    assert_empty @handler.find_unaddressed_comments("user/repo", 530, "test-bot[bot]")
  end

  # --- call() ---------------------------------------------------------------

  # When the local repo checkout is missing, the handler must surface the
  # failure to the update channel rather than silently re-detecting the same
  # comment every tick (mirrors PrCommentHandler's contract).
  def test_missing_checkout_surfaces_error_notification
    channel = RecordingUpdateChannel.new
    ctx = build_context(@tmpdir, update_channel: channel)
    repo = "user/definitely-not-a-real-checkout"
    ctx.issue_tracker.items = [
      { number: 530, status: "cc-planning", type: "ISSUE", repo: repo }
    ]
    ctx.vcs.issue_comments = [
      { id: 1, author: "test-bot[bot]", body: "## Plan", type: :issue },
      { id: 2, author: "human", body: "revise it", type: :issue }
    ]
    handler = Orchestrator::PlanCommentHandler.new(ctx)

    capture_io { handler.call(1) }

    assert_equal 1, channel.errors.size
    assert_match(/repo checkout not found/, channel.errors[0][:message])
    assert_equal repo, channel.errors[0][:fields]["Repo"]
  end

  def test_dispatch_lock_skips_revision_while_worker_runs
    channel = RecordingUpdateChannel.new
    ctx = build_context(@tmpdir, update_channel: channel)
    repo = "user/definitely-not-a-real-checkout"
    ctx.issue_tracker.items = [
      { number: 530, status: "cc-planning", type: "ISSUE", repo: repo }
    ]
    ctx.vcs.issue_comments = [
      { id: 1, author: "test-bot[bot]", body: "## Plan", type: :issue },
      { id: 2, author: "human", body: "revise it", type: :issue }
    ]
    ctx.dispatch_lock.lock("plan-530")
    ctx.dispatch_lock.record_pid("plan-530", Process.pid) # worker alive
    handler = Orchestrator::PlanCommentHandler.new(ctx)

    capture_io { handler.call(1) }

    # Locked with a live worker → returns before the checkout check.
    assert ctx.dispatch_lock.locked?("plan-530"), "lock kept while worker runs"
    assert_empty channel.errors
  end

  # Regression: the plan-N lock from a finished revision must be released once
  # its worker exits, instead of lingering for the full TTL and blocking the
  # next round of reviewer feedback. A dead recorded pid → lock reaped → the
  # handler proceeds to dispatch (here it reaches the missing-checkout path).
  def test_finished_worker_lock_is_reaped_and_redispatches
    channel = RecordingUpdateChannel.new
    ctx = build_context(@tmpdir, update_channel: channel)
    repo = "user/definitely-not-a-real-checkout"
    ctx.issue_tracker.items = [
      { number: 530, status: "cc-planning", type: "ISSUE", repo: repo }
    ]
    ctx.vcs.issue_comments = [
      { id: 1, author: "test-bot[bot]", body: "## Plan", type: :issue },
      { id: 2, author: "human", body: "round two feedback", type: :issue }
    ]
    ctx.dispatch_lock.lock("plan-530")
    ctx.dispatch_lock.record_pid("plan-530", 999_999) # dead pid
    handler = Orchestrator::PlanCommentHandler.new(ctx)

    capture_io { handler.call(1) }

    refute ctx.dispatch_lock.locked?("plan-530"), "stale lock should be reaped"
    assert_equal 1, channel.errors.size, "should proceed to dispatch (missing checkout)"
  end

  def test_dry_run_does_not_dispatch
    channel = RecordingUpdateChannel.new
    ctx = build_context(@tmpdir, dry_run: true, update_channel: channel)
    repo = "user/definitely-not-a-real-checkout"
    ctx.issue_tracker.items = [
      { number: 530, status: "cc-planning", type: "ISSUE", repo: repo }
    ]
    ctx.vcs.issue_comments = [
      { id: 1, author: "test-bot[bot]", body: "## Plan", type: :issue },
      { id: 2, author: "human", body: "revise it", type: :issue }
    ]
    handler = Orchestrator::PlanCommentHandler.new(ctx)

    capture_io { handler.call(1) }

    # Dry run short-circuits before the checkout check — nothing dispatched.
    assert_empty channel.errors
  end
end
