//// Tests for RFC 5545 §3.8.2.7 TRANSP property -> Event.free wiring.
////
//// TRANSP indicates whether the event consumes the calendar user's time
//// (OPAQUE — default) or is transparent (TRANSPARENT — does not block).
//// Our `Event.free` field is True iff TRANSP value, uppercased, equals
//// "TRANSPARENT". Default (no TRANSP) and unrecognized values fall back
//// to OPAQUE, i.e. free=False.

import cal
import gleam/list
import gleam/time/timestamp
import ical

// 2-week window: Sun 2026-06-14 00:00 EDT → Sun 2026-06-28 00:00 EDT.
fn two_weeks() -> #(timestamp.Timestamp, timestamp.Timestamp) {
  #(
    timestamp.from_unix_seconds(1_781_409_600),
    timestamp.from_unix_seconds(1_782_619_200),
  )
}

// No TRANSP property at all → defaults to OPAQUE → free=False.
pub fn no_transp_defaults_to_busy_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:no-transp\r\n"
    <> "SUMMARY:Default Busy\r\n"
    <> "DTSTART;TZID=America/New_York:20260615T100000\r\n"
    <> "DTEND;TZID=America/New_York:20260615T110000\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = two_weeks()
  let events = ical.parse_events(ical_text, "Cal", s, e)
  assert list.length(events) == 1
  let assert [event] = events
  assert event.free == False
  Nil
}

// TRANSP:TRANSPARENT → free=True.
pub fn transp_transparent_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:transparent-evt\r\n"
    <> "SUMMARY:Free Event\r\n"
    <> "DTSTART;TZID=America/New_York:20260615T100000\r\n"
    <> "DTEND;TZID=America/New_York:20260615T110000\r\n"
    <> "TRANSP:TRANSPARENT\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = two_weeks()
  let events = ical.parse_events(ical_text, "Cal", s, e)
  assert list.length(events) == 1
  let assert [event] = events
  assert event.free == True
  Nil
}

// TRANSP:OPAQUE (explicit) → free=False.
pub fn transp_opaque_explicit_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:opaque-evt\r\n"
    <> "SUMMARY:Busy Event\r\n"
    <> "DTSTART;TZID=America/New_York:20260615T100000\r\n"
    <> "DTEND;TZID=America/New_York:20260615T110000\r\n"
    <> "TRANSP:OPAQUE\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = two_weeks()
  let events = ical.parse_events(ical_text, "Cal", s, e)
  assert list.length(events) == 1
  let assert [event] = events
  assert event.free == False
  Nil
}

// Case-insensitive comparison: TRANSP:transparent (lowercase value) →
// free=True. Per RFC 5545 §3.3.5 enumerated tokens are case-insensitive.
pub fn transp_lowercase_transparent_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:transparent-lc\r\n"
    <> "SUMMARY:lc value\r\n"
    <> "DTSTART;TZID=America/New_York:20260615T100000\r\n"
    <> "DTEND;TZID=America/New_York:20260615T110000\r\n"
    <> "TRANSP:transparent\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = two_weeks()
  let events = ical.parse_events(ical_text, "Cal", s, e)
  assert list.length(events) == 1
  let assert [event] = events
  assert event.free == True
  Nil
}

// All-day event TRANSP:TRANSPARENT → free=True in the AllDay code path.
pub fn allday_transp_transparent_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:allday-transparent\r\n"
    <> "SUMMARY:All-day free\r\n"
    <> "DTSTART;VALUE=DATE:20260615\r\n"
    <> "DTEND;VALUE=DATE:20260616\r\n"
    <> "TRANSP:TRANSPARENT\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = two_weeks()
  let events = ical.parse_events(ical_text, "Cal", s, e)
  assert list.length(events) == 1
  let assert [event] = events
  assert event.free == True
  Nil
}

// Recurring event with TRANSP:TRANSPARENT → every generated instance
// inherits free=True.
pub fn recurring_transp_propagates_to_all_instances_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:weekly-free\r\n"
    <> "SUMMARY:Weekly free\r\n"
    <> "DTSTART;TZID=America/New_York:20260615T100000\r\n"
    <> "DTEND;TZID=America/New_York:20260615T110000\r\n"
    <> "RRULE:FREQ=WEEKLY;COUNT=3\r\n"
    <> "TRANSP:TRANSPARENT\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = two_weeks()
  let events = ical.parse_events(ical_text, "Cal", s, e)
  assert list.length(events) == 2
  // Every emitted instance must be free.
  list.each(events, fn(ev: cal.Event) { assert ev.free == True })
  Nil
}

// RECURRENCE-ID override may carry a different TRANSP than the master.
// Master is OPAQUE; override flips one instance to TRANSPARENT. The
// remaining instances stay busy; the overridden one is free.
pub fn recurrence_id_override_transp_flip_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:override-transp\r\n"
    <> "SUMMARY:Daily Busy\r\n"
    <> "DTSTART;TZID=America/New_York:20260615T100000\r\n"
    <> "DTEND;TZID=America/New_York:20260615T110000\r\n"
    <> "RRULE:FREQ=DAILY;COUNT=3\r\n"
    <> "TRANSP:OPAQUE\r\n"
    <> "END:VEVENT\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:override-transp\r\n"
    <> "SUMMARY:Daily Busy (override day 2)\r\n"
    <> "RECURRENCE-ID;TZID=America/New_York:20260616T100000\r\n"
    <> "DTSTART;TZID=America/New_York:20260616T100000\r\n"
    <> "DTEND;TZID=America/New_York:20260616T110000\r\n"
    <> "TRANSP:TRANSPARENT\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = two_weeks()
  let events = ical.parse_events(ical_text, "Cal", s, e)
  assert list.length(events) == 3
  // Two of three instances are busy (master defaults), one is free.
  let busy_count =
    list.fold(events, 0, fn(acc, ev: cal.Event) {
      case ev.free {
        False -> acc + 1
        True -> acc
      }
    })
  let free_count =
    list.fold(events, 0, fn(acc, ev: cal.Event) {
      case ev.free {
        True -> acc + 1
        False -> acc
      }
    })
  assert busy_count == 2
  assert free_count == 1
  Nil
}
