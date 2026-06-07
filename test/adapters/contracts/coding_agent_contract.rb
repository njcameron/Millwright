module CodingAgentContract
  VALID_STDIN_MODES = %i[prompt_file inline_arg stdin_data].freeze

  def test_contract_responds_to_required_methods
    adapter = build_adapter
    %i[command env_overrides stdin_mode].each do |m|
      assert_respond_to adapter, m
    end
  end

  def test_contract_command_returns_non_empty_argv
    argv = build_adapter.command(prompt_path: "/tmp/p")
    assert_kind_of Array, argv
    refute_empty argv
    argv.each { |a| assert_kind_of String, a }
  end

  def test_contract_env_overrides_returns_hash
    assert_kind_of Hash, build_adapter.env_overrides
  end

  def test_contract_stdin_mode_is_known_symbol
    assert_includes VALID_STDIN_MODES, build_adapter.stdin_mode
  end
end
