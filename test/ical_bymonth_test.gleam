//// Tests for RFC 5545 §3.3.10 BYMONTH recurrence rule part.
////
//// BYMONTH specifies a list of months (1..12) to expand or limit the
//// recurrence set:
////   * FREQ=YEARLY: BYMONTH expands — emit one candidate per BYMONTH
////     month per year (intersected with BYDAY/BYMONTHDAY if present).
////   * FREQ=MONTHLY: BYMONTH limits — only iterations whose month is in
////     the BYMONTH list are emitted.
////   * FREQ=WEEKLY/DAILY: BYMONTH limits each candidate by month.
////
//// Common real-world use cases include holidays
//// (FREQ=YEARLY;BYMONTH=11;BYDAY=4TH for US Thanksgiving) and quarterly
//// reminders (FREQ=YEARLY;BYMONTH=3,6,9,12).

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

pub fn yearly_bymonth_single_month_test() -> Nil {
  // FREQ=YEARLY;BYMONTH=11 with DTSTART=Nov 26 → emit Nov 26 each year.
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:by-yearly-bymonth-11\r\n"
    <> "SUMMARY:Anniversary in November\r\n"
    <> "DTSTART;VALUE=DATE:20261126\r\n"
    <> "DTEND;VALUE=DATE:20261127\r\n"
    <> "RRULE:FREQ=YEARLY;BYMONTH=11\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = two_years()
  let dates = ical.parse_events(ical_text, "Cal", s, e) |> event_dates
  assert list.length(dates) == 2
  assert list.contains(dates, calendar.Date(2026, calendar.November, 26))
  assert list.contains(dates, calendar.Date(2027, calendar.November, 26))
  Nil
}

pub fn yearly_bymonth_multiple_months_test() -> Nil {
  // FREQ=YEARLY;BYMONTH=3,6,9,12 → quarterly events on DTSTART's day.
  // DTSTART = March 15, so emit Mar 15, Jun 15, Sep 15, Dec 15 each year.
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:by-yearly-quarterly\r\n"
    <> "SUMMARY:Quarterly check-in\r\n"
    <> "DTSTART;VALUE=DATE:20260315\r\n"
    <> "DTEND;VALUE=DATE:20260316\r\n"
    <> "RRULE:FREQ=YEARLY;BYMONTH=3,6,9,12\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = two_years()
  let dates = ical.parse_events(ical_text, "Cal", s, e) |> event_dates
  // 2 years × 4 months = 8 events
  assert list.length(dates) == 8
  assert list.contains(dates, calendar.Date(2026, calendar.March, 15))
  assert list.contains(dates, calendar.Date(2026, calendar.June, 15))
  assert list.contains(dates, calendar.Date(2026, calendar.September, 15))
  assert list.contains(dates, calendar.Date(2026, calendar.December, 15))
  assert list.contains(dates, calendar.Date(2027, calendar.March, 15))
  assert list.contains(dates, calendar.Date(2027, calendar.June, 15))
  assert list.contains(dates, calendar.Date(2027, calendar.September, 15))
  assert list.contains(dates, calendar.Date(2027, calendar.December, 15))
  Nil
}

pub fn yearly_bymonth_byday_thanksgiving_test() -> Nil {
  // 4th Thursday of November every year — US Thanksgiving.
  // Nov 26 2026 (Thu, 4th Thursday); Nov 25 2027 (4th Thursday).
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:thanksgiving\r\n"
    <> "SUMMARY:Thanksgiving\r\n"
    <> "DTSTART;VALUE=DATE:20261126\r\n"
    <> "DTEND;VALUE=DATE:20261127\r\n"
    <> "RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=4TH\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = two_years()
  let dates = ical.parse_events(ical_text, "Cal", s, e) |> event_dates
  assert list.length(dates) == 2
  assert list.contains(dates, calendar.Date(2026, calendar.November, 26))
  assert list.contains(dates, calendar.Date(2027, calendar.November, 25))
  Nil
}

pub fn yearly_no_bymonth_unchanged_test() -> Nil {
  // Without BYMONTH, FREQ=YEARLY emits one event per year on DTSTART's date.
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:by-yearly-anniv\r\n"
    <> "SUMMARY:Anniversary\r\n"
    <> "DTSTART;VALUE=DATE:20260415\r\n"
    <> "DTEND;VALUE=DATE:20260416\r\n"
    <> "RRULE:FREQ=YEARLY\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = two_years()
  let dates = ical.parse_events(ical_text, "Cal", s, e) |> event_dates
  assert list.length(dates) == 2
  assert list.contains(dates, calendar.Date(2026, calendar.April, 15))
  assert list.contains(dates, calendar.Date(2027, calendar.April, 15))
  Nil
}

pub fn monthly_bymonth_limits_iterations_test() -> Nil {
  // FREQ=MONTHLY;BYMONTH=1,7 with DTSTART=Jan 15 → Jan and Jul each year.
  // Window: 2 years. Expect Jan 15 2026, Jul 15 2026, Jan 15 2027, Jul 15 2027.
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:by-monthly-bymonth\r\n"
    <> "SUMMARY:Twice-yearly\r\n"
    <> "DTSTART;VALUE=DATE:20260115\r\n"
    <> "DTEND;VALUE=DATE:20260116\r\n"
    <> "RRULE:FREQ=MONTHLY;BYMONTH=1,7\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = two_years()
  let dates = ical.parse_events(ical_text, "Cal", s, e) |> event_dates
  assert list.length(dates) == 4
  assert list.contains(dates, calendar.Date(2026, calendar.January, 15))
  assert list.contains(dates, calendar.Date(2026, calendar.July, 15))
  assert list.contains(dates, calendar.Date(2027, calendar.January, 15))
  assert list.contains(dates, calendar.Date(2027, calendar.July, 15))
  // Should NOT contain other months
  assert !list.contains(dates, calendar.Date(2026, calendar.February, 15))
  assert !list.contains(dates, calendar.Date(2026, calendar.June, 15))
  Nil
}

pub fn bymonth_invalid_values_dropped_test() -> Nil {
  // BYMONTH=13 (invalid) should be dropped; valid values (e.g., 6) honored.
  // With BYMONTH=6,13 + DTSTART=Jun 15 → emit Jun 15 each year.
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:by-bymonth-invalid\r\n"
    <> "SUMMARY:Mid-year\r\n"
    <> "DTSTART;VALUE=DATE:20260615\r\n"
    <> "DTEND;VALUE=DATE:20260616\r\n"
    <> "RRULE:FREQ=YEARLY;BYMONTH=6,13\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = two_years()
  let dates = ical.parse_events(ical_text, "Cal", s, e) |> event_dates
  assert list.length(dates) == 2
  assert list.contains(dates, calendar.Date(2026, calendar.June, 15))
  assert list.contains(dates, calendar.Date(2027, calendar.June, 15))
  Nil
}
