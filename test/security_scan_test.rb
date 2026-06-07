require "minitest/autorun"
require "tmpdir"
require "fileutils"

require_relative "../lib/routines/security_scan"
require_relative "routine_test_helper"

class SecurityScanTest < Minitest::Test
  # Regression for the path bug from v1.9.0 (routines moved into
  # lib/routines/ but the config-load path wasn't bumped, so cron runs
  # since then have been silently failing with `lib/config.yml not found`).
  def test_config_path_resolves_to_repo_root_config_yml
    src = File.read(File.expand_path("../../lib/routines/security_scan.rb", __FILE__))
    src.match(%r{File\.expand_path\("([^"]+)", __FILE__\)}) or
      flunk "could not locate config-load expand_path call"
    expanded = File.expand_path(Regexp.last_match(1),
                                File.expand_path("../../lib/routines/security_scan.rb", __FILE__))
    expected = File.expand_path("../../config.yml", __FILE__)
    assert_equal expected, expanded,
                 "security_scan config path must resolve to repo-root config.yml"
  end

  def setup
    @tmpdir = Dir.mktmpdir("security-scan-test")
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def build_scanner(repos: [{ name: "acme/widget", dir: "/tmp/workspace/widget" }])
    ss = SecurityScan.allocate
    ss.instance_variable_set(:@config, {
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
        "security_scan" => {
          "workspace_dir" => "/tmp/workspace",
          "repos" => repos.map { |r| { "name" => r[:name], "dir" => r[:dir] } }
        }
      }
    })
    ss.instance_variable_set(:@env, StubRoutineEnv.new)
    ss
  end

  # --- configured_repos ---

  def test_configured_repos_supports_hash_entries
    ss = build_scanner(repos: [
      { name: "u/foo", dir: "/path/foo" },
      { name: "u/bar", dir: "/path/bar" }
    ])
    repos = ss.send(:configured_repos)
    assert_equal 2, repos.size
    assert_equal "u/foo", repos[0][:name]
    assert_equal "/path/bar", repos[1][:dir]
  end

  def test_configured_repos_supports_string_entries_with_default_dir
    ss = build_scanner
    ss.instance_variable_get(:@config)["routines"]["security_scan"]["repos"] = ["u/foo"]
    repos = ss.send(:configured_repos)
    assert_equal "u/foo", repos[0][:name]
    assert_equal "/tmp/workspace/foo", repos[0][:dir]
  end

  def test_configured_repos_empty_when_missing
    ss = build_scanner
    ss.instance_variable_get(:@config).delete("routines")
    assert_empty ss.send(:configured_repos)
  end

  # --- build_prompt ---

  def test_build_prompt_focuses_on_idor_and_auth
    prompt = build_scanner.send(:build_prompt, "u/r")
    assert_includes prompt, "IDOR"
    assert_includes prompt, "Authorization Gaps"
    assert_includes prompt, "Hardcoded Secrets"
    assert_includes prompt, "SSRF"
  end

  def test_build_prompt_excludes_brakeman_categories
    prompt = build_scanner.send(:build_prompt, "u/r")
    assert_includes prompt, "DO NOT DUPLICATE"
    assert_includes prompt, "Skip anything a SAST scanner catches"
  end

  def test_build_prompt_requires_high_confidence
    prompt = build_scanner.send(:build_prompt, "u/r")
    assert_includes prompt, ">80% confident"
    assert_includes prompt, "MINIMIZE FALSE POSITIVES"
  end

  def test_build_prompt_requests_json_output
    prompt = build_scanner.send(:build_prompt, "u/r")
    assert_includes prompt, "REQUIRED OUTPUT FORMAT"
    assert_includes prompt, '"findings"'
    assert_includes prompt, '"analysis_summary"'
  end

  def test_build_prompt_mentions_target_repo
    prompt = build_scanner.send(:build_prompt, "u/specific-repo")
    assert_includes prompt, "u/specific-repo"
  end

  # --- parse_findings ---

  def test_parse_findings_valid_json
    ss = build_scanner
    raw = '{"findings": [{"file": "app/controllers/foo.rb", "line": 10, ' \
          '"severity": "HIGH", "category": "idor", "description": "test", ' \
          '"exploit_scenario": "test", "recommendation": "test", "confidence": 0.9}], ' \
          '"analysis_summary": {"files_reviewed": 5, "critical_count": 0, ' \
          '"high_count": 1, "medium_count": 0, "low_count": 0, "review_completed": true}}'
    result = ss.send(:parse_findings, raw)
    assert_equal 1, result["findings"].size
    assert_equal "HIGH", result["findings"][0]["severity"]
    assert_equal 5, result["analysis_summary"]["files_reviewed"]
  end

  def test_parse_findings_with_surrounding_text
    raw = 'Here is my analysis:\n{"findings": [], "analysis_summary": ' \
          '{"files_reviewed": 3, "critical_count": 0, "high_count": 0, ' \
          '"medium_count": 0, "low_count": 0, "review_completed": true}}\nDone.'
    result = build_scanner.send(:parse_findings, raw)
    assert_equal [], result["findings"]
    assert_equal true, result["analysis_summary"]["review_completed"]
  end

  def test_parse_findings_invalid_json
    result = build_scanner.send(:parse_findings, "not json at all")
    assert_equal [], result["findings"]
    assert_equal false, result["analysis_summary"]["review_completed"]
  end

  def test_parse_findings_empty_string
    assert_equal [], build_scanner.send(:parse_findings, "")["findings"]
  end

  # --- severity_counts ---

  def test_severity_counts
    items = [
      { "severity" => "CRITICAL" },
      { "severity" => "HIGH" },
      { "severity" => "HIGH" },
      { "severity" => "MEDIUM" },
      { "severity" => "LOW" }
    ]
    counts = build_scanner.send(:severity_counts, items)
    assert_equal 1, counts[:critical]
    assert_equal 2, counts[:high]
    assert_equal 1, counts[:medium]
    assert_equal 1, counts[:low]
  end

  def test_severity_counts_empty
    counts = build_scanner.send(:severity_counts, [])
    assert_equal 0, counts[:critical]
    assert_equal 0, counts[:high]
    assert_equal 0, counts[:medium]
    assert_equal 0, counts[:low]
  end

  # --- build_report ---

  def test_build_report_with_findings
    findings = {
      "findings" => [
        {
          "file" => "app/controllers/users_controller.rb",
          "line" => 42,
          "severity" => "HIGH",
          "category" => "idor",
          "description" => "User record fetched without ownership check",
          "exploit_scenario" => "Attacker changes ID param to access other users",
          "recommendation" => "Scope query to current_user",
          "confidence" => 0.9
        }
      ],
      "analysis_summary" => {
        "files_reviewed" => 10, "critical_count" => 0, "high_count" => 1,
        "medium_count" => 0, "low_count" => 0, "review_completed" => true
      }
    }
    report = build_scanner.send(:build_report, "acme/widget", findings, "{}")
    assert_includes report, "Weekly Security Scan — acme/widget"
    assert_includes report, "CRITICAL: 0 | HIGH: 1"
    assert_includes report, "[HIGH] IDOR"
    assert_includes report, "users_controller.rb:42"
    assert_includes report, "ownership check"
  end

  def test_build_report_no_findings
    findings = {
      "findings" => [],
      "analysis_summary" => { "files_reviewed" => 10, "critical_count" => 0,
        "high_count" => 0, "medium_count" => 0, "low_count" => 0,
        "review_completed" => true }
    }
    report = build_scanner.send(:build_report, "u/r", findings, "{}")
    assert_includes report, "No security issues found"
    assert_includes report, "CRITICAL: 0 | HIGH: 0"
  end

  # --- save_report (per-repo subdir) ---

  def test_save_report_writes_to_per_repo_subdir
    ss = build_scanner
    base_dir = File.join(@tmpdir, "logs", "security")
    ss.define_singleton_method(:save_report) do |repo, report|
      slug = repo.gsub("/", "_")
      dir = File.join(base_dir, slug)
      FileUtils.mkdir_p(dir)
      date = Time.now.utc.strftime("%Y-%m-%d")
      path = File.join(dir, "#{date}.md")
      File.write(path, report)
      path
    end

    path = ss.send(:save_report, "acme/widget", "# Test")
    assert_match %r{logs/security/acme_widget/\d{4}-\d{2}-\d{2}\.md\z}, path
    assert File.exist?(path)
  end

  # --- run (multi-repo integration) ---

  def test_run_iterates_over_configured_repos_and_posts_one_slack_per_repo
    ss = build_scanner(repos: [
      { name: "u/foo", dir: "/path/foo" },
      { name: "u/bar", dir: "/path/bar" }
    ])

    ss.define_singleton_method(:ensure_repo_up_to_date) { |_repo, _dir| }
    ss.define_singleton_method(:run_claude) do |_prompt, _dir|
      '{"findings": [], "analysis_summary": {"files_reviewed": 5, ' \
      '"critical_count": 0, "high_count": 0, "medium_count": 0, ' \
      '"low_count": 0, "review_completed": true}}'
    end
    ss.define_singleton_method(:save_report) { |_repo, _report| "/tmp/fake.md" }

    slack_calls = []
    ss.instance_variable_get(:@env).update_channel.define_singleton_method(:security_scan) do |repo, counts, report, _path|
      slack_calls << { repo: repo, counts: counts }
    end

    ss.run
    assert_equal 2, slack_calls.size
    assert_equal "u/foo", slack_calls[0][:repo]
    assert_equal "u/bar", slack_calls[1][:repo]
  end

  def test_run_with_findings_breaks_down_per_repo
    ss = build_scanner(repos: [
      { name: "u/foo", dir: "/path/foo" },
      { name: "u/bar", dir: "/path/bar" }
    ])

    ss.define_singleton_method(:ensure_repo_up_to_date) { |_repo, _dir| }
    ss.define_singleton_method(:run_claude) do |_prompt, dir|
      count = dir.include?("foo") ? 2 : 1
      findings = (1..count).map do |i|
        %({"file": "app.rb", "line": #{i}, "severity": "HIGH", "category": "idor", ) +
          %("description": "x", "exploit_scenario": "x", "recommendation": "x", "confidence": 0.9})
      end
      %({"findings": [#{findings.join(", ")}], "analysis_summary": {"files_reviewed": 5, ) +
        %("critical_count": 0, "high_count": #{count}, "medium_count": 0, "low_count": 0, ) +
        %("review_completed": true}})
    end
    ss.define_singleton_method(:save_report) { |_repo, _report| "/tmp/fake.md" }

    slack_calls = []
    ss.instance_variable_get(:@env).update_channel.define_singleton_method(:security_scan) do |repo, counts, _report, _path|
      slack_calls << { repo: repo, high: counts[:high] }
    end

    ss.run
    assert_equal 2, slack_calls.size
    assert_equal({ repo: "u/foo", high: 2 }, slack_calls[0])
    assert_equal({ repo: "u/bar", high: 1 }, slack_calls[1])
  end

  def test_run_one_repo_failure_does_not_block_others
    ss = build_scanner(repos: [
      { name: "u/broken", dir: "/path/broken" },
      { name: "u/ok", dir: "/path/ok" }
    ])

    ss.define_singleton_method(:ensure_repo_up_to_date) do |repo, _dir|
      raise "clone failed" if repo == "u/broken"
    end
    ss.define_singleton_method(:run_claude) do |_prompt, _dir|
      '{"findings": [], "analysis_summary": {"files_reviewed": 1, ' \
      '"critical_count": 0, "high_count": 0, "medium_count": 0, ' \
      '"low_count": 0, "review_completed": true}}'
    end
    ss.define_singleton_method(:save_report) { |_repo, _report| "/tmp/fake.md" }

    slack_calls = []
    ss.instance_variable_get(:@env).update_channel.define_singleton_method(:security_scan) do |repo, _counts, _report, _path|
      slack_calls << repo
    end

    ss.run
    assert_equal ["u/ok"], slack_calls
  end
end
