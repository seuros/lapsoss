# frozen_string_literal: true

module Lapsoss
  class Scope
    attr_reader :breadcrumbs, :tags, :user, :extra

    def initialize
      @breadcrumbs = []
      @tags = {}
      @user = {}
      @extra = {}
    end

    def add_breadcrumb(message, type: :default, **metadata)
      breadcrumb = Breadcrumb.build(message, type: type, metadata: metadata)
      @breadcrumbs << breadcrumb
      # Keep breadcrumbs to a reasonable limit
      @breadcrumbs.shift if @breadcrumbs.length > 20
    end

    def apply_context(context)
      @tags.merge!(context[:tags] || {})
      @user.merge!(context[:user] || {})
      @extra.merge!(context[:extra] || {})

      # Handle breadcrumbs if provided
      return unless context[:breadcrumbs]

      @breadcrumbs.concat(context[:breadcrumbs])
      # Keep breadcrumbs to a reasonable limit
      @breadcrumbs.shift while @breadcrumbs.length > 20
    end

    def clear
      @breadcrumbs.clear
      @tags.clear
      @user.clear
      @extra.clear
    end

    def set_context(key, value)
      @extra[key] = value
    end

    def set_user(user_info)
      @user.merge!(user_info)
    end

    def set_tag(key, value)
      @tags[key] = value
    end

    def set_tags(tags)
      @tags.merge!(tags)
    end

    def set_extra(key, value)
      @extra[key] = value
    end

    def set_extras(extras)
      @extra.merge!(extras)
    end
  end
end
