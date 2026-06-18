//// Tests for RFC 5545 §3.3.10 BYDAY with positional prefix in FREQ=MONTHLY
//// recurrence rules.
////
//// Each BYDAY entry MAY carry a numeric positional prefix (e.g. "1MO" = first
//// Monday of the month, "-1FR" = last Friday). When FREQ=MONTHLY:
////   * positive N: the Nth occurrence of that weekday within the month
////   * negative N: the Nth-from-last occurrence
////   * unprefixed: every occurrence of that weekday in the month
////
//// For FREQ=WEEKLY the prefix MUST be ignored (a weekly rule has no concept
//// of "the Nth Monday of the week"). The existing weekly behavior is
//// preserved as a regression check.

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

// 2-week window: Sun 2026-06-14 00:00 ET -> Sun 2026-06-28 00:00 ET
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

pub fn monthly_byday_first_monday_test() -> Nil {
  // 1st Monday of each month, starting Mon 2026-06-01:
  //   Jun 1, Jul 6, Aug 3, Sep 7.
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:monthly-first-mon\r\n"
    <> "SUMMARY:First Monday\r\n"
    <> "DTSTART;VALUE=DATE:20260601\r\n"
    <> "DTEND;VALUE=DATE:20260602\r\n"
    <> "RRULE:FREQ=MONTHLY;BYDAY=1MO\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = four_months()
  let dates = ical.parse_events(ical_text, "Cal", s, e) |> event_dates
  assert list.length(dates) == 4
  assert list.contains(dates, calendar.Date(2026, calendar.June, 1))
  assert list.contains(dates, calendar.Date(2026, calendar.July, 6))
  assert list.contains(dates, calendar.Date(2026, calendar.August, 3))
  assert list.contains(dates, calendar.Date(2026, calendar.September, 7))
  Nil
}

pub fn monthly_byday_last_friday_test() -> Nil {
  // Last Friday of each month starting Fri 2026-06-26:
  //   Jun 26, Jul 31, Aug 28, Sep 25.
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:monthly-last-fri\r\n"
    <> "SUMMARY:Last Friday\r\n"
    <> "DTSTART;VALUE=DATE:20260626\r\n"
    <> "DTEND;VALUE=DATE:20260627\r\n"
    <> "RRULE:FREQ=MONTHLY;BYDAY=-1FR\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = four_months()
  let dates = ical.parse_events(ical_text, "Cal", s, e) |> event_dates
  assert list.length(dates) == 4
  assert list.contains(dates, calendar.Date(2026, calendar.June, 26))
  assert list.contains(dates, calendar.Date(2026, calendar.July, 31))
  assert list.contains(dates, calendar.Date(2026, calendar.August, 28))
  assert list.contains(dates, calendar.Date(2026, calendar.September, 25))
  Nil
}

pub fn monthly_byday_second_wednesday_test() -> Nil {
  // 2nd Wednesday: Jun 10, Jul 8, Aug 12, Sep 9.
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:monthly-2nd-wed\r\n"
    <> "SUMMARY:Second Wednesday\r\n"
    <> "DTSTART;VALUE=DATE:20260610\r\n"
    <> "DTEND;VALUE=DATE:20260611\r\n"
    <> "RRULE:FREQ=MONTHLY;BYDAY=2WE\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = four_months()
  let dates = ical.parse_events(ical_text, "Cal", s, e) |> event_dates
  assert list.length(dates) == 4
  assert list.contains(dates, calendar.Date(2026, calendar.June, 10))
  assert list.contains(dates, calendar.Date(2026, calendar.July, 8))
  assert list.contains(dates, calendar.Date(2026, calendar.August, 12))
  assert list.contains(dates, calendar.Date(2026, calendar.September, 9))
  Nil
}

pub fn monthly_byday_multi_test() -> Nil {
  // First Monday AND last Friday each month: 8 events across 4 months.
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:monthly-multi\r\n"
    <> "SUMMARY:First Mon + Last Fri\r\n"
    <> "DTSTART;VALUE=DATE:20260601\r\n"
    <> "DTEND;VALUE=DATE:20260602\r\n"
    <> "RRULE:FREQ=MONTHLY;BYDAY=1MO,-1FR\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = four_months()
  let dates = ical.parse_events(ical_text, "Cal", s, e) |> event_dates
  assert list.length(dates) == 8
  assert list.contains(dates, calendar.Date(2026, calendar.June, 1))
  assert list.contains(dates, calendar.Date(2026, calendar.June, 26))
  assert list.contains(dates, calendar.Date(2026, calendar.July, 6))
  assert list.contains(dates, calendar.Date(2026, calendar.July, 31))
  assert list.contains(dates, calendar.Date(2026, calendar.August, 3))
  assert list.contains(dates, calendar.Date(2026, calendar.August, 28))
  assert list.contains(dates, calendar.Date(2026, calendar.September, 7))
  assert list.contains(dates, calendar.Date(2026, calendar.September, 25))
  Nil
}

