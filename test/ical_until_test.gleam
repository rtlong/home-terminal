//// Tests for RFC 5545 §3.3.10 RECUR rule part: UNTIL.
////
//// Supported here:
////   * DATE form for all-day DTSTART
////   * UTC DATE-TIME form for timed DTSTART
////
//// UNTIL is inclusive: the last occurrence whose DTSTART is equal to UNTIL
//// is part of the recurrence set.

import cal.{AllDay, AtTime}
import gleam/list
import gleam/time/calendar
import gleam/time/duration
import gleam/time/timestamp
import ical

// 2-week window: Sun 2026-06-14 00:00 ET -> Sun 2026-06-28 00:00 ET
fn two_weeks() -> #(timestamp.Timestamp, timestamp.Timestamp) {
  #(
    timestamp.from_unix_seconds(1_781_409_600),
    timestamp.from_unix_seconds(1_782_619_200),
  )
}

// 4-week window: Sun 2026-06-14 00:00 ET -> Tue 2026-07-14 00:00 ET
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

pub fn allday_until_date_inclusive_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:until-allday\r\n"
    <> "SUMMARY:All Day Until\r\n"
    <> "DTSTART;VALUE=DATE:20260615\r\n"
    <> "DTEND;VALUE=DATE:20260616\r\n"
    <> "RRULE:FREQ=DAILY;UNTIL=20260617\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = two_weeks()
  let dates = ical.parse_events(ical_text, "Cal", s, e) |> event_dates
  assert list.length(dates) == 3
  assert list.contains(dates, calendar.Date(2026, calendar.June, 15))
  assert list.contains(dates, calendar.Date(2026, calendar.June, 16))
  assert list.contains(dates, calendar.Date(2026, calendar.June, 17))
  assert !list.contains(dates, calendar.Date(2026, calendar.June, 18))
  Nil
}

pub fn timed_until_utc_inclusive_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:until-timed-inclusive\r\n"
    <> "SUMMARY:Timed Until Inclusive\r\n"
    <> "DTSTART:20260615T130000Z\r\n"
    <> "DTEND:20260615T140000Z\r\n"
    <> "RRULE:FREQ=DAILY;UNTIL=20260617T130000Z\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = two_weeks()
  let dates = ical.parse_events(ical_text, "Cal", s, e) |> event_dates
  assert list.length(dates) == 3
  assert list.contains(dates, calendar.Date(2026, calendar.June, 15))
  assert list.contains(dates, calendar.Date(2026, calendar.June, 16))
  assert list.contains(dates, calendar.Date(2026, calendar.June, 17))
  Nil
}

pub fn timed_until_utc_excludes_later_same_day_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:until-timed-exclusive\r\n"
    <> "SUMMARY:Timed Until Exclusive\r\n"
    <> "DTSTART:20260615T130000Z\r\n"
    <> "DTEND:20260615T140000Z\r\n"
    <> "RRULE:FREQ=DAILY;UNTIL=20260617T125959Z\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = two_weeks()
  let dates = ical.parse_events(ical_text, "Cal", s, e) |> event_dates
  assert list.length(dates) == 2
  assert list.contains(dates, calendar.Date(2026, calendar.June, 15))
  assert list.contains(dates, calendar.Date(2026, calendar.June, 16))
  assert !list.contains(dates, calendar.Date(2026, calendar.June, 17))
  Nil
}

pub fn weekly_byday_until_midweek_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:until-byday\r\n"
    <> "SUMMARY:MWF Until Wednesday\r\n"
    <> "DTSTART;TZID=America/New_York:20260615T090000\r\n"
    <> "DTEND;TZID=America/New_York:20260615T100000\r\n"
    <> "RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR;UNTIL=20260624T130000Z\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = two_weeks()
  let dates = ical.parse_events(ical_text, "Cal", s, e) |> event_dates
  assert list.length(dates) == 5
  assert list.contains(dates, calendar.Date(2026, calendar.June, 15))
  assert list.contains(dates, calendar.Date(2026, calendar.June, 17))
  assert list.contains(dates, calendar.Date(2026, calendar.June, 19))
  assert list.contains(dates, calendar.Date(2026, calendar.June, 22))
  assert list.contains(dates, calendar.Date(2026, calendar.June, 24))
  assert !list.contains(dates, calendar.Date(2026, calendar.June, 26))
  Nil
}

pub fn until_with_interval_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:until-interval\r\n"
    <> "SUMMARY:Biweekly Until\r\n"
    <> "DTSTART:20260615T130000Z\r\n"
    <> "DTEND:20260615T140000Z\r\n"
    <> "RRULE:FREQ=WEEKLY;INTERVAL=2;UNTIL=20260629T130000Z\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = four_weeks()
  let dates = ical.parse_events(ical_text, "Cal", s, e) |> event_dates
  assert list.length(dates) == 2
  assert list.contains(dates, calendar.Date(2026, calendar.June, 15))
  assert list.contains(dates, calendar.Date(2026, calendar.June, 29))
  assert !list.contains(dates, calendar.Date(2026, calendar.July, 13))
  Nil
}

pub fn until_entirely_before_window_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:until-before-window\r\n"
    <> "SUMMARY:Before Window\r\n"
    <> "DTSTART;VALUE=DATE:20260601\r\n"
    <> "DTEND;VALUE=DATE:20260602\r\n"
    <> "RRULE:FREQ=DAILY;UNTIL=20260603\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = two_weeks()
  let events = ical.parse_events(ical_text, "Cal", s, e)
  assert events == []
  Nil
}
