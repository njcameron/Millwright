module Adapters
  # Symbol → class lookup for adapters. Concerns are :issue_tracker,
  # :version_control, :update_channel, :coding_agent.
  #
  #   Adapters::Registry.register(:update_channel, :slack, Adapters::Slack::UpdateChannel)
  #   Adapters::Registry.build(:update_channel, "slack", config)
  module Registry
    @entries = Hash.new { |h, k| h[k] = {} }

    class << self
      def register(concern, name, klass)
        @entries[concern.to_sym][name.to_sym] = klass
      end

      def build(concern, name, config)
        klass = @entries.fetch(concern.to_sym).fetch(name.to_sym) do
          raise ArgumentError,
                "No adapter registered for #{concern.inspect} named #{name.inspect}. " \
                "Registered: #{@entries[concern.to_sym].keys.inspect}"
        end
        klass.new(config)
      end

      def registered?(concern, name)
        @entries[concern.to_sym].key?(name.to_sym)
      end

      # Test helper.
      def reset!
        @entries = Hash.new { |h, k| h[k] = {} }
      end
    end
  end
end

# Built-in adapter registrations.
require_relative "slack/update_channel"
require_relative "github_projects/issue_tracker"
require_relative "github/version_control"
require_relative "claude_code/coding_agent"
Adapters::Registry.register(:update_channel, :slack, Adapters::Slack::UpdateChannel)
Adapters::Registry.register(:issue_tracker, :github_projects, Adapters::GithubProjects::IssueTracker)
Adapters::Registry.register(:version_control, :github, Adapters::Github::VersionControl)
Adapters::Registry.register(:coding_agent, :claude_code, Adapters::ClaudeCode::CodingAgent)
