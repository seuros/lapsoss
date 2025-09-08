# frozen_string_literal: true

module Lapsoss
  class Pipeline
    def initialize
      @middlewares = []
      @built = false
      @app = nil
    end

    def use(middleware_class, *args, **kwargs)
      raise "Cannot modify pipeline after it's built" if @built

      @middlewares << { class: middleware_class, args: args, kwargs: kwargs }
      self
    end

    def build
      return @app if @built

      # Build the middleware chain from inside out
      @app = build_chain
      @built = true
      @app
    end

    def call(event, hint = {})
      build unless @built
      @app.call(event, hint)
    end

    def reset
      @middlewares.clear
      @built = false
      @app = nil
      self
    end

    def middlewares
      @middlewares.dup
    end

    private

    def build_chain
      # The final app just returns the event
      final_app = ->(event, _hint) { event }

      # Build middleware chain from right to left
      @middlewares.reverse.reduce(final_app) do |app, middleware_config|
        klass = middleware_config[:class]
        args = middleware_config[:args]
        kwargs = middleware_config[:kwargs]

        klass.new(app, *args, **kwargs)
      end
    end
  end
end
