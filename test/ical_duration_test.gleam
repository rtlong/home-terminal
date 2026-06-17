//// Tests for RFC 5545 §3.3.6 DURATION value type and §3.6.1 DTEND default.
////
//// A VEVENT may be specified with:
////   * DTSTART + DTEND  — the explicit, already-supported form
////   * DTSTART + DURATION  — DTEND = DTSTART + DURATION
////   * DTSTART only — defaults per §3.6.1:
////       - DATE-type DTSTART: event lasts one day, so DTEND = DTSTART + 1d
////       - DATE-TIME-type DTSTART: zero-duration, DTEND = DTSTART
////
//// DURATION grammar (subset we care about):
////   PT1H, PT30M, PT45S, PT1H30M, PT2H30M15S
////   P1D, P7D, P1DT12H
////   P1W (one week)

import cal.{AllDay, AtTime}
import gleam/list
import gleam/time/calendar
import gleam/time/timestamp
import ical

fn week_window() -> #(timestamp.Timestamp, timestamp.Timestamp) {
  // Sun 2026-06-14 00:00 ET → Sun 2026-06-21 00:00 ET
  #(
    timestamp.from_unix_seconds(1_781_409_600),
    timestamp.from_unix_seconds(1_782_014_400),
  )
}

fn first_event(events: List(cal.Event)) -> cal.Event {
  let assert [e, ..] = events
  e
}

// PT1H30M → 90-minute duration
pub fn duration_pt1h30m_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:e\r\n"
    <> "SUMMARY:Meeting\r\n"
    <> "DTSTART:20260615T140000Z\r\n"
    <> "DURATION:PT1H30M\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = week_window()
  let events = ical.parse_events(ical_text, "Cal", s, e)
  assert list.length(events) == 1
  let evt = first_event(events)
  let assert AtTime(start_ts) = evt.start
  let assert AtTime(end_ts) = evt.end
  let diff_secs = timestamp.to_unix_seconds(end_ts) -. timestamp.to_unix_seconds(start_ts)
  assert diff_secs == 5400.0
  // 90 * 60
  Nil
}

// PT30M → 30 minutes
pub fn duration_pt30m_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:e\r\n"
    <> "SUMMARY:Quick\r\n"
    <> "DTSTART:20260615T140000Z\r\n"
    <> "DURATION:PT30M\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = week_window()
  let events = ical.parse_events(ical_text, "Cal", s, e)
  let evt = first_event(events)
  let assert AtTime(start_ts) = evt.start
  let assert AtTime(end_ts) = evt.end
  let diff_secs = timestamp.to_unix_seconds(end_ts) -. timestamp.to_unix_seconds(start_ts)
  assert diff_secs == 1800.0
  Nil
}

// PT2H30M15S → exact seconds
pub fn duration_pt2h30m15s_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:e\r\n"
    <> "SUMMARY:Long\r\n"
    <> "DTSTART:20260615T140000Z\r\n"
    <> "DURATION:PT2H30M15S\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = week_window()
  let events = ical.parse_events(ical_text, "Cal", s, e)
  let evt = first_event(events)
  let assert AtTime(start_ts) = evt.start
  let assert AtTime(end_ts) = evt.end
  let diff_secs = timestamp.to_unix_seconds(end_ts) -. timestamp.to_unix_seconds(start_ts)
  assert diff_secs == 9015.0
  // 2*3600 + 30*60 + 15
  Nil
}

// P1D → 1 day for a timed event
pub fn duration_p1d_timed_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:e\r\n"
    <> "SUMMARY:Day-long\r\n"
    <> "DTSTART:20260615T140000Z\r\n"
    <> "DURATION:P1D\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = week_window()
  let events = ical.parse_events(ical_text, "Cal", s, e)
  let evt = first_event(events)
  let assert AtTime(start_ts) = evt.start
  let assert AtTime(end_ts) = evt.end
  let diff_secs = timestamp.to_unix_seconds(end_ts) -. timestamp.to_unix_seconds(start_ts)
  assert diff_secs == 86_400.0
  Nil
}

