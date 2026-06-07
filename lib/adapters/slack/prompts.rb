module Adapters
  module Slack
    # Prompt fragments — the worker uses these to send Slack updates
    # without the handler knowing the verb is "curl" or the destination
    # is Slack.
    class Prompts
      # Worker substitutes `<message>` (or the supplied placeholder) with the
      # actual text. The webhook is read from the $SLACK_WEBHOOK env var
      # (injected into the worker's environment via UpdateChannel#worker_env)
      # rather than inlined here, so the secret never lands in the on-disk
      # prompt file.
      def send_message(text_placeholder: "<message>")
        %(curl -s -X POST -H 'Content-type: application/json' --data '{"text":"#{text_placeholder}"}' "$SLACK_WEBHOOK")
      end
    end
  end
end
