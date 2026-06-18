//// Tests for RFC 5545 §3.3.10 BYMONTHDAY rule part.
////
//// BYMONTHDAY specifies specific days of the month for monthly recurrence:
////   * Positive: 1-31 (day of month)
////   * Negative: -1 to -31 (counting from end: -1 = last day, -2 = second-to-last)
////   * Multi-value: comma-separated (e.g., "15,-1" for 15th AND last day)
////
//// When combined with BYDAY in monthly rules, RFC 5545 says BYDAY is evaluated
//// first to find weekday candidates, then filtered to those matching BYMONTHDAY.
//// For simplicity, we test them separately here (common case).

import cal.{AllDay, AtTime}
import gleam/list
import gleam/time/calendar
import gleam/time/duration
import gleam/time/timestamp
import ical

// Window: Mon 2026-06-01 00:00 ET -> Thu 2026-10-01 00:00 ET (four months).
fn four_months() -> #(timestamp.Timestamp, timestamp.Timestamp) {
  #(
    timestamp.from_unix_seconds(1_780_286_400),
    timestamp.from_unix_seconds(1_790_827_200),
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

pub fn monthly_bymonthday_15th_test() -> Nil {
  // Every 15th of the month: Jun 15, Jul 15, Aug 15, Sep 15.
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:monthly-15th\r\n"
    <> "SUMMARY:15th of Month\r\n"
    <> "DTSTART;VALUE=DATE:20260615\r\n"
    <> "DTEND;VALUE=DATE:20260616\r\n"
    <> "RRULE:FREQ=MONTHLY;BYMONTHDAY=15\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = four_months()
  let dates = ical.parse_events(ical_text, "Cal", s, e) |> event_dates
  assert list.length(dates) == 4
  assert list.contains(dates, calendar.Date(2026, calendar.June, 15))
  assert list.contains(dates, calendar.Date(2026, calendar.July, 15))
  assert list.contains(dates, calendar.Date(2026, calendar.August, 15))
  assert list.contains(dates, calendar.Date(2026, calendar.September, 15))
  Nil
}

pub fn monthly_bymonthday_last_day_test() -> Nil {
  // Last day of each month: Jun 30, Jul 31, Aug 31, Sep 30.
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:monthly-last\r\n"
    <> "SUMMARY:Last Day of Month\r\n"
    <> "DTSTART;VALUE=DATE:20260630\r\n"
    <> "DTEND;VALUE=DATE:20260701\r\n"
    <> "RRULE:FREQ=MONTHLY;BYMONTHDAY=-1\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = four_months()
  let dates = ical.parse_events(ical_text, "Cal", s, e) |> event_dates
  assert list.length(dates) == 4
  assert list.contains(dates, calendar.Date(2026, calendar.June, 30))
  assert list.contains(dates, calendar.Date(2026, calendar.July, 31))
  assert list.contains(dates, calendar.Date(2026, calendar.August, 31))
  assert list.contains(dates, calendar.Date(2026, calendar.September, 30))
  Nil
}

pub fn monthly_bymonthday_multi_value_test() -> Nil {
  // 15th AND last day of each month: 8 events across 4 months.
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:monthly-15th-and-last\r\n"
    <> "SUMMARY:15th and Last Day\r\n"
    <> "DTSTART;VALUE=DATE:20260615\r\n"
    <> "DTEND;VALUE=DATE:20260616\r\n"
    <> "RRULE:FREQ=MONTHLY;BYMONTHDAY=15,-1\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = four_months()
  let dates = ical.parse_events(ical_text, "Cal", s, e) |> event_dates
  assert list.length(dates) == 8
  // 15ths
  assert list.contains(dates, calendar.Date(2026, calendar.June, 15))
  assert list.contains(dates, calendar.Date(2026, calendar.July, 15))
  assert list.contains(dates, calendar.Date(2026, calendar.August, 15))
  assert list.contains(dates, calendar.Date(2026, calendar.September, 15))
  // Last days
  assert list.contains(dates, calendar.Date(2026, calendar.June, 30))
  assert list.contains(dates, calendar.Date(2026, calendar.July, 31))
  assert list.contains(dates, calendar.Date(2026, calendar.August, 31))
  assert list.contains(dates, calendar.Date(2026, calendar.September, 30))
  Nil
}

