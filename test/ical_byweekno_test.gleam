//// Tests for RFC 5545 §3.3.10 BYWEEKNO recurrence rule part.
////
//// BYWEEKNO specifies a list of ISO 8601 week numbers (1..53 or -53..-1).
//// Negative values count from the end of the year.
////
//// ISO 8601 (with WKST=Monday): week 1 contains January 4. A year has 53
//// weeks if Jan 1 is Thursday, or if Jan 1 is Wednesday in a leap year;
//// otherwise 52 weeks.
////
//// 2026 starts Thursday → 53 weeks.
//// 2027 starts Friday → 52 weeks.
////
//// Per RFC 5545: BYWEEKNO MUST NOT be specified with FREQ other than YEARLY.
//// We silently ignore it for non-YEARLY.
////
//// When BYWEEKNO is given without BYDAY, the day-of-week of DTSTART is used
//// to pick the day within each selected week.

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

pub fn yearly_byweekno_first_week_test() -> Nil {
  // FREQ=YEARLY;BYWEEKNO=1 with DTSTART=Thu Jan 1 2026.
  // Week 1 of 2026 = Mon Dec 29 2025 - Sun Jan 4 2026; Thursday = Jan 1 2026.
  // Week 1 of 2027 = Mon Jan 4 - Sun Jan 10 2027; Thursday = Jan 7 2027.
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:bwn-first\r\n"
    <> "SUMMARY:Week 1 Thursday\r\n"
    <> "DTSTART;VALUE=DATE:20260101\r\n"
    <> "DTEND;VALUE=DATE:20260102\r\n"
    <> "RRULE:FREQ=YEARLY;BYWEEKNO=1\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = two_years()
  let dates = ical.parse_events(ical_text, "Cal", s, e) |> event_dates
  assert list.length(dates) == 2
  assert list.contains(dates, calendar.Date(2026, calendar.January, 1))
  assert list.contains(dates, calendar.Date(2027, calendar.January, 7))
  Nil
}

pub fn yearly_byweekno_last_week_test() -> Nil {
  // FREQ=YEARLY;BYWEEKNO=-1 with DTSTART=Thu Dec 31 2026.
  // 2026 has 53 weeks (Jan 1 = Thu). Week 53 Mon = Dec 28; Thursday = Dec 31.
  // 2027 has 52 weeks (Jan 1 = Fri). Week 52 Mon = Dec 27; Thursday = Dec 30.
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:bwn-last\r\n"
    <> "SUMMARY:Last-week Thursday\r\n"
    <> "DTSTART;VALUE=DATE:20261231\r\n"
    <> "DTEND;VALUE=DATE:20270101\r\n"
    <> "RRULE:FREQ=YEARLY;BYWEEKNO=-1\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = two_years()
  let dates = ical.parse_events(ical_text, "Cal", s, e) |> event_dates
  assert list.length(dates) == 2
  assert list.contains(dates, calendar.Date(2026, calendar.December, 31))
  assert list.contains(dates, calendar.Date(2027, calendar.December, 30))
  Nil
}

pub fn yearly_byweekno_specific_test() -> Nil {
  // FREQ=YEARLY;BYWEEKNO=20 with DTSTART=Mon May 11 2026.
  // 2026 Week 20 Mon = Dec 29 2025 + 19*7 = May 11 2026.
  // 2027 Week 20 Mon = Jan 4 2027 + 19*7 = May 17 2027.
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:bwn-20\r\n"
    <> "SUMMARY:Week 20 Monday\r\n"
    <> "DTSTART;VALUE=DATE:20260511\r\n"
    <> "DTEND;VALUE=DATE:20260512\r\n"
    <> "RRULE:FREQ=YEARLY;BYWEEKNO=20\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = two_years()
  let dates = ical.parse_events(ical_text, "Cal", s, e) |> event_dates
  assert list.length(dates) == 2
  assert list.contains(dates, calendar.Date(2026, calendar.May, 11))
  assert list.contains(dates, calendar.Date(2027, calendar.May, 17))
  Nil
}

