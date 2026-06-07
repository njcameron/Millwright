module IssueTrackerContract
  # Concrete adapter tests `include` this module after defining
  # `build_adapter` (a hermetic instance) and `seed_issues(issues)`
  # (so the contract can plant issues to read back).

  REQUIRED_FIELDS = %i[number repo title status type].freeze

  def test_contract_responds_to_required_methods
    adapter = build_adapter
    %i[issues_by_status count_active_workers set_status
       fetch_issue_body flag_for_review? mark_flagged_for_review prompts].each do |m|
      assert_respond_to adapter, m, "must implement ##{m}"
    end
  end

  def test_contract_issues_by_status_returns_array_of_hashes
    adapter = build_adapter
    seed_issues([
      { number: 1, repo: "u/r", title: "Foo", status: "Ready", type: "ISSUE" }
    ])
    result = adapter.issues_by_status("Ready")
    assert_kind_of Array, result
    return if result.empty?
    REQUIRED_FIELDS.each do |k|
      assert result.first.key?(k), "issues_by_status hash missing key #{k.inspect}"
    end
  end

  def test_contract_set_status_is_idempotent
    adapter = build_adapter
    seed_issues([
      { number: 1, repo: "u/r", title: "Foo", status: "Ready", type: "ISSUE" }
    ])
    adapter.set_status(1, "Ready", repo: "u/r")
    adapter.set_status(1, "Ready", repo: "u/r")
  end

  def test_contract_count_active_workers_returns_integer
    assert_kind_of Integer, build_adapter.count_active_workers
  end

  def test_contract_prompts_object_has_expected_methods
    p = build_adapter.prompts
    assert_respond_to p, :mark_plan_ready
    assert_respond_to p, :acknowledge_approval
  end
end
