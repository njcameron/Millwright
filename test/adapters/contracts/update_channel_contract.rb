module UpdateChannelContract
  EVENT_METHODS = %i[
    issue_picked_up plan_ready pr_created
    pr_comments_found plan_comments_found pr_comments_addressed
    worker_failed review_queue_full
    ci_fix_dispatched ci_fix_gave_up
    doctor_detected doctor_gave_up doctor_recovered
    weekly_digest security_scan no_slots
  ].freeze

  def test_contract_responds_to_event_methods
    adapter = build_adapter
    EVENT_METHODS.each do |m|
      assert_respond_to adapter, m, "must implement event ##{m}"
    end
    assert_respond_to adapter, :prompts
  end

  def test_contract_event_methods_dont_raise
    # Notification failures must never break the orchestrator. Concrete
    # adapters either rescue internally or are routed to a no-op
    # transport stub for these contract runs.
    adapter = build_adapter
    adapter.issue_picked_up(1, "t", "u/r", "auto")
    adapter.no_slots(0, 3)
    adapter.worker_failed(1, "u/r", StandardError.new("boom"))
  end

  def test_contract_prompts_object_has_send_message
    assert_respond_to build_adapter.prompts, :send_message
  end

  def test_contract_worker_env_returns_string_valued_hash
    env = build_adapter.worker_env
    assert_kind_of Hash, env
    env.each do |k, v|
      assert_kind_of String, k
      assert_kind_of String, v
    end
  end
end
