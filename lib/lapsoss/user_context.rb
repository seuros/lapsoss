# frozen_string_literal: true

module Lapsoss
  # Enhanced user context handling with privacy controls
  class UserContext
    SENSITIVE_FIELDS = %i[
      email phone mobile telephone
      address street city state zip postal_code country
      ssn social_security_number
      credit_card card_number cvv
      password password_confirmation
      secret token api_key
      ip_address last_login_ip
      birth_date date_of_birth dob
      salary income wage
    ].freeze

    def initialize(privacy_mode: false, allowed_fields: nil, field_transformers: {})
      @privacy_mode = privacy_mode
      @allowed_fields = allowed_fields&.map(&:to_sym)
      @field_transformers = field_transformers
    end

    def process_user_data(user_data)
      return {} unless user_data.is_a?(Hash)

      processed = {}

      user_data.each do |key, value|
        key_sym = key.to_sym

        # Skip if not in allowed fields list (when specified)
        next if @allowed_fields&.exclude?(key_sym)

        # Apply privacy filtering
        processed[key] = if @privacy_mode && sensitive_field?(key_sym)
                           apply_privacy_filter(key_sym, value)
        else
                           transform_field(key_sym, value)
        end
      end

      processed
    end

    def merge_user_data(existing_data, new_data)
      existing_processed = process_user_data(existing_data || {})
      new_processed = process_user_data(new_data || {})

      existing_processed.merge(new_processed)
    end

    def extract_user_id(user_data)
      return nil unless user_data.is_a?(Hash)

      # Try common user ID fields in order of preference
      %i[id user_id uuid guid].each do |field|
        value = user_data[field] || user_data[field.to_s]
        return value if value
      end

      nil
    end

    def extract_user_segment(user_data)
      return nil unless user_data.is_a?(Hash)

      segments = {}

      # Check for common user segments
      segments[:internal] = !(user_data[:internal] || user_data["internal"]).nil?
      segments[:premium] = !(user_data[:premium] || user_data["premium"]).nil?
      segments[:beta] = !(user_data[:beta] || user_data["beta"]).nil?
      segments[:admin] = !(user_data[:admin] || user_data["admin"]).nil?

      # Check role-based segments
      if role = user_data[:role] || user_data["role"]
        segments[:role] = role.to_s.downcase
      end

      # Check plan-based segments
      if plan = user_data[:plan] || user_data["plan"]
        segments[:plan] = plan.to_s.downcase
      end

      segments.compact
    end

    def sanitize_for_logging(user_data)
      return {} unless user_data.is_a?(Hash)

      sanitized = {}

      user_data.each do |key, value|
        key_sym = key.to_sym

        sanitized[key] = if sensitive_field?(key_sym)
                           "[REDACTED]"
        else
                           case value
                           in Hash => h
                             sanitize_for_logging(h)
                           in Array => arr
                             arr.map do |v|
                               case v
                               in Hash => h
                                 sanitize_for_logging(h)
                               else
                                 v
                               end
                             end
                           else
                             value
                           end
        end
      end

      sanitized
    end

    private

    def sensitive_field?(field)
      SENSITIVE_FIELDS.include?(field) || field.to_s.match?(/password|secret|token|key|ssn|credit|card/i)
    end

    def apply_privacy_filter(field, value)
      case field
      when :email
        mask_email(value)
      when :phone, :mobile, :telephone
        mask_phone(value)
      when :ip_address, :last_login_ip
        mask_ip(value)
      else
        "[FILTERED]"
      end
    end

    def transform_field(field, value)
      if transformer = @field_transformers[field]
        transformer.call(value)
      else
        value
      end
    end

    def mask_email(email)
      return "[INVALID_EMAIL]" unless email.is_a?(String) && email.include?("@")

      local, domain = email.split("@", 2)
      masked_local = local.length > 2 ? "#{local[0]}***#{local[-1]}" : "***"
      "#{masked_local}@#{domain}"
    end

    def mask_phone(phone)
      return "[INVALID_PHONE]" unless phone.is_a?(String)

      # Remove all non-digits
      digits = phone.gsub(/\D/, "")
      return "[INVALID_PHONE]" if digits.length < 4

      # Show last 4 digits
      ("*" * (digits.length - 4)) + digits[-4..]
    end

    def mask_ip(ip)
      return "[INVALID_IP]" unless ip.is_a?(String)

      if ip.include?(":")
        # IPv6 - mask last 4 groups
        parts = ip.split(":")
        parts[-4..-1] = [ "****" ] * 4 if parts.length >= 4
        parts.join(":")
      else
        # IPv4 - mask last octet
        parts = ip.split(".")
        return "[INVALID_IP]" if parts.length != 4

        parts[-1] = "***"
        parts.join(".")
      end
    end
  end
end
