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
