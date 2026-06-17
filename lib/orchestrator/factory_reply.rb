class Orchestrator
  # Identifies comments authored by the factory so the comment handlers can tell
  # a worker's reply apart from genuine human feedback.
  #
  # On repos where the GitHub App token is read-only, workers strip GH_TOKEN and
  # post their replies as the OWNER account. But the owner account is ALSO the
  # human reviewer (Dispatcher requests it via `gh pr create --reviewer`), so the
  # author alone can't distinguish a worker's owner-authored reply from the
  # owner's own review feedback. Treating every owner comment as factory-side
  # silently swallows that feedback (and, for plans-under-review, ALL of it).
  #
  # To disambiguate without leaning on the author, every factory-posted comment
  # embeds a hidden marker. A comment counts as factory-side when it is from the
  # bot OR carries that marker; the owner's unmarked feedback is left alone.
  module FactoryReply
    # A hidden HTML comment: invisible in GitHub's rendered view, but preserved
    # in the body the API returns, so dedup can spot factory replies regardless
    # of which account posted them.
    MARKER = "<!-- millwright-factory-reply -->".freeze

    module_function

    # True when the comment was posted by the factory — either the bot account
    # or a worker that stamped its reply with MARKER (e.g. posting as the owner
    # on a read-only-token repo).
    def factory?(comment, factory_user)
      comment[:author] == factory_user || comment[:body].to_s.include?(MARKER)
    end

    # Appends the marker to a factory-authored body so a later tick recognises
    # it as a factory reply even when it was posted by the owner account.
    def stamp(body)
      "#{body}\n\n#{MARKER}"
    end
  end
end
