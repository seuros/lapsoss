# frozen_string_literal: true

module Lapsoss
  # Error exclusion system for filtering exception types
  class ExclusionFilter
    def initialize(configuration = {})
      @excluded_exceptions = configuration[:excluded_exceptions] || []
      @excluded_patterns = configuration[:excluded_patterns] || []
      @excluded_messages = configuration[:excluded_messages] || []
      @excluded_environments = configuration[:excluded_environments] || []
      @custom_filters = configuration[:custom_filters] || []
      @inclusion_overrides = configuration[:inclusion_overrides] || []
    end

    def should_exclude?(event)
      # Check inclusion overrides first - these take precedence
      return false if should_include_override?(event)

      # Apply exclusion filters
      return true if excluded_by_exception_type?(event)
      return true if excluded_by_pattern?(event)
      return true if excluded_by_message?(event)
      return true if excluded_by_environment?(event)
      return true if excluded_by_custom_filter?(event)

      false
    end

    def add_exclusion(type, value)
      case type
      when :exception
        @excluded_exceptions << value
      when :pattern
        @excluded_patterns << value
      when :message
        @excluded_messages << value
      when :environment
        @excluded_environments << value
      when :custom
        @custom_filters << value
      else
        raise ArgumentError, "Unknown exclusion type: #{type}"
      end
    end

    def add_inclusion_override(filter)
      @inclusion_overrides << filter
    end

    def clear_exclusions(type = nil)
      if type
        case type
        when :exception then @excluded_exceptions.clear
        when :pattern then @excluded_patterns.clear
        when :message then @excluded_messages.clear
        when :environment then @excluded_environments.clear
        when :custom then @custom_filters.clear
        else raise ArgumentError, "Unknown exclusion type: #{type}"
        end
      else
        @excluded_exceptions.clear
        @excluded_patterns.clear
        @excluded_messages.clear
        @excluded_environments.clear
        @custom_filters.clear
      end
    end

    def exclusion_stats
      {
        excluded_exceptions: @excluded_exceptions.length,
        excluded_patterns: @excluded_patterns.length,
        excluded_messages: @excluded_messages.length,
        excluded_environments: @excluded_environments.length,
        custom_filters: @custom_filters.length,
        inclusion_overrides: @inclusion_overrides.length
      }
    end

    private

    def should_include_override?(event)
      @inclusion_overrides.any? { |filter| filter.call(event) }
    end

    def excluded_by_exception_type?(event)
      return false unless event.exception

      exception_class = event.exception.class

      @excluded_exceptions.any? do |excluded|
        case excluded
        when Class
          exception_class <= excluded
        when String
          exception_class.name == excluded || exception_class.name.include?(excluded)
        when Regexp
          exception_class.name.match?(excluded)
        else
          false
        end
      end
    end

    def excluded_by_pattern?(event)
      return false unless event.exception

      exception_class = event.exception.class
      exception_message = event.exception.message

      @excluded_patterns.any? do |pattern|
        case pattern
        when Regexp
          exception_class.name.match?(pattern) || exception_message.match?(pattern)
        when String
          exception_class.name.include?(pattern) || exception_message.include?(pattern)
        else
          false
        end
      end
    end

    def excluded_by_message?(event)
      return false unless event.exception

      exception_message = event.exception.message

      @excluded_messages.any? do |excluded_message|
        case excluded_message
        when Regexp
          exception_message.match?(excluded_message)
        when String
          exception_message.include?(excluded_message)
        else
          false
        end
      end
    end

    def excluded_by_environment?(event)
      return false if @excluded_environments.empty?

      environment = event.context[:environment] ||
                    event.context.dig(:tags, :environment) ||
                    Lapsoss.configuration.environment

      return false unless environment

      @excluded_environments.include?(environment.to_s)
    end

    def excluded_by_custom_filter?(event)
      @custom_filters.any? { |filter| filter.call(event) }
    end
  end
end
