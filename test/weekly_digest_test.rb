require "minitest/autorun"
require "tmpdir"
require "fileutils"

require_relative "../lib/routines/weekly_digest"
require_relative "routine_test_helper"

class WeeklyDigestTest < Minitest::Test
  # Regression for the v1.9.0 routine-move path bug — see security_scan_test.
  def test_config_path_resolves_to_repo_root_config_yml
    src = File.read(File.expand_path("../../lib/routines/weekly_digest.rb", __FILE__))
    src.match(%r{File\.expand_path\("([^"]+)", __FILE__\)}) or
      flunk "could not locate config-load expand_path call"
    expanded = File.expand_path(Regexp.last_match(1),
                                File.expand_path("../../lib/routines/weekly_digest.rb", __FILE__))
    expected = File.expand_path("../../config.yml", __FILE__)
    assert_equal expected, expanded,
                 "weekly_digest config path must resolve to repo-root config.yml"
  end

  def setup
    @tmpdir = Dir.mktmpdir("weekly-digest-test")
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def build_digest
    wd = WeeklyDigest.allocate
    wd.instance_variable_set(:@config, {
      "owner" => "acme",
      "slack_webhook" => "https://hooks.slack.com/test",
      "factory_username" => "test-bot[bot]",
      "github_app" => {
        "app_id" => 12345,
        "installation_id" => 67890,
        "bot_user_id" => 99999,
        "private_key_path" => "/dev/null"
      },
      "routines" => {
        "weekly_digest" => { "repo" => "acme/widget" }
      }
    })
    wd.instance_variable_set(:@env, StubRoutineEnv.new)
    wd.instance_variable_set(:@repo, "acme/widget")
    wd
  end

  # --- extract_issue_number ---

  def test_extract_issue_number_standard_branch
    wd = build_digest
    assert_equal 389, wd.send(:extract_issue_number, "389-verbatim-golden-answer-mode")
  end

  def test_extract_issue_number_short_branch
    wd = build_digest
    assert_equal 42, wd.send(:extract_issue_number, "42-fix")
  end

  def test_extract_issue_number_no_match
    wd = build_digest
    assert_nil wd.send(:extract_issue_number, "feature-branch")
  end

  def test_extract_issue_number_nil
    wd = build_digest
    assert_nil wd.send(:extract_issue_number, nil)
  end

  # --- format_pr_section ---

  def test_format_pr_section_complete
    wd = build_digest
    pr = {
      number: 100,
      title: "Add search feature",
      branch: "50-add-search",
      merged_at: "2026-03-10T12:00:00Z",
      body: "Implements full-text search",
      issue_number: 50,
      issue_title: "Add search to the app",
      issue_body: "Users need to search their documents",
      issue_comments: [
        {"author" => "acme", "body" => "Approved plan"}
      ]
    }
    result = wd.send(:format_pr_section, pr)
    assert_includes result, "PR #100: Add search feature"
    assert_includes result, "Implements full-text search"
    assert_includes result, "Issue #50: Add search to the app"
    assert_includes result, "Users need to search their documents"
    assert_includes result, "[acme]: Approved plan"
  end

  def test_format_pr_section_no_issue
    wd = build_digest
    pr = {
      number: 100,
      title: "Bump dependencies",
      branch: "deps-update",
      merged_at: "2026-03-10T12:00:00Z",
      body: "Update gems",
      issue_number: nil,
      issue_title: nil,
      issue_body: nil,
      issue_comments: []
    }
    result = wd.send(:format_pr_section, pr)
    assert_includes result, "PR #100: Bump dependencies"
    refute_includes result, "Linked Issue"
  end

  # --- build_prompt ---

  def test_build_prompt_includes_all_prs
    wd = build_digest
    prs = [
      {number: 1, title: "Feature A", branch: "1-a", merged_at: "2026-03-10T12:00:00Z",
       body: "desc A", issue_number: 1, issue_title: "A", issue_body: "brief A", issue_comments: []},
      {number: 2, title: "Feature B", branch: "2-b", merged_at: "2026-03-11T12:00:00Z",
       body: "desc B", issue_number: 2, issue_title: "B", issue_body: "brief B", issue_comments: []}
    ]
    prompt = wd.send(:build_prompt, prs)
    assert_includes prompt, "Feature A"
    assert_includes prompt, "Feature B"
    assert_includes prompt, "brief A"
    assert_includes prompt, "brief B"
  end

  def test_build_prompt_with_issue_comments
    wd = build_digest
    prs = [
      {number: 1, title: "Feature A", branch: "1-a", merged_at: "2026-03-10T12:00:00Z",
       body: "desc", issue_number: 1, issue_title: "A", issue_body: "brief",
       issue_comments: [{"author" => "reviewer", "body" => "The plan looks good"}]}
    ]
    prompt = wd.send(:build_prompt, prs)
    assert_includes prompt, "[reviewer]: The plan looks good"
  end

  def test_build_prompt_without_linked_issue
    wd = build_digest
    prs = [
      {number: 1, title: "Hotfix", branch: "hotfix-typo", merged_at: "2026-03-10T12:00:00Z",
       body: "Fix typo", issue_number: nil, issue_title: nil, issue_body: nil, issue_comments: []}
    ]
    prompt = wd.send(:build_prompt, prs)
    assert_includes prompt, "Hotfix"
    assert_includes prompt, "Fix typo"
  end

  # --- run (integration) ---

  def test_run_skips_when_no_merged_prs
    wd = build_digest
    wd.define_singleton_method(:fetch_merged_prs) { [] }

    claude_called = false
    wd.define_singleton_method(:run_claude) { |_| claude_called = true; "" }

    slack_called = false
    wd.instance_variable_get(:@env).update_channel.define_singleton_method(:weekly_digest) do |_, _|
      slack_called = true
    end

    wd.run
    refute claude_called
    refute slack_called
  end

  def test_run_full_flow
    wd = build_digest

    wd.define_singleton_method(:fetch_merged_prs) do
      [{number: 1, title: "Feature", branch: "1-feat", merged_at: "2026-03-10T12:00:00Z",
        body: "desc", issue_number: 1}]
    end
    wd.define_singleton_method(:enrich_pr) do |pr|
      pr.merge(issue_title: "Issue", issue_body: "brief", issue_comments: [])
    end
    wd.define_singleton_method(:run_claude) { |_| "Weekly update content" }
    wd.define_singleton_method(:save_digest) { |_| }

    slack_calls = []
    wd.instance_variable_get(:@env).update_channel.define_singleton_method(:weekly_digest) do |content, count|
      slack_calls << {content: content, count: count}
    end

    wd.run
    assert_equal 1, slack_calls.size
    assert_equal "Weekly update content", slack_calls[0][:content]
    assert_equal 1, slack_calls[0][:count]
  end
end

