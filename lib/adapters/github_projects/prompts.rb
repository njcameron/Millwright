module Adapters
  module GithubProjects
    # Prompt fragments for board-state mutations on GitHub Projects v2.
    # The "needs review" label is how this project signals that a plan
    # is awaiting human approval; other adapters might use a state.
    class Prompts
      def mark_plan_ready(issue_number:, repo:)
        %(gh issue edit #{issue_number} -R #{repo} --add-label "needs review")
      end

      def acknowledge_approval(issue_number:, repo:)
        %(gh issue edit #{issue_number} -R #{repo} --remove-label "needs review")
      end
    end
  end
end