// P1W → 7 days
pub fn duration_p1w_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:e\r\n"
    <> "SUMMARY:Week-long\r\n"
    <> "DTSTART:20260615T140000Z\r\n"
    <> "DURATION:P1W\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let window_start = timestamp.from_unix_seconds(1_781_409_600)
  // 4-week window
  let window_end = timestamp.from_unix_seconds(1_784_001_600)
  let events = ical.parse_events(ical_text, "Cal", window_start, window_end)
  let evt = first_event(events)
  let assert AtTime(start_ts) = evt.start
  let assert AtTime(end_ts) = evt.end
  let diff_secs = timestamp.to_unix_seconds(end_ts) -. timestamp.to_unix_seconds(start_ts)
  assert diff_secs == 604_800.0
  // 7 * 86400
  Nil
}

// P1DT12H → 36 hours
pub fn duration_p1dt12h_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:e\r\n"
    <> "SUMMARY:Day-and-a-half\r\n"
    <> "DTSTART:20260615T140000Z\r\n"
    <> "DURATION:P1DT12H\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let window_start = timestamp.from_unix_seconds(1_781_409_600)
  let window_end = timestamp.from_unix_seconds(1_784_001_600)
  let events = ical.parse_events(ical_text, "Cal", window_start, window_end)
  let evt = first_event(events)
  let assert AtTime(start_ts) = evt.start
  let assert AtTime(end_ts) = evt.end
  let diff_secs = timestamp.to_unix_seconds(end_ts) -. timestamp.to_unix_seconds(start_ts)
  assert diff_secs == 129_600.0
  // 36 * 3600
  Nil
}

// All-day VEVENT with no DTEND and no DURATION should default to 1 day
// per RFC 5545 §3.6.1.
pub fn allday_no_dtend_defaults_to_one_day_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:e\r\n"
    <> "SUMMARY:Holiday\r\n"
    <> "DTSTART;VALUE=DATE:20260615\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = week_window()
  let events = ical.parse_events(ical_text, "Cal", s, e)
  let evt = first_event(events)
  let assert AllDay(start_date) = evt.start
  let assert AllDay(end_date) = evt.end
  assert start_date == calendar.Date(2026, calendar.June, 15)
  assert end_date == calendar.Date(2026, calendar.June, 16)
  Nil
}

// Timed VEVENT with no DTEND and no DURATION should default to zero duration
// per RFC 5545 §3.6.1.
pub fn timed_no_dtend_defaults_to_zero_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:e\r\n"
    <> "SUMMARY:Instant\r\n"
    <> "DTSTART:20260615T140000Z\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = week_window()
  let events = ical.parse_events(ical_text, "Cal", s, e)
  let evt = first_event(events)
  let assert AtTime(start_ts) = evt.start
  let assert AtTime(end_ts) = evt.end
  assert timestamp.to_unix_seconds(start_ts) == timestamp.to_unix_seconds(end_ts)
  Nil
}

// All-day DURATION P3D should extend the event to 3 days.
pub fn allday_with_duration_p3d_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:e\r\n"
    <> "SUMMARY:Conference\r\n"
    <> "DTSTART;VALUE=DATE:20260615\r\n"
    <> "DURATION:P3D\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = week_window()
  let events = ical.parse_events(ical_text, "Cal", s, e)
  let evt = first_event(events)
  let assert AllDay(start_date) = evt.start
  let assert AllDay(end_date) = evt.end
  assert start_date == calendar.Date(2026, calendar.June, 15)
  assert end_date == calendar.Date(2026, calendar.June, 18)
  Nil
}

// Recurring event with DURATION should still expand correctly with the right
// per-instance duration.
pub fn recurring_with_duration_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:e\r\n"
    <> "SUMMARY:Daily Standup\r\n"
    <> "DTSTART:20260615T140000Z\r\n"
    <> "DURATION:PT15M\r\n"
    <> "RRULE:FREQ=DAILY\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = week_window()
  let events = ical.parse_events(ical_text, "Cal", s, e)
  // Daily starting 06-15 within week ending 06-21 → 06-15, 16, 17, 18, 19, 20 = 6 instances
  assert list.length(events) == 6
  let evt = first_event(events)
  let assert AtTime(start_ts) = evt.start
  let assert AtTime(end_ts) = evt.end
  let diff_secs = timestamp.to_unix_seconds(end_ts) -. timestamp.to_unix_seconds(start_ts)
  assert diff_secs == 900.0
  Nil
}
