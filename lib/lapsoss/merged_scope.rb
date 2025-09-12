# frozen_string_literal: true

module Lapsoss
  # Performance-optimized scope that provides a merged view without cloning
  class MergedScope
    def initialize(scope_stack, base_scope)
      @scope_stack = scope_stack
      @base_scope = base_scope || Scope.new
      @own_breadcrumbs = []
    end

    def tags
      @tags ||= merge_hash_contexts(:tags)
    end

    def user
      @user ||= merge_hash_contexts(:user)
    end

    def extra
      @extra ||= merge_hash_contexts(:extra)
    end

    def breadcrumbs
      @breadcrumbs ||= merge_breadcrumbs
    end

    def transaction_name
      # Check scope stack first (most recent wins)
      @scope_stack.reverse_each do |context|
        return context[:transaction_name] if context[:transaction_name]
      end
      # Fall back to base scope
      @base_scope.transaction_name
    end

    def transaction_source
      # Check scope stack first (most recent wins)
      @scope_stack.reverse_each do |context|
        return context[:transaction_source] if context[:transaction_source]
      end
      # Fall back to base scope
      @base_scope.transaction_source
    end

    def add_breadcrumb(message, type: :default, **metadata)
      breadcrumb = Breadcrumb.build(message, type: type, metadata: metadata)
      @own_breadcrumbs << breadcrumb
      # Keep breadcrumbs to a reasonable limit
      @own_breadcrumbs.shift if @own_breadcrumbs.length > 20
      # Clear cached breadcrumbs to force recomputation
      @breadcrumbs = nil
    end

    def set_transaction_name(name, source: nil)
      @base_scope.set_transaction_name(name, source: source)
    end

    private

    def merge_hash_contexts(key)
      result = @base_scope.send(key).dup
      @scope_stack.each do |context|
        result.merge!(context[key] || {})
      end
      result
    end

    def merge_breadcrumbs
      result = @base_scope.breadcrumbs.dup
      @scope_stack.each do |context|
        result.concat(context[:breadcrumbs]) if context[:breadcrumbs]
      end
      # Add our own breadcrumbs
      result.concat(@own_breadcrumbs)
      # Keep breadcrumbs to a reasonable limit
      result.last(20)
    end
  end
end