pub fn monthly_bymonthday_second_to_last_test() -> Nil {
  // Second-to-last day of each month: Jun 29, Jul 30, Aug 30, Sep 29.
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:monthly-2nd-to-last\r\n"
    <> "SUMMARY:Second to Last Day\r\n"
    <> "DTSTART;VALUE=DATE:20260629\r\n"
    <> "DTEND;VALUE=DATE:20260630\r\n"
    <> "RRULE:FREQ=MONTHLY;BYMONTHDAY=-2\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = four_months()
  let dates = ical.parse_events(ical_text, "Cal", s, e) |> event_dates
  assert list.length(dates) == 4
  assert list.contains(dates, calendar.Date(2026, calendar.June, 29))
  assert list.contains(dates, calendar.Date(2026, calendar.July, 30))
  assert list.contains(dates, calendar.Date(2026, calendar.August, 30))
  assert list.contains(dates, calendar.Date(2026, calendar.September, 29))
  Nil
}

pub fn monthly_bymonthday_with_count_test() -> Nil {
  // COUNT=3 → only first three 15ths.
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:monthly-count\r\n"
    <> "SUMMARY:15th of Month (COUNT=3)\r\n"
    <> "DTSTART;VALUE=DATE:20260615\r\n"
    <> "DTEND;VALUE=DATE:20260616\r\n"
    <> "RRULE:FREQ=MONTHLY;BYMONTHDAY=15;COUNT=3\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = four_months()
  let dates = ical.parse_events(ical_text, "Cal", s, e) |> event_dates
  assert list.length(dates) == 3
  assert list.contains(dates, calendar.Date(2026, calendar.June, 15))
  assert list.contains(dates, calendar.Date(2026, calendar.July, 15))
  assert list.contains(dates, calendar.Date(2026, calendar.August, 15))
  assert !list.contains(dates, calendar.Date(2026, calendar.September, 15))
  Nil
}

pub fn monthly_bymonthday_timed_test() -> Nil {
  // 15th of each month at 10:00 ET.
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:monthly-timed\r\n"
    <> "SUMMARY:15th at 10am\r\n"
    <> "DTSTART;TZID=America/New_York:20260615T100000\r\n"
    <> "DTEND;TZID=America/New_York:20260615T110000\r\n"
    <> "RRULE:FREQ=MONTHLY;BYMONTHDAY=15\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = four_months()
  let dates = ical.parse_events(ical_text, "Cal", s, e) |> event_dates
  assert list.length(dates) == 4
  assert list.contains(dates, calendar.Date(2026, calendar.June, 15))
  assert list.contains(dates, calendar.Date(2026, calendar.July, 15))
  assert list.contains(dates, calendar.Date(2026, calendar.August, 15))
  assert list.contains(dates, calendar.Date(2026, calendar.September, 15))
  Nil
}

pub fn monthly_bymonthday_skips_invalid_dates_test() -> Nil {
  // BYMONTHDAY=31 should only occur in months with 31 days.
  // Jun (30), Jul (31), Aug (31), Sep (30) → 2 events (Jul, Aug).
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:monthly-31st\r\n"
    <> "SUMMARY:31st where possible\r\n"
    <> "DTSTART;VALUE=DATE:20260731\r\n"
    <> "DTEND;VALUE=DATE:20260801\r\n"
    <> "RRULE:FREQ=MONTHLY;BYMONTHDAY=31\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = four_months()
  let dates = ical.parse_events(ical_text, "Cal", s, e) |> event_dates
  assert list.length(dates) == 2
  assert list.contains(dates, calendar.Date(2026, calendar.July, 31))
  assert list.contains(dates, calendar.Date(2026, calendar.August, 31))
  assert !list.contains(dates, calendar.Date(2026, calendar.June, 30))
  assert !list.contains(dates, calendar.Date(2026, calendar.September, 30))
  Nil
}
