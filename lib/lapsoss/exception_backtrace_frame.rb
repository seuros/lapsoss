# frozen_string_literal: true

module Lapsoss
  # Wrapper for BacktraceFrame that adds exception-specific metadata
  class ExceptionBacktraceFrame
    attr_reader :frame, :exception_class, :is_crash_frame

    def initialize(frame, exception_class: nil, is_crash_frame: false)
      @frame = frame
      @exception_class = exception_class
      @is_crash_frame = is_crash_frame
    end

    def crash_frame?
      @is_crash_frame
    end

    # Delegate all other methods to the wrapped frame
    def method_missing(method, *, &)
      if @frame.respond_to?(method)
        @frame.send(method, *, &)
      else
        super
      end
    end

    def respond_to_missing?(method, include_private = false)
      @frame.respond_to?(method, include_private) || super
    end

    # Override to_h to include exception metadata
    def to_h
      @frame.to_h.merge(
        exception_class: @exception_class,
        crash_frame: @is_crash_frame
      ).compact
    end
  end
end
