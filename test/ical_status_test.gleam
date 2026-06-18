//// Tests for RFC 5545 §3.8.1.11 STATUS property.
////
//// VEVENT STATUS values: TENTATIVE, CONFIRMED, CANCELLED. Default when
//// absent is treated as CONFIRMED. CANCELLED events MUST be excluded
//// from the rendered output (the dashboard should not display them).
////
//// Special cases:
//// * Master VEVENT with STATUS:CANCELLED -> entire recurring series is
////   suppressed (no instances emitted).
//// * RECURRENCE-ID override with STATUS:CANCELLED -> only that single
////   instance is suppressed; the rest of the series remains.

import cal.{AllDay, AtTime}
import gleam/list
import gleam/time/calendar
import gleam/time/duration
import gleam/time/timestamp
import ical

// 2-week window: Sun 2026-06-14 00:00 EDT → Sun 2026-06-28 00:00 EDT.
fn two_weeks() -> #(timestamp.Timestamp, timestamp.Timestamp) {
  #(
    timestamp.from_unix_seconds(1_781_409_600),
    timestamp.from_unix_seconds(1_782_619_200),
  )
}

fn et_date(ts: timestamp.Timestamp) -> calendar.Date {
  let offset = duration.seconds(-4 * 3600)
  timestamp.to_calendar(ts, offset).0
}

fn event_dates(events: List(cal.Event)) -> List(calendar.Date) {
  list.map(events, fn(e: cal.Event) {
    case e.start {
      AtTime(ts) -> et_date(ts)
      AllDay(d) -> d
    }
  })
}

// STATUS:CANCELLED on a non-recurring event → event excluded from output.
pub fn cancelled_event_excluded_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:cancelled-1\r\n"
    <> "SUMMARY:Cancelled\r\n"
    <> "DTSTART;TZID=America/New_York:20260615T100000\r\n"
    <> "DTEND;TZID=America/New_York:20260615T110000\r\n"
    <> "STATUS:CANCELLED\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = two_weeks()
  let events = ical.parse_events(ical_text, "Cal", s, e)
  assert events == []
  Nil
}

// STATUS:CONFIRMED → event included (treated normally).
pub fn confirmed_event_included_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:confirmed-1\r\n"
    <> "SUMMARY:Confirmed\r\n"
    <> "DTSTART;TZID=America/New_York:20260615T100000\r\n"
    <> "DTEND;TZID=America/New_York:20260615T110000\r\n"
    <> "STATUS:CONFIRMED\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = two_weeks()
  let events = ical.parse_events(ical_text, "Cal", s, e)
  assert list.length(events) == 1
  Nil
}

// No STATUS → default treat as CONFIRMED, event included.
pub fn missing_status_treated_as_confirmed_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:no-status\r\n"
    <> "SUMMARY:Default Status\r\n"
    <> "DTSTART;TZID=America/New_York:20260615T100000\r\n"
    <> "DTEND;TZID=America/New_York:20260615T110000\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = two_weeks()
  let events = ical.parse_events(ical_text, "Cal", s, e)
  assert list.length(events) == 1
  Nil
}

// STATUS:TENTATIVE → event still shown (it's still on the calendar).
pub fn tentative_event_included_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:tentative-1\r\n"
    <> "SUMMARY:Tentative\r\n"
    <> "DTSTART;TZID=America/New_York:20260615T100000\r\n"
    <> "DTEND;TZID=America/New_York:20260615T110000\r\n"
    <> "STATUS:TENTATIVE\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = two_weeks()
  let events = ical.parse_events(ical_text, "Cal", s, e)
  assert list.length(events) == 1
  Nil
}

// STATUS comparison is case-insensitive: status:cancelled (lowercase) →
// excluded.
pub fn cancelled_lowercase_excluded_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:cancelled-lc\r\n"
    <> "SUMMARY:Cancelled lc\r\n"
    <> "DTSTART;TZID=America/New_York:20260615T100000\r\n"
    <> "DTEND;TZID=America/New_York:20260615T110000\r\n"
    <> "STATUS:cancelled\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = two_weeks()
  let events = ical.parse_events(ical_text, "Cal", s, e)
  assert events == []
  Nil
}

// Master VEVENT with STATUS:CANCELLED + RRULE → entire series excluded.
pub fn cancelled_master_with_rrule_excluded_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:weekly-cancelled\r\n"
    <> "SUMMARY:Cancelled Weekly\r\n"
    <> "DTSTART;TZID=America/New_York:20260615T100000\r\n"
    <> "DTEND;TZID=America/New_York:20260615T110000\r\n"
    <> "RRULE:FREQ=WEEKLY;COUNT=3\r\n"
    <> "STATUS:CANCELLED\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = two_weeks()
  let events = ical.parse_events(ical_text, "Cal", s, e)
  assert events == []
  Nil
}

// RECURRENCE-ID override with STATUS:CANCELLED → that one instance is
// suppressed; remaining instances still emitted. Daily RRULE with COUNT=3
// minus one cancelled day = 2 events.
pub fn recurrence_id_override_cancelled_drops_one_instance_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:daily-with-cancel\r\n"
    <> "SUMMARY:Daily\r\n"
    <> "DTSTART;TZID=America/New_York:20260615T100000\r\n"
    <> "DTEND;TZID=America/New_York:20260615T110000\r\n"
    <> "RRULE:FREQ=DAILY;COUNT=3\r\n"
    <> "END:VEVENT\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:daily-with-cancel\r\n"
    <> "SUMMARY:Daily (cancelled day 2)\r\n"
    <> "RECURRENCE-ID;TZID=America/New_York:20260616T100000\r\n"
    <> "DTSTART;TZID=America/New_York:20260616T100000\r\n"
    <> "DTEND;TZID=America/New_York:20260616T110000\r\n"
    <> "STATUS:CANCELLED\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = two_weeks()
  let events = ical.parse_events(ical_text, "Cal", s, e)
  let dates = event_dates(events)
  assert list.length(dates) == 2
  assert list.contains(dates, calendar.Date(2026, calendar.June, 15))
  assert !list.contains(dates, calendar.Date(2026, calendar.June, 16))
  assert list.contains(dates, calendar.Date(2026, calendar.June, 17))
  Nil
}
