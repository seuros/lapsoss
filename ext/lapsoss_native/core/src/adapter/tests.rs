use super::*;

#[test]
fn transport_validation_rejects_unsupported_budgets_and_durations() {
    for (field, value) in [
        ("timeout", 0.0),
        ("timeout", f64::NAN),
        ("timeout", f64::INFINITY),
        ("timeout", f64::MAX),
        ("initial_backoff", -1.0),
        ("initial_backoff", f64::NAN),
        ("max_backoff", 0.5),
        ("max_backoff", f64::MAX),
        ("max_backoff", 1e17), // Duration fits, but milliseconds exceed u64.
        ("backoff_multiplier", 0.5),
        ("backoff_multiplier", f64::INFINITY),
    ] {
        let mut config = TransportConfig::default();
        match field {
            "timeout" => config.timeout = value,
            "initial_backoff" => config.initial_backoff = value,
            "max_backoff" => config.max_backoff = value,
            "backoff_multiplier" => config.backoff_multiplier = value,
            _ => unreachable!("test table contains only transport fields"),
        }
        assert!(config.validate().is_err(), "{field} = {value}");
    }
    for (retries, valid) in [(0, true), (254, true), (255, false), (u32::MAX, false)] {
        let config = TransportConfig {
            max_retries: retries,
            ..TransportConfig::default()
        };
        assert_eq!(config.validate().is_ok(), valid, "max_retries = {retries}");
    }
}

#[test]
fn retry_after_is_advisory_and_cannot_overflow_the_sleep_deadline() {
    for (header, expected) in [
        ("0", Some(Duration::ZERO)),
        ("12", Some(Duration::from_secs(12))),
        ("Sun, 06 Nov 1994 08:49:37 GMT", Some(Duration::ZERO)),
        ("18446744073709551615", None),
        ("-1", None),
        ("not a date", None),
    ] {
        assert_eq!(parse_retry_after(header), expected, "{header}");
    }
}
