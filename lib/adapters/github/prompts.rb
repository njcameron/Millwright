module Adapters
  module Github
    # Multi-line / single-line CLI verb fragments for the worker prompt.
    # Each method returns the literal string that used to be inlined in
    # the handler prompts, so the surrounding prose stays unchanged.
    class Prompts
      def post_issue_comment(issue_number:, repo:, body_placeholder: "<message>")
        %(gh issue comment #{issue_number} -R #{repo} --body "#{body_placeholder}")
      end

      def view_issue(issue_number:, repo:, comments: false)
        suffix = comments ? " --comments" : ""
        "gh issue view #{issue_number} -R #{repo}#{suffix}"
      end

      def create_pr(issue_number:, repo:, branch:, reviewer:)
        %(gh pr create -R #{repo} --title "Fix ##{issue_number}: <title>" --body "Closes ##{issue_number}" --head #{branch} --reviewer #{reviewer})
      end

      def push_branch(branch:)
        "git push origin #{branch}"
      end

      def checkout_branch(branch:)
        "git fetch origin #{branch} && git checkout #{branch}"
      end

      def create_worktree(worktree_dir:, branch:, base_branch: "main")
        "git fetch origin #{base_branch} && git worktree add #{worktree_dir} -b #{branch} origin/#{base_branch}"
      end

      def remove_worktree(worktree_dir:)
        "git worktree remove #{worktree_dir}"
      end

      def reply_to_review_comment(repo:, pr_number:, body_placeholder: "<your reply>")
        %(gh api repos/#{repo}/pulls/#{pr_number}/comments -f body="#{body_placeholder}" -F in_reply_to=<comment_id>)
      end

      def post_pr_comment(pr_number:, repo:, body_placeholder: "<your reply>")
        %(gh pr comment #{pr_number} -R #{repo} --body "#{body_placeholder}")
      end
    end
  end
end
