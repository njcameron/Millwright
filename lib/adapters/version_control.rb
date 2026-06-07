module Adapters
  # Abstract base for version-control adapters (GitHub, GitLab, Gitea, ...).
  #
  # Owns repos, PRs, comments, CI status, and the worker-side auth/env that
  # `git push` / `gh` / `glab` need. Also exposes a `#prompts` object so
  # handler prompts don't embed provider-specific CLI invocations.
  class VersionControl
    # Returns {number:, branch:} for the PR linked to the issue, or nil.
    def find_pr_for_issue(repo, issue_number)
      raise NotImplementedError
    end

    # Array of review-comment hashes on the PR.
    def pr_review_comments(repo, pr_number)
      raise NotImplementedError
    end

    # Array of issue-style comment hashes on the PR.
    def pr_issue_comments(repo, pr_number)
      raise NotImplementedError
    end

    # Post a reply to a specific review comment.
    def post_review_reply(repo, pr_number, comment_id, body)
      raise NotImplementedError
    end

    # Post a top-level comment on the PR.
    def post_pr_comment(repo, pr_number, body)
      raise NotImplementedError
    end

    # "success" / "failure" / nil — latest CI conclusion for the branch.
    def latest_run_conclusion(repo, branch)
      raise NotImplementedError
    end

    # Failure log text (string) or nil if no failed run is available.
    def fetch_failed_log(repo, branch)
      raise NotImplementedError
    end

    # Authenticated HTTP GET against `url`. Returns [body, content_type] on
    # success (content_type may be nil if the server omits the header), or nil
    # on failure. Replaces the `gh auth token` + curl backtick in the dispatcher.
    def fetch_authenticated(url)
      raise NotImplementedError
    end

    # Hash of env vars merged into the worker's spawn environment
    # (auth tokens, git author/committer identity, ...).
    def worker_env
      raise NotImplementedError
    end

    # Returns the Prompts object for this adapter.
    def prompts
      raise NotImplementedError
    end
  end
end
