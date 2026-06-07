require "minitest/autorun"
require_relative "../../lib/adapters/slack/update_channel"
require_relative "contracts/update_channel_contract"

class SlackUpdateChannelTest < Minitest::Test
  include UpdateChannelContract

  def build_adapter
    adapter = Adapters::Slack::UpdateChannel.new("slack_webhook" => "https://example.test/webhook")
    # Route all transport to a no-op so events don't hit the network.
    adapter.define_singleton_method(:send_blocks) { |*| }
    adapter.define_singleton_method(:post) { |**| }
    adapter
  end

  # The send_message fragment ends up in the on-disk worker prompt, so it must
  # reference the webhook via $SLACK_WEBHOOK rather than inlining the secret.
  def test_send_message_fragment_references_env_var_not_secret
    fragment = build_adapter.prompts.send_message
    assert_includes fragment, "curl -s -X POST"
    assert_includes fragment, "$SLACK_WEBHOOK"
    refute_includes fragment, "example.test/webhook", "webhook secret must not be inlined"
  end

  # worker_env carries the webhook into the worker process so $SLACK_WEBHOOK
  # resolves at runtime; empty when no webhook is configured.
  def test_worker_env_carries_webhook
    assert_equal({ "SLACK_WEBHOOK" => "https://example.test/webhook" }, build_adapter.worker_env)

    no_webhook = Adapters::Slack::UpdateChannel.new("slack_webhook" => nil)
    assert_equal({}, no_webhook.worker_env)
  end

  # Regression: a previous markdown_to_slack call did `.squeeze("\n")`,
  # collapsing `\n\n` paragraph breaks to `\n`. split_for_slack then
  # found no paragraph boundaries and dropped the entire body into one
  # Slack section block — Slack rejects any section text > 3000 chars
  # with `400 invalid_blocks`, and the rescue in #security_scan silently
  # ate the failure. Ensures no chunk exceeds the per-section cap regardless of
  # paragraph length.
  def test_split_for_slack_never_emits_chunk_above_max_length
    adapter = build_adapter
    long_unbroken_paragraph = "a " * 5000 # 10_000 chars, no paragraph breaks
    chunks = adapter.send(:split_for_slack, long_unbroken_paragraph, 2800)
    refute_empty chunks
    chunks.each do |c|
      assert c.length <= 2800, "chunk of #{c.length} chars exceeds 2800 cap"
    end
  end

  def test_split_for_slack_preserves_paragraph_breaks
    adapter = build_adapter
    text = (["paragraph one " * 100, "paragraph two " * 100, "paragraph three " * 100]).join("\n\n")
    chunks = adapter.send(:split_for_slack, text, 2800)
    chunks.each { |c| assert c.length <= 2800 }
    assert chunks.size >= 2, "expected multiple chunks for #{text.length}-char input"
  end

  def test_markdown_to_slack_preserves_double_newlines
    adapter = build_adapter
    md = "## Title\n\nFirst para.\n\nSecond para.\n\n<details>x</details>\n\nThird para."
    result = adapter.send(:markdown_to_slack, md)
    assert_includes result, "\n\n", "double newlines must survive for split_for_slack"
    refute_match(/<details>/, result)
  end
end
