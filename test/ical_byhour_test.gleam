//// Tests for RFC 5545 §3.3.10 RECUR rule parts: BYHOUR, BYMINUTE, BYSECOND.
////
//// For FREQ=DAILY/WEEKLY/MONTHLY/YEARLY these rule parts EXPAND the candidate
//// set: each candidate's local time-of-day is replaced by every combination
//// in the cartesian product byhour × byminute × bysecond. When a list is
//// empty the candidate's original component for that field is preserved.
////
//// Test window: Sun 2026-06-14 00:00 EDT → Sun 2026-06-21 00:00 EDT (7 days).
//// DTSTART anchored at Sun 2026-06-14 09:00 EDT so all 7 daily anchors fall
//// inside the window (06-21 anchor is *at* window_end; events whose local
//// hour ≥ midnight on 06-21 are excluded since 06-21 09:00 > 06-21 00:00).

import cal.{AllDay, AtTime}
import gleam/list
import gleam/time/duration
import gleam/time/timestamp
import ical

// 1-week window: Sun 2026-06-14 00:00 EDT → Sun 2026-06-21 00:00 EDT.
fn one_week() -> #(timestamp.Timestamp, timestamp.Timestamp) {
  #(
    timestamp.from_unix_seconds(1_781_409_600),
    timestamp.from_unix_seconds(1_782_014_400),
  )
}

fn et_offset() -> duration.Duration {
  duration.seconds(-4 * 3600)
}

/// Project each timed event to its local (hour, minute) tuple in EDT.
fn event_local_hour_minutes(events: List(cal.Event)) -> List(#(Int, Int)) {
  list.filter_map(events, fn(e: cal.Event) {
    case e.start {
      AtTime(ts) -> {
        let #(_, tod) = timestamp.to_calendar(ts, et_offset())
        Ok(#(tod.hours, tod.minutes))
      }
      AllDay(_) -> Error(Nil)
    }
  })
}

/// Project each timed event to its local (hour, minute, second) tuple in EDT.
fn event_local_hms(events: List(cal.Event)) -> List(#(Int, Int, Int)) {
  list.filter_map(events, fn(e: cal.Event) {
    case e.start {
      AtTime(ts) -> {
        let #(_, tod) = timestamp.to_calendar(ts, et_offset())
        Ok(#(tod.hours, tod.minutes, tod.seconds))
      }
      AllDay(_) -> Error(Nil)
    }
  })
}

// FREQ=DAILY;BYHOUR=9,12,15 emits each daily anchor at 09:00, 12:00, 15:00.
// 7 days within the 1-week window × 3 hours = 21 occurrences.
pub fn daily_byhour_three_values_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:daily-byhour\r\n"
    <> "SUMMARY:Daily 9-12-15\r\n"
    <> "DTSTART;TZID=America/New_York:20260614T090000\r\n"
    <> "DTEND;TZID=America/New_York:20260614T100000\r\n"
    <> "RRULE:FREQ=DAILY;BYHOUR=9,12,15\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = one_week()
  let events = ical.parse_events(ical_text, "Cal", s, e)
  let times = event_local_hour_minutes(events)
  assert list.length(times) == 21
  assert list.contains(times, #(9, 0))
  assert list.contains(times, #(12, 0))
  assert list.contains(times, #(15, 0))
  // Nothing outside BYHOUR set.
  assert !list.contains(times, #(10, 0))
  Nil
}

// FREQ=DAILY;BYMINUTE=0,30 emits each daily anchor at H:00 and H:30.
// 7 days × 2 minutes = 14 occurrences. DTSTART hour is preserved (09).
pub fn daily_byminute_two_values_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:daily-byminute\r\n"
    <> "SUMMARY:Daily :00 :30\r\n"
    <> "DTSTART;TZID=America/New_York:20260614T090000\r\n"
    <> "DTEND;TZID=America/New_York:20260614T100000\r\n"
    <> "RRULE:FREQ=DAILY;BYMINUTE=0,30\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = one_week()
  let events = ical.parse_events(ical_text, "Cal", s, e)
  let times = event_local_hour_minutes(events)
  assert list.length(times) == 14
  assert list.contains(times, #(9, 0))
  assert list.contains(times, #(9, 30))
  // Hour stays at 09 — no other hour selected.
  assert !list.contains(times, #(10, 0))
  assert !list.contains(times, #(8, 30))
  Nil
}

// FREQ=DAILY;BYSECOND=0,30 emits each daily anchor at H:M:00 and H:M:30.
// 7 days × 2 seconds = 14 occurrences.
pub fn daily_bysecond_two_values_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:daily-bysecond\r\n"
    <> "SUMMARY:Daily :00 :30 sec\r\n"
    <> "DTSTART;TZID=America/New_York:20260614T090000\r\n"
    <> "DTEND;TZID=America/New_York:20260614T100000\r\n"
    <> "RRULE:FREQ=DAILY;BYSECOND=0,30\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = one_week()
  let events = ical.parse_events(ical_text, "Cal", s, e)
  let times = event_local_hms(events)
  assert list.length(times) == 14
  assert list.contains(times, #(9, 0, 0))
  assert list.contains(times, #(9, 0, 30))
  assert !list.contains(times, #(9, 0, 15))
  Nil
}

// FREQ=DAILY;BYHOUR=9,17;BYMINUTE=0,30 — cartesian product.
// 7 days × 2 hours × 2 minutes = 28 occurrences at 09:00 09:30 17:00 17:30 each.
pub fn daily_byhour_byminute_combo_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:daily-combo\r\n"
    <> "SUMMARY:Daily 9/17 x :00/:30\r\n"
    <> "DTSTART;TZID=America/New_York:20260614T090000\r\n"
    <> "DTEND;TZID=America/New_York:20260614T093000\r\n"
    <> "RRULE:FREQ=DAILY;BYHOUR=9,17;BYMINUTE=0,30\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = one_week()
  let events = ical.parse_events(ical_text, "Cal", s, e)
  let times = event_local_hour_minutes(events)
  assert list.length(times) == 28
  assert list.contains(times, #(9, 0))
  assert list.contains(times, #(9, 30))
  assert list.contains(times, #(17, 0))
  assert list.contains(times, #(17, 30))
  // Nothing in between.
  assert !list.contains(times, #(13, 0))
  assert !list.contains(times, #(9, 15))
  Nil
}

// Invalid BYHOUR values are dropped at parse time. BYHOUR=9,12,25,-1 keeps
// only 9 and 12 → 7 days × 2 hours = 14 occurrences. If 25 were honored,
// timestamp construction would either explode or wrap; either way we'd see
// a different count or unexpected hours.
pub fn byhour_invalid_dropped_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:byhour-invalid\r\n"
    <> "SUMMARY:Daily filtered hours\r\n"
    <> "DTSTART;TZID=America/New_York:20260614T090000\r\n"
    <> "DTEND;TZID=America/New_York:20260614T100000\r\n"
    <> "RRULE:FREQ=DAILY;BYHOUR=9,12,25,-1\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = one_week()
  let events = ical.parse_events(ical_text, "Cal", s, e)
  let times = event_local_hour_minutes(events)
  assert list.length(times) == 14
  assert list.contains(times, #(9, 0))
  assert list.contains(times, #(12, 0))
  // Out-of-range values must not produce occurrences.
  assert !list.contains(times, #(25, 0))
  assert !list.contains(times, #(23, 0))
  Nil
}
