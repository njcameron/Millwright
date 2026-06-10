module VersionControlContract
  # Concrete adapter tests `include` this and define `build_adapter`.

  REQUIRED_METHODS = %i[
    find_pr_for_issue pr_review_comments pr_issue_comments issue_comments
    post_review_reply post_pr_comment post_issue_comment
    latest_run_conclusion fetch_failed_log
    fetch_authenticated worker_env prompts
  ].freeze

  def test_contract_responds_to_required_methods
    adapter = build_adapter
    REQUIRED_METHODS.each do |m|
      assert_respond_to adapter, m, "must implement ##{m}"
    end
  end

  def test_contract_find_pr_for_issue_returns_hash_or_nil
    result = build_adapter.find_pr_for_issue("u/r", 999_999)
    if result
      assert result.key?(:number), "find_pr_for_issue hash missing :number"
      assert result.key?(:branch), "find_pr_for_issue hash missing :branch"
    end
  end

  def test_contract_pr_comments_return_arrays
    assert_kind_of Array, build_adapter.pr_review_comments("u/r", 1)
    assert_kind_of Array, build_adapter.pr_issue_comments("u/r", 1)
  end

  def test_contract_worker_env_returns_hash_with_string_values
    env = build_adapter.worker_env
    assert_kind_of Hash, env
    env.each do |k, v|
      assert_kind_of String, k
      assert_kind_of String, v unless v.nil?
    end
  end

  def test_contract_prompts_object_has_expected_methods
    p = build_adapter.prompts
    %i[post_issue_comment create_pr push_branch checkout_branch
       create_worktree remove_worktree reply_to_review_comment
       post_pr_comment].each do |m|
      assert_respond_to p, m
    end
  end
end
