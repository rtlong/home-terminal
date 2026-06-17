//// Tests for RFC 5545 §3.2.19 TZID parameter quoting.
////
//// Parameter values that contain DQUOTE, COLON, or SEMICOLON must be wrapped
//// in DQUOTEs by the producer; the DQUOTEs are NOT part of the value. iCal
//// in the wild also quotes simple TZIDs unnecessarily ("America/New_York")
//// because some authoring tools always quote — we must handle both.

import cal.{AtTime}
import gleam/time/calendar
import gleam/time/duration
import gleam/time/timestamp
import ical

fn one_day() -> #(timestamp.Timestamp, timestamp.Timestamp) {
  #(
    timestamp.from_unix_seconds(1_781_409_600),
    timestamp.from_unix_seconds(1_781_496_000),
  )
}

fn et_calendar_components(
  ts: timestamp.Timestamp,
) -> #(calendar.Date, calendar.TimeOfDay) {
  let offset = duration.seconds(-4 * 3600)
  timestamp.to_calendar(ts, offset)
}

// Unquoted TZID — REGRESSION: existing behaviour, must still work.
pub fn unquoted_tzid_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:e\r\n"
    <> "SUMMARY:Test\r\n"
    <> "DTSTART;TZID=America/New_York:20260614T090000\r\n"
    <> "DTEND;TZID=America/New_York:20260614T100000\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = one_day()
  let assert [evt, ..] = ical.parse_events(ical_text, "Cal", s, e)
  let assert AtTime(ts) = evt.start
  let #(date, time_of_day) = et_calendar_components(ts)
  assert date == calendar.Date(2026, calendar.June, 14)
  assert time_of_day.hours == 9
  assert time_of_day.minutes == 0
  Nil
}

// Quoted TZID — DQUOTEs are NOT part of the value and must be stripped
// before resolution. Currently get_tzid_param hands the quoted string to
// the qdate FFI which fails to find the zone, so parse_event_time errors
// and the event is dropped.
pub fn quoted_tzid_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:e\r\n"
    <> "SUMMARY:Test\r\n"
    <> "DTSTART;TZID=\"America/New_York\":20260614T090000\r\n"
    <> "DTEND;TZID=\"America/New_York\":20260614T100000\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = one_day()
  let assert [evt, ..] = ical.parse_events(ical_text, "Cal", s, e)
  let assert AtTime(ts) = evt.start
  let #(date, time_of_day) = et_calendar_components(ts)
  assert date == calendar.Date(2026, calendar.June, 14)
  assert time_of_day.hours == 9
  assert time_of_day.minutes == 0
  Nil
}

// Quoted TZID on EXDATE should also be unquoted before lookup.
pub fn quoted_tzid_on_exdate_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:e\r\n"
    <> "SUMMARY:Test\r\n"
    <> "DTSTART;TZID=\"America/New_York\":20260615T090000\r\n"
    <> "DTEND;TZID=\"America/New_York\":20260615T100000\r\n"
    <> "RRULE:FREQ=DAILY\r\n"
    <> "EXDATE;TZID=\"America/New_York\":20260616T090000\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  // 3-day window: 2026-06-15 00:00 ET → 2026-06-18 00:00 ET
  let window_start = timestamp.from_unix_seconds(1_781_409_600)
  let window_end = timestamp.from_unix_seconds(1_781_755_200)
  let events = ical.parse_events(ical_text, "Cal", window_start, window_end)

  // Expect exactly 2 instances (06-15, 06-17) at 09:00 ET; 06-16 excluded.
  let assert [evt1, evt2] = events
  let assert AtTime(t1) = evt1.start
  let assert AtTime(t2) = evt2.start
  let #(d1, tod1) = et_calendar_components(t1)
  let #(d2, tod2) = et_calendar_components(t2)
  assert d1 == calendar.Date(2026, calendar.June, 15)
  assert d2 == calendar.Date(2026, calendar.June, 17)
  // Hour assertion proves the TZID was actually honoured (not UTC fall-through:
  // 09:00 UTC would be 05:00 ET).
  assert tod1.hours == 9
  assert tod2.hours == 9
  Nil
}
