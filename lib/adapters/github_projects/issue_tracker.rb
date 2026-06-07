require "json"
require "open3"
require_relative "../issue_tracker"
require_relative "prompts"

module Adapters
  module GithubProjects
    # Concrete IssueTracker backed by a GitHub Projects v2 board.
    # Reads via the GraphQL API, writes via `gh project item-edit`,
    # and reads issue body / labels via `gh issue view`.
    class IssueTracker < Adapters::IssueTracker
      def initialize(config)
        @owner = config["owner"]
        @project_number = config["project_number"]
        @project_id = config["project_id"]
        @statuses = config["statuses"]
        @prompts = Adapters::GithubProjects::Prompts.new
      end

      def prompts
        @prompts
      end

      def issues_by_status(status)
        project_items.select { |item| item[:status] == status && item[:type] == "ISSUE" }
      end

      def count_active_workers
        items = project_items
        planning = items.count { |i| i[:status] == @statuses["planning"] && i[:type] == "ISSUE" }
        building = items.count { |i| i[:status] == @statuses["building"] && i[:type] == "ISSUE" }
        planning + building
      end

      def set_status(issue_number, status, repo: nil)
        item = find_project_item(issue_number, repo: repo)
        return unless item

        cmd = [
          "gh", "project", "item-edit",
          "--project-id", @project_id,
          "--id", item[:id],
          "--field-id", status_field_id,
          "--single-select-option-id", status_option_id(status)
        ]
        system(*cmd, exception: true)
      end

      def fetch_issue_body(issue_number, repo:)
        output, status = Open3.capture2(
          "gh", "issue", "view", issue_number.to_s, "-R", repo,
          "--json", "body", "--jq", ".body"
        )
        status.success? ? output : ""
      end

      # "needs review" label means the plan is waiting for human approval.
      # Linear / Jira adapters would check a state instead.
      def flag_for_review?(repo, issue_number)
        output, status = Open3.capture2(
          "gh", "issue", "view", issue_number.to_s, "-R", repo,
          "--json", "labels", "--jq", ".labels[].name"
        )
        return false unless status.success?
        output.split("\n").any? { |l| l.strip.downcase == "needs review" }
      end

      def mark_flagged_for_review(repo, issue_number)
        # Only used by the worker via the prompt fragment (Step 5).
        # Ruby-side callers don't currently invoke this; raising keeps the
        # surface honest until a real caller appears.
        raise NotImplementedError,
              "Worker-side path only — use prompts.mark_plan_ready"
      end

      private

      def project_items
        @project_items_cache ||= fetch_project_items
      end

      def fetch_project_items
        all_nodes = []
        cursor = nil

        loop do
          query = <<~GRAPHQL
            query($owner: String!, $number: Int!, $cursor: String) {
              #{owner_type}(login: $owner) {
                projectV2(number: $number) {
                  items(first: 100, after: $cursor) {
                    pageInfo {
                      hasNextPage
                      endCursor
                    }
                    nodes {
                      id
                      type
                      fieldValueByName(name: "Status") {
                        ... on ProjectV2ItemFieldSingleSelectValue {
                          name
                        }
                      }
                      content {
                        ... on Issue {
                          number
                          title
                          repository {
                            nameWithOwner
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          GRAPHQL

          variables = { owner: @owner, number: @project_number }
          variables[:cursor] = cursor if cursor

          result = run_graphql(query, variables)
          items = result.dig("data", owner_type, "projectV2", "items") || {}
          nodes = items["nodes"] || []
          all_nodes.concat(nodes)

          page_info = items["pageInfo"] || {}
          break unless page_info["hasNextPage"]
          cursor = page_info["endCursor"]
        end

        all_nodes.map do |node|
          {
            id: node["id"],
            type: node["type"],
            status: node.dig("fieldValueByName", "name"),
            repo: node.dig("content", "repository", "nameWithOwner"),
            number: node.dig("content", "number"),
            title: node.dig("content", "title")
          }
        end
      end

      def find_project_item(issue_number, repo: nil)
        project_items.find { |item| item[:number] == issue_number && (repo.nil? || item[:repo] == repo) }
      end

      def status_field_id
        @status_field_id ||= status_field_info["id"]
      end

      def status_option_id(status_name)
        option = status_field_info["options"].find { |o| o["name"].downcase == status_name.downcase }
        raise "Status option '#{status_name}' not found in project" unless option
        option["id"]
      end

      def status_field_info
        @status_field_info ||= begin
          query = <<~GRAPHQL
            query($owner: String!, $number: Int!) {
              #{owner_type}(login: $owner) {
                projectV2(number: $number) {
                  field(name: "Status") {
                    ... on ProjectV2SingleSelectField {
                      id
                      options {
                        id
                        name
                      }
                    }
                  }
                }
              }
            }
          GRAPHQL

          result = run_graphql(query, owner: @owner, number: @project_number)
          result.dig("data", owner_type, "projectV2", "field")
        end
      end

      # GitHub Projects v2 can be owned by a user OR an organisation, and the
      # GraphQL root field differs (`user(login:)` vs `organization(login:)`).
      # Resolve which once per process and memoise it, so every project query
      # targets the correct root. Without this, an org-owned project silently
      # returns null under `user(login:)`.
      def owner_type
        @owner_type ||= begin
          query = <<~GRAPHQL
            query($owner: String!) {
              repositoryOwner(login: $owner) { __typename }
            }
          GRAPHQL
          result = run_graphql(query, owner: @owner)
          result.dig("data", "repositoryOwner", "__typename") == "Organization" ? "organization" : "user"
        end
      end

      def run_graphql(query, variables = {})
        args = ["gh", "api", "graphql", "-f", "query=#{query}"]
        variables.each do |key, value|
          flag = value.is_a?(Integer) ? "-F" : "-f"
          args.push(flag, "#{key}=#{value}")
        end

        retries = 0
        begin
          output, status = Open3.capture2(*args)
          raise "GraphQL query failed: #{output}" unless status.success?
          JSON.parse(output)
        rescue
          retries += 1
          if retries <= 3
            sleep(retries * 5)
            retry
          end
          raise
        end
      end
    end
  end
end
