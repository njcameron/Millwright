require_relative "test_helper"

class PrCommentHandlerTest < Minitest::Test
  include OrchestratorTestHelper

  def setup
    @tmpdir = Dir.mktmpdir("pr-comment-handler-test")
    @ctx = build_context(@tmpdir)
    @it = @ctx.issue_tracker; @vcs = @ctx.vcs
    @handler = Orchestrator::PrCommentHandler.new(@ctx)
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def test_unaddressed_review_comment
    @vcs.review_comments = [
      { id: 1, author: "human", body: "Fix this", in_reply_to_id: nil, type: :review }
    ]

    result = @handler.find_unaddressed_comments("user/repo", 10, "test-bot[bot]")
    assert_equal 1, result.size
    assert_equal "Fix this", result[0][:body]
  end

  def test_review_comment_addressed_by_bot_reply
    @vcs.review_comments = [
      { id: 1, author: "human", body: "Fix this", in_reply_to_id: nil, type: :review },
      { id: 2, author: "test-bot[bot]", body: "Done", in_reply_to_id: 1, type: :review }
    ]

    result = @handler.find_unaddressed_comments("user/repo", 10, "test-bot[bot]")
    assert_empty result
  end

  def test_review_reply_not_treated_as_top_level
    @vcs.review_comments = [
      { id: 1, author: "human", body: "Fix this", in_reply_to_id: nil, type: :review },
      { id: 2, author: "test-bot[bot]", body: "Done", in_reply_to_id: 1, type: :review },
      { id: 3, author: "human", body: "Actually no", in_reply_to_id: 1, type: :review }
    ]

    result = @handler.find_unaddressed_comments("user/repo", 10, "test-bot[bot]")
    assert_empty result
  end

  def test_unaddressed_issue_comment
    @vcs.issue_comments = [
      { id: 10, author: "human", body: "Please change X", type: :issue }
    ]

    result = @handler.find_unaddressed_comments("user/repo", 10, "test-bot[bot]")
    assert_equal 1, result.size
    assert_equal "Please change X", result[0][:body]
  end

  def test_issue_comment_addressed_by_later_bot_comment
    @vcs.issue_comments = [
      { id: 10, author: "human", body: "Please change X", type: :issue },
      { id: 11, author: "test-bot[bot]", body: "Done, changed X", type: :issue }
    ]

    result = @handler.find_unaddressed_comments("user/repo", 10, "test-bot[bot]")
    assert_empty result
  end

  def test_new_human_comment_after_bot_reply_is_unaddressed
    @vcs.issue_comments = [
      { id: 10, author: "human", body: "Change X", type: :issue },
      { id: 11, author: "test-bot[bot]", body: "Done", type: :issue },
      { id: 12, author: "human", body: "Actually, also change Y", type: :issue }
    ]

    result = @handler.find_unaddressed_comments("user/repo", 10, "test-bot[bot]")
    assert_equal 1, result.size
    assert_equal "Actually, also change Y", result[0][:body]
  end

  def test_bot_comments_are_never_unaddressed
    @vcs.review_comments = [
      { id: 1, author: "test-bot[bot]", body: "I did this", in_reply_to_id: nil, type: :review }
    ]
    @vcs.issue_comments = [
      { id: 10, author: "test-bot[bot]", body: "Status update", type: :issue }
    ]

    result = @handler.find_unaddressed_comments("user/repo", 10, "test-bot[bot]")
    assert_empty result
  end

  def test_review_comment_with_claude_mention_is_ignored
    @vcs.review_comments = [
      { id: 1, author: "human", body: "Fix this", in_reply_to_id: nil, type: :review },
      { id: 2, author: "human", body: "@claude ignore this one", in_reply_to_id: nil, type: :review }
    ]

    result = @handler.find_unaddressed_comments("user/repo", 10, "test-bot[bot]")
    assert_equal 1, result.size
    assert_equal "Fix this", result[0][:body]
  end

  def test_issue_comment_with_claude_mention_is_ignored
    @vcs.issue_comments = [
      { id: 10, author: "human", body: "Please change X", type: :issue },
      { id: 11, author: "human", body: "Hey @claude do this instead", type: :issue }
    ]

    result = @handler.find_unaddressed_comments("user/repo", 10, "test-bot[bot]")
    assert_equal 1, result.size
    assert_equal "Please change X", result[0][:body]
  end

  def test_mixed_review_and_issue_comments
    @vcs.review_comments = [
      { id: 1, author: "human", body: "Inline fix needed", in_reply_to_id: nil, type: :review },
      { id: 2, author: "human", body: "Another inline", in_reply_to_id: nil, type: :review },
      { id: 3, author: "test-bot[bot]", body: "Fixed", in_reply_to_id: 2, type: :review }
    ]
    @vcs.issue_comments = [
      { id: 10, author: "human", body: "General feedback", type: :issue }
    ]

    result = @handler.find_unaddressed_comments("user/repo", 10, "test-bot[bot]")
    assert_equal 2, result.size
    assert_equal ["Inline fix needed", "General feedback"], result.map { |c| c[:body] }
  end

  # Regression (issue #7 / PR #12): on repos where the App token is read-only,
  # workers strip GH_TOKEN and reply as the OWNER account (here "testuser"), not
  # the bot. A worker stamps its reply with the factory marker, so an owner-
  # authored *stamped* reply must count as addressing the comment, or the
  # orchestrator re-dispatches it every tick (infinite loop + duplicate workers).
  def test_review_comment_addressed_by_marked_owner_reply
    @vcs.review_comments = [
      { id: 1, author: "chatgpt-codex-connector[bot]", body: "Preserve the unabridged SERP response", in_reply_to_id: nil, type: :review },
      { id: 2, author: "testuser", body: marked("Done — re-pulled the full response."), in_reply_to_id: 1, type: :review }
    ]

    result = @handler.find_unaddressed_comments("user/repo", 10, "test-bot[bot]")
    assert_empty result
  end

  def test_issue_comment_addressed_by_later_marked_owner_comment
    @vcs.issue_comments = [
      { id: 10, author: "human", body: "Please change X", type: :issue },
      { id: 11, author: "testuser", body: marked("Done, changed X"), type: :issue }
    ]

    result = @handler.find_unaddressed_comments("user/repo", 10, "test-bot[bot]")
    assert_empty result
  end

  # The owner is ALSO the human reviewer (Dispatcher requests it via
  # `--reviewer`), so an UNMARKED top-level owner comment is genuine feedback —
  # e.g. "please also update X" posted as a general PR comment — and must be
  # picked up, not silently dropped as factory-side.
  def test_unmarked_owner_issue_comment_is_unaddressed
    @vcs.issue_comments = [
      { id: 10, author: "testuser", body: "Please also update the changelog", type: :issue }
    ]

    result = @handler.find_unaddressed_comments("user/repo", 10, "test-bot[bot]")
    assert_equal 1, result.size
    assert_equal "Please also update the changelog", result[0][:body]
  end

  # A worker's own reply (posted as the owner, carrying the marker) must not
  # re-trigger as a fresh candidate.
  def test_marked_owner_issue_comment_is_not_unaddressed
    @vcs.issue_comments = [
      { id: 10, author: "testuser", body: marked("Status update from the worker"), type: :issue }
    ]

    result = @handler.find_unaddressed_comments("user/repo", 10, "test-bot[bot]")
    assert_empty result
  end

  # A later UNMARKED owner comment (the reviewer asking for more) must NOT mark
  # earlier feedback as addressed — only a marked factory reply does.
  def test_later_unmarked_owner_comment_does_not_address_feedback
    @vcs.issue_comments = [
      { id: 10, author: "chatgpt-codex-connector[bot]", body: "Consider edge case Y", type: :issue },
      { id: 11, author: "testuser", body: "Agreed, and please also do Z", type: :issue }
    ]

    result = @handler.find_unaddressed_comments("user/repo", 10, "test-bot[bot]")
    assert_equal ["Consider edge case Y", "Agreed, and please also do Z"], result.map { |c| c[:body] }
  end

  # Owner *inline* review comments are genuine human feedback (distinguishable
  # from worker replies by in_reply_to_id), so a top-level owner review comment
  # must still be picked up.
  def test_owner_top_level_review_comment_is_unaddressed
    @vcs.review_comments = [
      { id: 1, author: "testuser", body: "Inline nit to fix", in_reply_to_id: nil, type: :review }
    ]

    result = @handler.find_unaddressed_comments("user/repo", 10, "test-bot[bot]")
    assert_equal 1, result.size
    assert_equal "Inline nit to fix", result[0][:body]
  end

  def test_cloudflare_bot_comments_are_ignored
    @vcs.review_comments = [
      { id: 1, author: "cloudflare-workers-and-pages", body: "Deployment successful!", in_reply_to_id: nil, type: :review }
    ]
    @vcs.issue_comments = [
      { id: 10, author: "cloudflare-workers-and-pages", body: "Preview URL ready", type: :issue }
    ]

    result = @handler.find_unaddressed_comments("user/repo", 10, "test-bot[bot]")
    assert_empty result
  end

  # Regression: when the local repo checkout is missing, the orchestrator used
  # to only log "repo directory not found" and silently re-detect the same
  # comment every tick. It must now surface the failure to the update channel.
  def test_missing_checkout_surfaces_error_notification
    channel = RecordingUpdateChannel.new
    ctx = build_context(@tmpdir, update_channel: channel)
    repo = "user/definitely-not-a-real-checkout"
    ctx.issue_tracker.items = [
      { number: 7, status: "In review", type: "ISSUE", repo: repo }
    ]
    ctx.vcs.prs[[repo, 7]] = { number: 42, branch: "feature" }
    ctx.vcs.issue_comments = [
      { id: 10, author: "human", body: "do x", type: :issue }
    ]
    handler = Orchestrator::PrCommentHandler.new(ctx)

    capture_io { handler.call(1) }

    assert_equal 1, channel.errors.size
    assert_match(/repo checkout not found/, channel.errors[0][:message])
    assert_equal repo, channel.errors[0][:fields]["Repo"]
  end
end
