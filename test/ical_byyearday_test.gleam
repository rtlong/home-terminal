//// Tests for RFC 5545 §3.3.10 BYYEARDAY recurrence rule part.
////
//// BYYEARDAY specifies a list of day-of-year ordinals (1..366 or -366..-1).
//// Negative values count from the end of the year (-1 = Dec 31).
////
//// Per RFC 5545: BYYEARDAY MUST NOT be specified when FREQ is DAILY, WEEKLY,
//// or MONTHLY. We silently ignore it for those frequencies.
////
//// Common patterns: "first day of year", "last day of year", "100 days into
//// the year". 2026 and 2027 are non-leap years (365 days).

import cal.{AllDay, AtTime}
import gleam/list
import gleam/time/calendar
import gleam/time/duration
import gleam/time/timestamp
import ical

// 2-year window: Thu 2026-01-01 00:00 ET -> Sat 2028-01-01 00:00 ET
fn two_years() -> #(timestamp.Timestamp, timestamp.Timestamp) {
  #(
    timestamp.from_unix_seconds(1_767_243_600),
    timestamp.from_unix_seconds(1_830_315_600),
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

pub fn yearly_byyearday_first_day_test() -> Nil {
  // FREQ=YEARLY;BYYEARDAY=1 — Jan 1 each year.
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:byd-first\r\n"
    <> "SUMMARY:New Year\r\n"
    <> "DTSTART;VALUE=DATE:20260101\r\n"
    <> "DTEND;VALUE=DATE:20260102\r\n"
    <> "RRULE:FREQ=YEARLY;BYYEARDAY=1\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = two_years()
  let dates = ical.parse_events(ical_text, "Cal", s, e) |> event_dates
  assert list.length(dates) == 2
  assert list.contains(dates, calendar.Date(2026, calendar.January, 1))
  assert list.contains(dates, calendar.Date(2027, calendar.January, 1))
  Nil
}

pub fn yearly_byyearday_last_day_test() -> Nil {
  // FREQ=YEARLY;BYYEARDAY=-1 — Dec 31 each year (last day).
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:byd-last\r\n"
    <> "SUMMARY:Year-end\r\n"
    <> "DTSTART;VALUE=DATE:20261231\r\n"
    <> "DTEND;VALUE=DATE:20270101\r\n"
    <> "RRULE:FREQ=YEARLY;BYYEARDAY=-1\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = two_years()
  let dates = ical.parse_events(ical_text, "Cal", s, e) |> event_dates
  assert list.length(dates) == 2
  assert list.contains(dates, calendar.Date(2026, calendar.December, 31))
  assert list.contains(dates, calendar.Date(2027, calendar.December, 31))
  Nil
}

pub fn yearly_byyearday_specific_test() -> Nil {
  // FREQ=YEARLY;BYYEARDAY=100 — 100th day of year.
  // 2026 (non-leap): Jan 31 + Feb 28 + Mar 31 = 90; day 100 = Apr 10.
  // 2027 (non-leap): same → Apr 10.
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:byd-100\r\n"
    <> "SUMMARY:Day 100\r\n"
    <> "DTSTART;VALUE=DATE:20260410\r\n"
    <> "DTEND;VALUE=DATE:20260411\r\n"
    <> "RRULE:FREQ=YEARLY;BYYEARDAY=100\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = two_years()
  let dates = ical.parse_events(ical_text, "Cal", s, e) |> event_dates
  assert list.length(dates) == 2
  assert list.contains(dates, calendar.Date(2026, calendar.April, 10))
  assert list.contains(dates, calendar.Date(2027, calendar.April, 10))
  Nil
}

pub fn yearly_byyearday_multiple_test() -> Nil {
  // FREQ=YEARLY;BYYEARDAY=1,100,-1 — first, 100th, last day each year.
  // 2026: Jan 1, Apr 10, Dec 31. 2027: same. Total 6.
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:byd-multi\r\n"
    <> "SUMMARY:Markers\r\n"
    <> "DTSTART;VALUE=DATE:20260101\r\n"
    <> "DTEND;VALUE=DATE:20260102\r\n"
    <> "RRULE:FREQ=YEARLY;BYYEARDAY=1,100,-1\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = two_years()
  let dates = ical.parse_events(ical_text, "Cal", s, e) |> event_dates
  assert list.length(dates) == 6
  assert list.contains(dates, calendar.Date(2026, calendar.January, 1))
  assert list.contains(dates, calendar.Date(2026, calendar.April, 10))
  assert list.contains(dates, calendar.Date(2026, calendar.December, 31))
  assert list.contains(dates, calendar.Date(2027, calendar.January, 1))
  assert list.contains(dates, calendar.Date(2027, calendar.April, 10))
  assert list.contains(dates, calendar.Date(2027, calendar.December, 31))
  Nil
}

pub fn byyearday_invalid_values_dropped_test() -> Nil {
  // BYYEARDAY=0,367,-367 are invalid; only 100 retained.
  // Expect same as yearly_byyearday_specific_test.
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:byd-invalid\r\n"
    <> "SUMMARY:Day 100\r\n"
    <> "DTSTART;VALUE=DATE:20260410\r\n"
    <> "DTEND;VALUE=DATE:20260411\r\n"
    <> "RRULE:FREQ=YEARLY;BYYEARDAY=0,100,367,-367\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = two_years()
  let dates = ical.parse_events(ical_text, "Cal", s, e) |> event_dates
  assert list.length(dates) == 2
  assert list.contains(dates, calendar.Date(2026, calendar.April, 10))
  assert list.contains(dates, calendar.Date(2027, calendar.April, 10))
  Nil
}

pub fn byyearday_with_non_yearly_ignored_test() -> Nil {
  // RFC: BYYEARDAY MUST NOT be specified with FREQ=DAILY/WEEKLY/MONTHLY.
  // Robust behavior: ignore BYYEARDAY for non-YEARLY, fall back to FREQ=MONTHLY.
  // DTSTART=Apr 10, FREQ=MONTHLY → emit 10th of each month for 2 years = 24.
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:byd-monthly\r\n"
    <> "SUMMARY:10th\r\n"
    <> "DTSTART;VALUE=DATE:20260110\r\n"
    <> "DTEND;VALUE=DATE:20260111\r\n"
    <> "RRULE:FREQ=MONTHLY;BYYEARDAY=100\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = two_years()
  let dates = ical.parse_events(ical_text, "Cal", s, e) |> event_dates
  assert list.length(dates) == 24
  assert list.contains(dates, calendar.Date(2026, calendar.January, 10))
  assert list.contains(dates, calendar.Date(2026, calendar.December, 10))
  assert list.contains(dates, calendar.Date(2027, calendar.January, 10))
  assert list.contains(dates, calendar.Date(2027, calendar.December, 10))
  Nil
}
