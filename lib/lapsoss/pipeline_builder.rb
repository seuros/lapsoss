# frozen_string_literal: true

module Lapsoss
  class PipelineBuilder
    def initialize
      @pipeline = Pipeline.new
    end

    def sample(rate: 1.0, &block)
      @pipeline.use(Middleware::SampleFilter, sample_rate: rate, sample_callback: block)
      self
    end

    def exclude_exceptions(*exception_classes, patterns: [])
      @pipeline.use(Middleware::ExceptionFilter,
                    excluded_exceptions: exception_classes,
                    excluded_patterns: patterns)
      self
    end

    def enhance_user_context(provider: nil, privacy_mode: false)
      @pipeline.use(Middleware::UserContextEnhancer,
                    user_provider: provider,
                    privacy_mode: privacy_mode)
      self
    end

    def track_releases(provider: nil)
      @pipeline.use(Middleware::ReleaseTracker, release_provider: provider)
      self
    end

    def rate_limit(max_events: 100, time_window: 60)
      @pipeline.use(Middleware::RateLimiter,
                    max_events: max_events,
                    time_window: time_window)
      self
    end

    def collect_metrics(collector: nil)
      @pipeline.use(Middleware::MetricsCollector, collector: collector)
      self
    end

    def enrich_events(*enrichers)
      @pipeline.use(Middleware::EventEnricher, enrichers: enrichers)
      self
    end

    def filter_if(&condition)
      @pipeline.use(Middleware::ConditionalFilter, condition)
      self
    end

    def transform_events(&transformer)
      @pipeline.use(Middleware::EventTransformer, transformer)
      self
    end

    def use_middleware(middleware_class, *, **)
      @pipeline.use(middleware_class, *, **)
      self
    end

    delegate :build, to: :@pipeline

    attr_reader :pipeline
  end
end
