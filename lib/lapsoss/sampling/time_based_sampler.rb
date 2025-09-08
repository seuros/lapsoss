# frozen_string_literal: true

module Lapsoss
  module Sampling
    class TimeBasedSampler < Base
      def initialize(schedule: {})
        @schedule = schedule
        @default_rate = schedule.fetch(:default, 1.0)
      end

      def sample?(_event, _hint = {})
        now = Time.zone.now
        rate = find_rate_for_time(now)
        rate > rand
      end

      private

      def find_rate_for_time(time)
        hour = time.hour
        day_of_week = time.wday # 0 = Sunday

        # Check specific hour
        hour_key = :"hour_#{hour}"
        return @schedule[hour_key] if @schedule.key?(hour_key)

        # Check day of week
        day_names = %i[sunday monday tuesday wednesday thursday friday saturday]
        day_key = day_names[day_of_week]
        return @schedule[day_key] if @schedule.key?(day_key)

        # Check business hours
        if @schedule.key?(:business_hours) && (9..17).cover?(hour) && (1..5).cover?(day_of_week)
          return @schedule[:business_hours]
        end

        # Check weekends
        return @schedule[:weekends] if @schedule.key?(:weekends) && [ 0, 6 ].include?(day_of_week)

        @default_rate
      end
    end
  end
end
