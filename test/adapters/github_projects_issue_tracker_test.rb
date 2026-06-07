require "minitest/autorun"
require_relative "../../lib/adapters/github_projects/issue_tracker"
require_relative "contracts/issue_tracker_contract"

class GithubProjectsIssueTrackerTest < Minitest::Test
  include IssueTrackerContract

  TEST_CONFIG = {
    "owner" => "u",
    "project_number" => 1,
    "project_id" => "PVT_test",
    "statuses" => {
      "ready" => "Ready",
      "planning" => "cc-planning",
      "planning_approved" => "Planning approved",
      "building" => "In progress",
      "pr" => "In review",
      "done" => "Done"
    }
  }.freeze

  def build_adapter
    adapter = Adapters::GithubProjects::IssueTracker.new(TEST_CONFIG.dup)
    items = @seeded_items || []
    adapter.define_singleton_method(:project_items) { items }
    adapter.define_singleton_method(:set_status) { |*, **| } # avoid `gh project item-edit` shell-out
    adapter.define_singleton_method(:fetch_issue_body) { |*, **| "" }
    adapter.define_singleton_method(:flag_for_review?) { |*| false }
    adapter
  end

  def seed_issues(issues)
    @seeded_items = issues.map { |i| i.merge(id: "PVTI_#{i[:number]}") }
  end

  # ---- user/org GraphQL root resolution ----

  # Builds a real adapter (project_items NOT stubbed) whose run_graphql is
  # routed by query content, so we exercise fetch_project_items / owner_type
  # against both a user- and an organization-owned project.
  def adapter_with_graphql(typename:, items_nodes: [], field: nil)
    adapter = Adapters::GithubProjects::IssueTracker.new(TEST_CONFIG.dup)
    root = (typename == "Organization") ? "organization" : "user"
    calls = []
    adapter.define_singleton_method(:run_graphql) do |query, _variables = {}|
      calls << query
      if query.include?("repositoryOwner")
        { "data" => { "repositoryOwner" => { "__typename" => typename } } }
      elsif query.include?("items(")
        { "data" => { root => { "projectV2" => { "items" =>
          { "nodes" => items_nodes, "pageInfo" => { "hasNextPage" => false } } } } } }
      elsif query.include?("field(name")
        { "data" => { root => { "projectV2" => { "field" => field } } } }
      end
    end
    adapter.define_singleton_method(:graphql_calls) { calls }
    adapter
  end

  def issue_node(number:, status:)
    {
      "id" => "PVTI_#{number}", "type" => "ISSUE",
      "fieldValueByName" => { "name" => status },
      "content" => { "number" => number, "title" => "t",
                     "repository" => { "nameWithOwner" => "o/r" } }
    }
  end

  def test_org_owned_project_items_are_read
    adapter = adapter_with_graphql(typename: "Organization",
                                   items_nodes: [issue_node(number: 7, status: "Ready")])
    items = adapter.issues_by_status("Ready")
    assert_equal [7], items.map { |i| i[:number] }
  end

  def test_user_owned_project_items_are_read
    adapter = adapter_with_graphql(typename: "User",
                                   items_nodes: [issue_node(number: 3, status: "Ready")])
    assert_equal [3], adapter.issues_by_status("Ready").map { |i| i[:number] }
  end

  def test_status_option_id_resolves_for_org_project
    field = { "id" => "FIELD_1", "options" => [{ "id" => "OPT_1", "name" => "Ready" }] }
    adapter = adapter_with_graphql(typename: "Organization", field: field)
    assert_equal "OPT_1", adapter.send(:status_option_id, "Ready")
  end

  def test_owner_type_detected_once_and_memoised
    adapter = adapter_with_graphql(typename: "Organization",
                                   items_nodes: [issue_node(number: 1, status: "Ready")])
    adapter.issues_by_status("Ready")
    adapter.send(:owner_type) # second access
    owner_queries = adapter.graphql_calls.count { |q| q.include?("repositoryOwner") }
    assert_equal 1, owner_queries, "owner type should be detected once and cached"
  end
end
