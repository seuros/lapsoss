# frozen_string_literal: true

# Test adapter that allows setting a custom name
class NamedTestAdapter < TestAdapter
  def initialize(name)
    super()
    @adapter_name = name
  end

  def name
    @adapter_name.to_sym
  end
end