pub fn monthly_byday_with_count_test() -> Nil {
  // COUNT=3 → only the first 3 first-Mondays.
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:monthly-count\r\n"
    <> "SUMMARY:First Monday (COUNT=3)\r\n"
    <> "DTSTART;VALUE=DATE:20260601\r\n"
    <> "DTEND;VALUE=DATE:20260602\r\n"
    <> "RRULE:FREQ=MONTHLY;BYDAY=1MO;COUNT=3\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = four_months()
  let dates = ical.parse_events(ical_text, "Cal", s, e) |> event_dates
  assert list.length(dates) == 3
  assert list.contains(dates, calendar.Date(2026, calendar.June, 1))
  assert list.contains(dates, calendar.Date(2026, calendar.July, 6))
  assert list.contains(dates, calendar.Date(2026, calendar.August, 3))
  assert !list.contains(dates, calendar.Date(2026, calendar.September, 7))
  Nil
}

pub fn monthly_byday_with_until_test() -> Nil {
  // UNTIL=20260901 (Sep 1) → Sep 7 (1st Mon of Sep) is past UNTIL, dropped.
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:monthly-until\r\n"
    <> "SUMMARY:First Monday (UNTIL=Sep 1)\r\n"
    <> "DTSTART;VALUE=DATE:20260601\r\n"
    <> "DTEND;VALUE=DATE:20260602\r\n"
    <> "RRULE:FREQ=MONTHLY;BYDAY=1MO;UNTIL=20260901\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = four_months()
  let dates = ical.parse_events(ical_text, "Cal", s, e) |> event_dates
  assert list.length(dates) == 3
  assert list.contains(dates, calendar.Date(2026, calendar.June, 1))
  assert list.contains(dates, calendar.Date(2026, calendar.July, 6))
  assert list.contains(dates, calendar.Date(2026, calendar.August, 3))
  assert !list.contains(dates, calendar.Date(2026, calendar.September, 7))
  Nil
}

pub fn monthly_byday_timed_test() -> Nil {
  // 2nd Tuesday of each month at 10:00 ET.
  // DTSTART = 2nd Tue of June = Jun 9, 2026 (Mon Jun 1, Tue Jun 2, Tue Jun 9).
  // 2nd Tues: Jul 14, Aug 11, Sep 8.
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:monthly-timed\r\n"
    <> "SUMMARY:Second Tuesday 10am\r\n"
    <> "DTSTART;TZID=America/New_York:20260609T100000\r\n"
    <> "DTEND;TZID=America/New_York:20260609T110000\r\n"
    <> "RRULE:FREQ=MONTHLY;BYDAY=2TU\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = four_months()
  let dates = ical.parse_events(ical_text, "Cal", s, e) |> event_dates
  assert list.length(dates) == 4
  assert list.contains(dates, calendar.Date(2026, calendar.June, 9))
  assert list.contains(dates, calendar.Date(2026, calendar.July, 14))
  assert list.contains(dates, calendar.Date(2026, calendar.August, 11))
  assert list.contains(dates, calendar.Date(2026, calendar.September, 8))
  Nil
}

pub fn weekly_byday_with_prefix_ignored_test() -> Nil {
  // For FREQ=WEEKLY the positional prefix MUST be ignored. BYDAY=1MO behaves
  // as BYDAY=MO. DTSTART=Mon 2026-06-15, 2-week window: Jun 15, Jun 22.
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:weekly-prefix-ignored\r\n"
    <> "SUMMARY:Weekly with bogus prefix\r\n"
    <> "DTSTART;VALUE=DATE:20260615\r\n"
    <> "DTEND;VALUE=DATE:20260616\r\n"
    <> "RRULE:FREQ=WEEKLY;BYDAY=1MO\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = two_weeks()
  let dates = ical.parse_events(ical_text, "Cal", s, e) |> event_dates
  assert list.length(dates) == 2
  assert list.contains(dates, calendar.Date(2026, calendar.June, 15))
  assert list.contains(dates, calendar.Date(2026, calendar.June, 22))
  Nil
}
