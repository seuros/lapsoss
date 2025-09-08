# frozen_string_literal: true

require "singleton"
require "concurrent"

module Lapsoss
  class Registry
    include Singleton

    class AdapterNotFoundError < StandardError; end
    class DuplicateAdapterError < StandardError; end

    def initialize
      @adapters = Concurrent::Map.new
    end

    # Register a named adapter instance
    #
    # @param name [Symbol] Unique identifier for this adapter instance
    # @param type [Symbol] The adapter type (e.g., :sentry, :appsignal)
    # @param settings [Hash] Configuration for the adapter
    # @return [Adapter] The registered adapter instance
    def register(name, type, **settings)
      name = name.to_sym

      # Check if adapter already exists
      raise DuplicateAdapterError, "Adapter '#{name}' already registered" if @adapters.key?(name)

      adapter_class = resolve_adapter_class(type)
      adapter = adapter_class.new(name, settings)
      @adapters[name] = adapter
      adapter
    end

    # Register an adapter instance directly (for testing)
    #
    # @param adapter [Adapter] The adapter instance to register
    def register_adapter(adapter)
      # Ensure we're getting an adapter instance, not a config hash
      raise ArgumentError, "Expected an adapter instance, got #{adapter.class}" unless adapter.respond_to?(:capture)

      name = if adapter.respond_to?(:name) && adapter.name
               adapter.name.to_sym
      elsif adapter.class.name
               adapter.class.name.split("::").last.to_sym
      else
               # Generate a unique name if class name is nil (anonymous class)
               :"adapter_#{adapter.object_id}"
      end
      @adapters[name] = adapter
    end

    # Unregister an adapter
    #
    # @param name [Symbol] The adapter name to remove
    def unregister(name)
      adapter = @adapters.delete(name.to_sym)
      adapter&.shutdown if adapter.respond_to?(:shutdown)
      adapter
    end

    # Get a specific adapter by name
    #
    # @param name [Symbol] The adapter name
    # @return [Adapter, nil] The adapter instance or nil
    def [](name)
      @adapters[name.to_sym]
    end

    # Get all registered adapters
    #
    # @return [Array<Adapter>] All adapter instances
    def all
      @adapters.values
    end

    # Get all active (enabled) adapters
    #
    # @return [Array<Adapter>] Active adapter instances
    def active
      @adapters.values.select(&:enabled?)
    end

    # Check if an adapter is registered
    #
    # @param name [Symbol] The adapter name
    # @return [Boolean]
    def registered?(name)
      @adapters.key?(name.to_sym)
    end

    # Clear all adapters
    def clear!
      @adapters.each_value do |adapter|
        adapter.shutdown if adapter.respond_to?(:shutdown)
      end
      @adapters.clear
    end

    # Get adapter names
    #
    # @return [Array<Symbol>] Registered adapter names
    def names
      @adapters.keys
    end

    # Get all registered adapters (alias for all)
    #
    # @return [Array<Adapter>] All adapter instances
    def adapters
      all
    end

    private

    # Resolve adapter type to class
    def resolve_adapter_class(type)
      # Try to get the class by convention: Adapters::{Type}Adapter
      class_name = "#{type.to_s.split('_').map(&:capitalize).join}Adapter"

      begin
        Adapters.const_get(class_name)
      rescue NameError
        raise AdapterNotFoundError, "Unknown adapter type: #{type}. Expected class: Lapsoss::Adapters::#{class_name}"
      end
    end
  end
end