pub fn yearly_byweekno_multiple_test() -> Nil {
  // FREQ=YEARLY;BYWEEKNO=1,20,-1 with DTSTART=Thu Jan 1 2026.
  // Note: DTSTART's day-of-week (Thu) is used for all selected weeks.
  // 2026: Wk1 Thu = Jan 1, Wk20 Thu = May 14, Wk-1=Wk53 Thu = Dec 31.
  // 2027: Wk1 Thu = Jan 7, Wk20 Thu = May 20, Wk-1=Wk52 Thu = Dec 30.
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:bwn-multi\r\n"
    <> "SUMMARY:Multi-week\r\n"
    <> "DTSTART;VALUE=DATE:20260101\r\n"
    <> "DTEND;VALUE=DATE:20260102\r\n"
    <> "RRULE:FREQ=YEARLY;BYWEEKNO=1,20,-1\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = two_years()
  let dates = ical.parse_events(ical_text, "Cal", s, e) |> event_dates
  assert list.length(dates) == 6
  assert list.contains(dates, calendar.Date(2026, calendar.January, 1))
  assert list.contains(dates, calendar.Date(2026, calendar.May, 14))
  assert list.contains(dates, calendar.Date(2026, calendar.December, 31))
  assert list.contains(dates, calendar.Date(2027, calendar.January, 7))
  assert list.contains(dates, calendar.Date(2027, calendar.May, 20))
  assert list.contains(dates, calendar.Date(2027, calendar.December, 30))
  Nil
}

pub fn yearly_byweekno_53_skips_short_year_test() -> Nil {
  // BYWEEKNO=53 with DTSTART=Thu Dec 31 2026.
  // 2026 has 53 weeks → Thu Dec 31 2026 emitted.
  // 2027 has 52 weeks (no week 53) → no emission for 2027.
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:bwn-53\r\n"
    <> "SUMMARY:Week 53 Thursday\r\n"
    <> "DTSTART;VALUE=DATE:20261231\r\n"
    <> "DTEND;VALUE=DATE:20270101\r\n"
    <> "RRULE:FREQ=YEARLY;BYWEEKNO=53\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = two_years()
  let dates = ical.parse_events(ical_text, "Cal", s, e) |> event_dates
  assert list.length(dates) == 1
  assert list.contains(dates, calendar.Date(2026, calendar.December, 31))
  assert !list.contains(dates, calendar.Date(2027, calendar.December, 30))
  Nil
}

pub fn byweekno_invalid_values_dropped_test() -> Nil {
  // BYWEEKNO=0,54,-54 invalid; only 20 retained.
  // Same expected dates as yearly_byweekno_specific_test.
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:bwn-invalid\r\n"
    <> "SUMMARY:Week 20\r\n"
    <> "DTSTART;VALUE=DATE:20260511\r\n"
    <> "DTEND;VALUE=DATE:20260512\r\n"
    <> "RRULE:FREQ=YEARLY;BYWEEKNO=0,20,54,-54\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = two_years()
  let dates = ical.parse_events(ical_text, "Cal", s, e) |> event_dates
  assert list.length(dates) == 2
  assert list.contains(dates, calendar.Date(2026, calendar.May, 11))
  assert list.contains(dates, calendar.Date(2027, calendar.May, 17))
  Nil
}

pub fn byweekno_with_non_yearly_ignored_test() -> Nil {
  // Per RFC: BYWEEKNO MUST NOT be specified with FREQ other than YEARLY.
  // FREQ=MONTHLY with BYWEEKNO=20 → ignore BYWEEKNO, emit DTSTART monthly.
  // DTSTART=Mon May 11 2026, FREQ=MONTHLY, window Jan 1 2026 – Jan 1 2028.
  // Pre-DTSTART months are not emitted, so:
  //   May–Dec 2026 (8) + Jan–Dec 2027 (12) = 20 events.
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:bwn-monthly\r\n"
    <> "SUMMARY:11th\r\n"
    <> "DTSTART;VALUE=DATE:20260511\r\n"
    <> "DTEND;VALUE=DATE:20260512\r\n"
    <> "RRULE:FREQ=MONTHLY;BYWEEKNO=20\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = two_years()
  let dates = ical.parse_events(ical_text, "Cal", s, e) |> event_dates
  assert list.length(dates) == 20
  assert list.contains(dates, calendar.Date(2026, calendar.May, 11))
  assert list.contains(dates, calendar.Date(2026, calendar.December, 11))
  assert list.contains(dates, calendar.Date(2027, calendar.January, 11))
  assert list.contains(dates, calendar.Date(2027, calendar.December, 11))
  Nil
}
