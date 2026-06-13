require "minitest/autorun"
require_relative "../../lib/adapters/claude_code/coding_agent"
require_relative "contracts/coding_agent_contract"

class ClaudeCodeCodingAgentTest < Minitest::Test
  include CodingAgentContract

  def build_adapter
    Adapters::ClaudeCode::CodingAgent.new({})
  end

  def test_command_includes_bypass_permissions
    argv = build_adapter.command(prompt_path: "/tmp/p")
    assert_includes argv, "--permission-mode"
    assert_includes argv, "bypassPermissions"
    assert_includes argv, "-p"
  end

  def test_command_includes_remote_control_by_default
    argv = build_adapter.command(prompt_path: "/tmp/p")
    assert_includes argv, "--remote-control"
  end

  def test_remote_control_can_be_disabled
    adapter = Adapters::ClaudeCode::CodingAgent.new("coding_agent" => { "remote_control" => false })
    argv = adapter.command(prompt_path: "/tmp/p")
    refute_includes argv, "--remote-control"
  end

  def test_remote_control_accepts_session_name
    adapter = Adapters::ClaudeCode::CodingAgent.new("coding_agent" => { "remote_control" => "worker-1" })
    argv = adapter.command(prompt_path: "/tmp/p")
    idx = argv.index("--remote-control")
    refute_nil idx
    assert_equal "worker-1", argv[idx + 1]
  end

  def test_command_omits_model_by_default
    refute_includes build_adapter.command(prompt_path: "/tmp/p"), "--model"
  end

  def test_command_includes_configured_model
    adapter = Adapters::ClaudeCode::CodingAgent.new("coding_agent" => { "model" => "claude-opus-4-8" })
    argv = adapter.command(prompt_path: "/tmp/p")
    idx = argv.index("--model")
    refute_nil idx, "expected --model in argv"
    assert_equal "claude-opus-4-8", argv[idx + 1]
  end

  def test_blank_model_is_treated_as_unset
    adapter = Adapters::ClaudeCode::CodingAgent.new("coding_agent" => { "model" => "  " })
    refute_includes adapter.command(prompt_path: "/tmp/p"), "--model"
  end

  def test_env_overrides_clears_claude_code_session
    overrides = build_adapter.env_overrides
    assert_nil overrides["CLAUDECODE"]
    assert_nil overrides["CLAUDE_CODE_ENTRYPOINT"]
    assert_nil overrides["CLAUDE_CODE_SESSION_ACCESS_TOKEN"]
  end

  def test_stdin_mode_is_prompt_file
    assert_equal :prompt_file, build_adapter.stdin_mode
  end
end
