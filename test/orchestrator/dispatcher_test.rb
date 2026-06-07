require_relative "test_helper"

class DispatcherTest < Minitest::Test
  include OrchestratorTestHelper

  def setup
    @tmpdir = Dir.mktmpdir("dispatcher-test")
    @ctx = build_context(@tmpdir)
    @dispatcher = Orchestrator::Dispatcher.new(@ctx)
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def call_build_prompt(**overrides)
    args = {
      issue_number: 42,
      repo: "user/repo",
      worktree_dir: "/tmp/worktree-42",
      branch: "42-test",
      attachments: ""
    }.merge(overrides)
    @dispatcher.build_prompt(args[:issue_number], args[:repo], args[:worktree_dir],
                             args[:branch], args[:attachments],
                             planning_approved: args.fetch(:planning_approved, false))
  end

  def test_build_prompt_shared_scaffolding_present_in_both_modes
    [false, true].each do |planning_approved|
      prompt = call_build_prompt(planning_approved: planning_approved)
      assert_includes prompt, "repo user/repo", "missing repo header (planning_approved=#{planning_approved})"
      assert_includes prompt, "testuser", "missing owner (planning_approved=#{planning_approved})"
      assert_includes prompt, "gh issue comment 42 -R user/repo", "missing progress-comment instruction"
      assert_includes prompt, "$SLACK_WEBHOOK", "missing slack webhook env reference"
      refute_includes prompt, "https://hooks.slack.com/test", "webhook secret must not be inlined in the prompt"
      assert_includes prompt, "git worktree add /tmp/worktree-42 -b 42-test origin/main", "missing worktree creation"
      assert_includes prompt, "bundle exec rubocop -a", "missing rubocop"
      assert_includes prompt, "gh pr create -R user/repo", "missing PR creation"
      assert_includes prompt, "--reviewer testuser", "missing reviewer assignment"
      assert_includes prompt, "git worktree remove /tmp/worktree-42", "missing worktree cleanup"
    end
  end

  def test_build_prompt_fresh_issue_has_plan_or_implement_branch
    prompt = call_build_prompt(planning_approved: false)
    assert_includes prompt, "plan first"
    assert_includes prompt, "needs review"
    assert_includes prompt, "STOP"
  end

  def test_build_prompt_fresh_issue_does_not_mention_approved_plan
    prompt = call_build_prompt(planning_approved: false)
    refute_includes prompt, "approved"
    refute_match(/--remove-label .needs review./, prompt)
  end

  def test_build_prompt_planning_approved_treats_comments_as_truth
    prompt = call_build_prompt(planning_approved: true)
    assert_includes prompt, "approved"
    assert_includes prompt, "PRIMARY source of truth"
    assert_includes prompt, "--comments"
    assert_includes prompt, "--remove-label \"needs review\""
  end

  def test_build_prompt_planning_approved_skips_plan_decision_branch
    prompt = call_build_prompt(planning_approved: true)
    refute_includes prompt, "plan first"
    refute_includes prompt, "STOP"
  end

  def test_build_prompt_injects_attachments_in_both_modes
    [false, true].each do |planning_approved|
      prompt = call_build_prompt(attachments: "ATTACHMENTS_MARKER", planning_approved: planning_approved)
      assert_includes prompt, "ATTACHMENTS_MARKER", "attachments missing (planning_approved=#{planning_approved})"
    end
  end

  # --- fetch_attachments ---

  def fetch_attachments(repo, issue_number)
    @dispatcher.send(:fetch_attachments, repo, issue_number, @tmpdir)
  end

  def attach_path(issue_number, filename)
    File.join(@tmpdir, ".issue-attachments", issue_number.to_s, filename)
  end

  def test_fetch_attachments_downloads_image_assets_url_with_derived_extension
    url = "https://github.com/user-attachments/assets/abc-123"
    @ctx.issue_tracker.issue_bodies[7] = "Here is a screenshot: #{url}"
    png_bytes = "\x89PNG\r\n\x1a\n\x00binary".b
    @ctx.vcs.authenticated_responses[url] = [png_bytes, "image/png"]

    msg = fetch_attachments("user/repo", 7)

    written = attach_path(7, "abc-123.png")
    assert File.exist?(written), "expected image written with .png extension"
    assert_equal png_bytes, File.binread(written), "image bytes should be written binary-safe"
    assert_includes msg, "abc-123.png"
    assert_includes msg, ".issue-attachments/7/"
  end

  def test_fetch_attachments_keeps_filename_for_files_url
    url = "https://github.com/user-attachments/files/55/spec.pdf"
    @ctx.issue_tracker.issue_bodies[8] = "See #{url}"
    @ctx.vcs.authenticated_responses[url] = ["PDF-DATA", "application/pdf"]

    msg = fetch_attachments("user/repo", 8)

    assert File.exist?(attach_path(8, "spec.pdf")), "files URL should keep its filename"
    assert_includes msg, "spec.pdf"
  end

  def test_fetch_attachments_skips_non_image_assets_url
    url = "https://github.com/user-attachments/assets/vid-999"
    @ctx.issue_tracker.issue_bodies[9] = "A video: #{url}"
    @ctx.vcs.authenticated_responses[url] = ["VIDEO".b, "video/mp4"]

    msg = fetch_attachments("user/repo", 9)

    refute File.exist?(attach_path(9, "vid-999.mp4")), "non-image asset should not be written"
    assert_equal "", msg, "no downloadable attachments → empty message"
  end

  def test_fetch_attachments_handles_content_type_with_charset
    url = "https://github.com/user-attachments/assets/dia-1"
    @ctx.issue_tracker.issue_bodies[10] = url
    @ctx.vcs.authenticated_responses[url] = ["GIF".b, "image/gif; charset=binary"]

    fetch_attachments("user/repo", 10)

    assert File.exist?(attach_path(10, "dia-1.gif")), "content-type with parameters should still map"
  end
end
