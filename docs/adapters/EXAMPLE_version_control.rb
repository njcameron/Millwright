# Copy into `lib/adapters/<provider>/version_control.rb`, fill TODOs,
# register: `Adapters::Registry.register(:version_control, :gitlab, ...)`.
# Set `version_control: gitlab` in config.yml.

require_relative "../version_control"

module Adapters
  module Example
    class VersionControl < Adapters::VersionControl
      def initialize(config)
        @config = config
        @prompts = Prompts.new
      end

      def prompts
        @prompts
      end

      # TODO: Return `{ number:, branch: }` for the PR linked to the issue,
      # or `nil` if there is none. Linking by branch-name convention (e.g.
      # branches starting `NNN-`) is the default for GitHub. Cross-provider
      # setups may need an explicit `issue_link` field.
      def find_pr_for_issue(repo, issue_number)
        raise NotImplementedError
      end

      # TODO: Array of review-comment hashes:
      #   { id:, author:, body:, in_reply_to_id:, path:, type: :review }
      def pr_review_comments(repo, pr_number)
        raise NotImplementedError
      end

      # TODO: Array of issue-style comment hashes (no `in_reply_to_id`, no `path`):
      #   { id:, author:, body:, type: :issue }
      def pr_issue_comments(repo, pr_number)
        raise NotImplementedError
      end

      # TODO: Array of comment hashes on a plain issue, same shape as
      #   pr_issue_comments. Often the same endpoint (PRs are issues).
      def issue_comments(repo, issue_number)
        raise NotImplementedError
      end

      # TODO: Post a threaded reply to `comment_id`.
      def post_review_reply(repo, pr_number, comment_id, body)
        raise NotImplementedError
      end

      # TODO: Post a top-level PR comment.
      def post_pr_comment(repo, pr_number, body)
        raise NotImplementedError
      end

      # TODO: Post a top-level comment on an issue.
      def post_issue_comment(repo, issue_number, body)
        raise NotImplementedError
      end

      # TODO: "success" / "failure" / nil for the latest CI run on the branch.
      def latest_run_conclusion(repo, branch)
        raise NotImplementedError
      end

      # TODO: Last ~20k chars of the latest failed CI log, or nil.
      def fetch_failed_log(repo, branch)
        raise NotImplementedError
      end

      # TODO: Authenticated HTTP GET against `url`, returning the body string.
      # Used by the dispatcher to download issue attachments.
      def fetch_authenticated(url)
        raise NotImplementedError
      end

      # TODO: Env hash merged into the worker's spawn environment.
      # Must include whatever auth `git push` / `gh` / `glab` need, plus
      # the git author/committer identity for bot commits.
      #   { "GH_TOKEN" => …, "GIT_AUTHOR_NAME" => …, "GIT_COMMITTER_EMAIL" => …, … }
      def worker_env
        raise NotImplementedError
      end
    end

    class Prompts
      # Each method returns the literal CLI string the worker should run.
      # TODO for every method below: substitute provider verbs.

      def post_issue_comment(issue_number:, repo:, body_placeholder: "<message>")
        raise NotImplementedError
      end

      def view_issue(issue_number:, repo:, comments: false)
        raise NotImplementedError
      end

      def create_pr(issue_number:, repo:, branch:, reviewer:)
        raise NotImplementedError
      end

      def push_branch(branch:)
        raise NotImplementedError
      end

      def checkout_branch(branch:)
        raise NotImplementedError
      end

      def create_worktree(worktree_dir:, branch:, base_branch: "main")
        raise NotImplementedError
      end

      def remove_worktree(worktree_dir:)
        raise NotImplementedError
      end

      def reply_to_review_comment(repo:, pr_number:, body_placeholder: "<your reply>")
        raise NotImplementedError
      end

      def post_pr_comment(pr_number:, repo:, body_placeholder: "<your reply>")
        raise NotImplementedError
      end
    end
  end
end
