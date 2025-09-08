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

    def add_breadcrumb(message, type: :default, **metadata)
      breadcrumb = Breadcrumb.build(message, type: type, metadata: metadata)
      @own_breadcrumbs << breadcrumb
      # Keep breadcrumbs to a reasonable limit
      @own_breadcrumbs.shift if @own_breadcrumbs.length > 20
      # Clear cached breadcrumbs to force recomputation
      @breadcrumbs = nil
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
