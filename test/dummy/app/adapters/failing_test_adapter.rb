# frozen_string_literal: true

# Test adapter that always fails to test error handling
class FailingTestAdapter
  def initialize(error_message = "Adapter failure!")
    @error_message = error_message
  end

  def name
    :failing_adapter
  end

  def enabled?
    true
  end

  def capture(_event)
    raise @error_message
  end
end
