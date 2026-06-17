//// Tests for RFC 5545 §3.8.5.1 EXDATE property.
////
//// Covers parser handling of:
////   * All-day EXDATE values (DATE form) on all-day recurring events.
////   * Multiple comma-separated values on a single EXDATE line.
////   * Timed EXDATE with multiple values.

import cal.{AllDay, AtTime}
import gleam/list
import gleam/time/calendar
import gleam/time/duration
import gleam/time/timestamp
import ical

// 2-week window: Sun 2026-06-14 00:00 ET → Sun 2026-06-28 00:00 ET
fn two_weeks() -> #(timestamp.Timestamp, timestamp.Timestamp) {
  #(
    timestamp.from_unix_seconds(1_781_409_600),
    timestamp.from_unix_seconds(1_782_619_200),
  )
}

// 4-week window: Sun 2026-06-14 00:00 ET → Sun 2026-07-12 00:00 ET
fn four_weeks() -> #(timestamp.Timestamp, timestamp.Timestamp) {
  #(
    timestamp.from_unix_seconds(1_781_409_600),
    timestamp.from_unix_seconds(1_784_001_600),
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

// All-day EXDATE on an all-day recurring event must suppress that instance.
// REGRESSION: collect_exdates currently returns Error(Nil) for AllDay values,
// so the EXDATE is silently ignored and the excluded day still appears.
pub fn allday_exdate_excludes_instance_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:allday-exdate\r\n"
    <> "SUMMARY:All Day Daily\r\n"
    <> "DTSTART;VALUE=DATE:20260615\r\n"
    <> "DTEND;VALUE=DATE:20260616\r\n"
    <> "RRULE:FREQ=DAILY\r\n"
    <> "EXDATE;VALUE=DATE:20260617\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(start, end_) = two_weeks()
  let events = ical.parse_events(ical_text, "Cal", start, end_)
  let dates = event_dates(events)
  // 13 daily instances span 06-15..06-27 (window end 06-28 is exclusive);
  // dropping 06-17 leaves 12.
  assert !list.contains(dates, calendar.Date(2026, calendar.June, 17))
  assert list.length(dates) == 12
  Nil
}

// EXDATE may carry MULTIPLE comma-separated values on a single line:
//   EXDATE;VALUE=DATE:20260617,20260620,20260624
// (RFC 5545 §3.8.5.1: "value-list = value *(COMMA value)")
pub fn allday_multi_value_exdate_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:multi-exdate\r\n"
    <> "SUMMARY:Multi ExDate\r\n"
    <> "DTSTART;VALUE=DATE:20260615\r\n"
    <> "DTEND;VALUE=DATE:20260616\r\n"
    <> "RRULE:FREQ=DAILY\r\n"
    <> "EXDATE;VALUE=DATE:20260617,20260620,20260624\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(start, end_) = two_weeks()
  let events = ical.parse_events(ical_text, "Cal", start, end_)
  let dates = event_dates(events)
  assert !list.contains(dates, calendar.Date(2026, calendar.June, 17))
  assert !list.contains(dates, calendar.Date(2026, calendar.June, 20))
  assert !list.contains(dates, calendar.Date(2026, calendar.June, 24))
  // 13 daily instances minus 3 excluded = 10.
  assert list.length(dates) == 10
  Nil
}

// Timed EXDATE with multiple values on one line should exclude each.
pub fn timed_multi_value_exdate_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:timed-multi-exdate\r\n"
    <> "SUMMARY:Daily Standup\r\n"
    <> "DTSTART;TZID=America/New_York:20260615T090000\r\n"
    <> "DTEND;TZID=America/New_York:20260615T093000\r\n"
    <> "RRULE:FREQ=DAILY\r\n"
    <> "EXDATE;TZID=America/New_York:20260617T090000,20260620T090000\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(start, end_) = two_weeks()
  let events = ical.parse_events(ical_text, "Cal", start, end_)
  let dates = event_dates(events)
  assert !list.contains(dates, calendar.Date(2026, calendar.June, 17))
  assert !list.contains(dates, calendar.Date(2026, calendar.June, 20))
  assert list.length(dates) == 11
  Nil
}

// Multiple EXDATE lines should accumulate (also tests interaction with multi-value).
pub fn multiple_exdate_lines_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:multi-line-exdate\r\n"
    <> "SUMMARY:Test\r\n"
    <> "DTSTART;VALUE=DATE:20260615\r\n"
    <> "DTEND;VALUE=DATE:20260616\r\n"
    <> "RRULE:FREQ=DAILY\r\n"
    <> "EXDATE;VALUE=DATE:20260617\r\n"
    <> "EXDATE;VALUE=DATE:20260620,20260624\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(start, end_) = four_weeks()
  let events = ical.parse_events(ical_text, "Cal", start, end_)
  let dates = event_dates(events)
  assert !list.contains(dates, calendar.Date(2026, calendar.June, 17))
  assert !list.contains(dates, calendar.Date(2026, calendar.June, 20))
  assert !list.contains(dates, calendar.Date(2026, calendar.June, 24))
  Nil
}
