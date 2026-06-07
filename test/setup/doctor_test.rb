require "minitest/autorun"
require "tmpdir"
require "openssl"
require_relative "../../lib/setup/doctor"

class DoctorTest < Minitest::Test
  GOOD_STATUSES = {
    "ready" => "Ready",
    "planning" => "cc-planning",
    "planning_approved" => "Planning approved",
    "building" => "In progress",
    "pr" => "In review",
    "done" => "Done"
  }.freeze

  def good_config(overrides = {})
    {
      "owner" => "octocat",
      "project_number" => 7,
      "project_id" => "PVT_abc123",
      "factory_username" => "millwright-bot[bot]",
      "github_app" => {
        "app_id" => 123, "installation_id" => 456, "bot_user_id" => 789,
        "private_key_path" => "private-key.pem"
      },
      "slack_webhook" => "https://hooks.slack.test/xyz",
      "statuses" => GOOD_STATUSES.dup
    }.merge(overrides)
  end

  def build(config:, repo_root: Dir.pwd, config_error: nil, skip_slack: false)
    Setup::Doctor.new(repo_root: repo_root, config: config, config_error: config_error, skip_slack: skip_slack)
  end

  def find(results, check)
    results.find { |r| r.check == check }
  end

  # ---- config_file ----

  def test_missing_config_fails
    r = build(config: nil).check_config_file
    assert_equal :fail, r.status
    assert_includes r.detail, "not found"
  end

  def test_invalid_yaml_fails
    r = build(config: nil, config_error: "bad indent at line 3").check_config_file
    assert_equal :fail, r.status
    assert_includes r.detail, "not valid YAML"
    assert_includes r.hint, "bad indent"
  end

  def test_config_dependent_checks_skip_without_config
    doctor = build(config: nil)
    %i[required_keys private_key github_app_token board_statuses].each do |check|
      r = doctor.send("check_#{check}")
      assert_equal :skip, r.status, "#{check} should skip without config"
    end
  end

  # ---- required_keys ----

  def test_required_keys_all_present
    r = build(config: good_config).check_required_keys
    assert_equal :pass, r.status
  end

  def test_required_keys_reports_missing
    config = good_config
    config.delete("owner")
    config["statuses"].delete("done")
    r = build(config: config).check_required_keys
    assert_equal :fail, r.status
    assert_includes r.detail, "owner (missing)"
    assert_includes r.detail, "statuses.done (missing)"
  end

  def test_required_keys_detects_placeholders
    config = good_config(
      "owner" => "<your-github-username>",
      "project_id" => "<your-project-node-id>"
    )
    config["github_app"]["app_id"] = 0
    r = build(config: config).check_required_keys
    assert_equal :fail, r.status
    assert_includes r.detail, "owner (placeholder)"
    assert_includes r.detail, "project_id (placeholder)"
    assert_includes r.detail, "github_app.app_id (placeholder)"
  end

  # ---- ruby_version ----

  def test_ruby_version_passes_on_current
    # The test suite itself requires Ruby 3.2+, so this always passes here.
    assert_equal :pass, build(config: good_config).check_ruby_version.status
  end

  # ---- board_statuses (probe stubbed) ----

  def test_board_statuses_pass_when_all_present
    doctor = build(config: good_config)
    doctor.define_singleton_method(:fetch_board_options) do
      { names: GOOD_STATUSES.values, owner_type: "user" }
    end
    r = doctor.check_board_statuses
    assert_equal :pass, r.status
    assert_includes r.detail, "user-owned"
  end

  def test_board_statuses_fail_lists_missing_columns
    doctor = build(config: good_config)
    doctor.define_singleton_method(:fetch_board_options) do
      { names: GOOD_STATUSES.values - ["Done"], owner_type: "organization" }
    end
    r = doctor.check_board_statuses
    assert_equal :fail, r.status
    assert_includes r.detail, "Done"
  end

  def test_board_statuses_fail_when_unreachable
    doctor = build(config: good_config)
    doctor.define_singleton_method(:fetch_board_options) { nil }
    r = doctor.check_board_statuses
    assert_equal :fail, r.status
    assert_includes r.hint, "org-owned"
  end

  # ---- github_app_token (probe stubbed) ----

  def test_app_token_maps_404_to_installation_hint
    doctor = build(config: good_config)
    doctor.define_singleton_method(:private_key_usable?) { true }
    doctor.define_singleton_method(:generate_app_token) { raise "Failed to generate installation token: 404 not found" }
    r = doctor.check_github_app_token
    assert_equal :fail, r.status
    assert_includes r.hint, "installation_id"
  end

  # ---- slack_webhook ----

  def test_slack_skipped_with_no_slack_flag
    r = build(config: good_config, skip_slack: true).check_slack_webhook
    assert_equal :skip, r.status
  end

  def test_slack_skipped_when_unconfigured
    config = good_config
    config.delete("slack_webhook")
    r = build(config: config).check_slack_webhook
    assert_equal :skip, r.status
  end

  def test_slack_pass_on_2xx
    doctor = build(config: good_config)
    doctor.define_singleton_method(:slack_test_response) { Struct.new(:code).new(200) }
    r = doctor.check_slack_webhook
    assert_equal :pass, r.status
  end

  def test_slack_fail_on_non_2xx
    doctor = build(config: good_config)
    doctor.define_singleton_method(:slack_test_response) { Struct.new(:code).new(404) }
    r = doctor.check_slack_webhook
    assert_equal :fail, r.status
    assert_includes r.detail, "404"
  end

  # ---- private_key (real RSA in a temp repo) ----

  def test_private_key_valid_passes
    Dir.mktmpdir do |dir|
      key_path = File.join(dir, "private-key.pem")
      File.write(key_path, OpenSSL::PKey::RSA.new(2048).to_pem)
      config = good_config
      config["github_app"]["private_key_path"] = key_path # absolute
      r = build(config: config, repo_root: dir).check_private_key
      assert_equal :pass, r.status
    end
  end

  def test_private_key_missing_fails
    Dir.mktmpdir do |dir|
      r = build(config: good_config, repo_root: dir).check_private_key
      assert_equal :fail, r.status
      assert_includes r.detail, "not found"
    end
  end

  # ---- reporting / exit code ----

  def test_success_requires_no_failures
    doctor = build(config: good_config)
    pass = Setup::Doctor::Result.new(check: :a, status: :pass, detail: "ok")
    warn = Setup::Doctor::Result.new(check: :b, status: :warn, detail: "meh")
    skip = Setup::Doctor::Result.new(check: :c, status: :skip, detail: "n/a")
    fail = Setup::Doctor::Result.new(check: :d, status: :fail, detail: "boom")
    assert doctor.success?([pass, warn, skip])
    refute doctor.success?([pass, fail])
  end

  def test_format_report_includes_symbols_and_summary
    doctor = build(config: good_config)
    results = [
      Setup::Doctor::Result.new(check: :ruby_version, status: :pass, detail: "ok"),
      Setup::Doctor::Result.new(check: :bundler, status: :fail, detail: "missing", hint: "bundle install")
    ]
    report = doctor.format_report(results)
    assert_includes report, "✓ ruby_version"
    assert_includes report, "✗ bundler"
    assert_includes report, "bundle install"
    assert_includes report, "1 passed, 1 failed"
    assert_includes report, "Some checks failed"
  end

  def test_format_json_shape
    doctor = build(config: good_config)
    results = [Setup::Doctor::Result.new(check: :ruby_version, status: :pass, detail: "ok", hint: nil)]
    parsed = JSON.parse(doctor.format_json(results))
    assert_equal 1, parsed.size
    assert_equal "ruby_version", parsed[0]["check"]
    assert_equal "pass", parsed[0]["status"]
    assert parsed[0].key?("detail")
    assert parsed[0].key?("hint")
  end

  # ---- secret redaction ----

  def test_scrub_redacts_webhook_token_and_key
    doctor = build(config: good_config)
    token = "ghs_#{"a" * 36}"
    pem = "-----BEGIN RSA PRIVATE KEY-----\nABCDEF\n-----END RSA PRIVATE KEY-----"
    text = "leaked https://hooks.slack.test/xyz and #{token} and #{pem}"
    scrubbed = doctor.scrub(text)
    refute_includes scrubbed, "hooks.slack.test/xyz"
    refute_includes scrubbed, token
    refute_includes scrubbed, "ABCDEF"
    assert_includes scrubbed, "[redacted-webhook]"
    assert_includes scrubbed, "[redacted-token]"
    assert_includes scrubbed, "[redacted-key]"
  end

  def test_format_json_scrubs_secrets
    doctor = build(config: good_config)
    results = [Setup::Doctor::Result.new(check: :slack_webhook, status: :fail,
                                         detail: "failed posting to https://hooks.slack.test/xyz", hint: nil)]
    json = doctor.format_json(results)
    refute_includes json, "hooks.slack.test/xyz"
    assert_includes json, "[redacted-webhook]"
  end
end
