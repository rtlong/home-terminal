//// Tests for RFC 5545 §3.3.10 RECUR rule part: COUNT.
////
//// COUNT bounds the recurrence set to N occurrences. DTSTART always counts
//// as the first occurrence. EXDATE removes instances *after* COUNT applies
//// (so a COUNT=5 rule with one EXDATE yields at most 4 emitted events).

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

// FREQ=DAILY;COUNT=3 emits exactly DTSTART, DTSTART+1, DTSTART+2.
pub fn daily_count_3_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:daily-count-3\r\n"
    <> "SUMMARY:Daily 3\r\n"
    <> "DTSTART;VALUE=DATE:20260615\r\n"
    <> "DTEND;VALUE=DATE:20260616\r\n"
    <> "RRULE:FREQ=DAILY;COUNT=3\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = two_weeks()
  let events = ical.parse_events(ical_text, "Cal", s, e)
  let dates = event_dates(events)
  assert list.length(dates) == 3
  assert list.contains(dates, calendar.Date(2026, calendar.June, 15))
  assert list.contains(dates, calendar.Date(2026, calendar.June, 16))
  assert list.contains(dates, calendar.Date(2026, calendar.June, 17))
  Nil
}

// FREQ=WEEKLY;COUNT=4 timed event: emit 4 weekly instances.
pub fn weekly_count_4_timed_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:weekly-count-4\r\n"
    <> "SUMMARY:Weekly 4\r\n"
    <> "DTSTART;TZID=America/New_York:20260615T100000\r\n"
    <> "DTEND;TZID=America/New_York:20260615T110000\r\n"
    <> "RRULE:FREQ=WEEKLY;COUNT=4\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = four_weeks()
  let events = ical.parse_events(ical_text, "Cal", s, e)
  let dates = event_dates(events)
  // 06-15, 06-22, 06-29, 07-06 — all within 4-week window ending 07-12.
  assert list.length(dates) == 4
  assert list.contains(dates, calendar.Date(2026, calendar.June, 15))
  assert list.contains(dates, calendar.Date(2026, calendar.June, 22))
  assert list.contains(dates, calendar.Date(2026, calendar.June, 29))
  assert list.contains(dates, calendar.Date(2026, calendar.July, 6))
  Nil
}

// COUNT=1 → DTSTART only.
pub fn count_1_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:count-1\r\n"
    <> "SUMMARY:Just Once\r\n"
    <> "DTSTART;VALUE=DATE:20260615\r\n"
    <> "DTEND;VALUE=DATE:20260616\r\n"
    <> "RRULE:FREQ=DAILY;COUNT=1\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = two_weeks()
  let events = ical.parse_events(ical_text, "Cal", s, e)
  let dates = event_dates(events)
  assert list.length(dates) == 1
  assert list.contains(dates, calendar.Date(2026, calendar.June, 15))
  Nil
}

// WEEKLY+BYDAY+COUNT: counts individual occurrences, not weeks.
// MO 06-15, WE 06-17, FR 06-19, MO 06-22, WE 06-24 (stop after 5).
pub fn weekly_byday_count_5_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:wkbyday-count-5\r\n"
    <> "SUMMARY:MWF x5\r\n"
    <> "DTSTART;TZID=America/New_York:20260615T090000\r\n"
    <> "DTEND;TZID=America/New_York:20260615T100000\r\n"
    <> "RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR;COUNT=5\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = two_weeks()
  let events = ical.parse_events(ical_text, "Cal", s, e)
  let dates = event_dates(events)
  assert list.length(dates) == 5
  assert list.contains(dates, calendar.Date(2026, calendar.June, 15))
  assert list.contains(dates, calendar.Date(2026, calendar.June, 17))
  assert list.contains(dates, calendar.Date(2026, calendar.June, 19))
  assert list.contains(dates, calendar.Date(2026, calendar.June, 22))
  assert list.contains(dates, calendar.Date(2026, calendar.June, 24))
  // Friday 06-26 must NOT appear (would be the 6th occurrence).
  assert !list.contains(dates, calendar.Date(2026, calendar.June, 26))
  Nil
}

// INTERVAL+COUNT: bi-weekly COUNT=2 → exactly 2 instances, 2 weeks apart.
// Without COUNT, an unbounded WEEKLY;INTERVAL=2 in a 4-week window would emit
// 3 instances (06-15, 06-29, 07-13); COUNT=2 must cap to 2.
pub fn count_with_interval_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:biweekly-count-2\r\n"
    <> "SUMMARY:BiWeekly 2\r\n"
    <> "DTSTART;TZID=America/New_York:20260615T100000\r\n"
    <> "DTEND;TZID=America/New_York:20260615T110000\r\n"
    <> "RRULE:FREQ=WEEKLY;INTERVAL=2;COUNT=2\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = four_weeks()
  let events = ical.parse_events(ical_text, "Cal", s, e)
  let dates = event_dates(events)
  assert list.length(dates) == 2
  assert list.contains(dates, calendar.Date(2026, calendar.June, 15))
  assert list.contains(dates, calendar.Date(2026, calendar.June, 29))
  // 07-13 would be the 3rd biweekly instance; COUNT=2 must exclude it.
  assert !list.contains(dates, calendar.Date(2026, calendar.July, 13))
  Nil
}

// COUNT then EXDATE: COUNT bounds the RRULE-generated set; EXDATE then removes
// matching instances. Daily COUNT=5 with one EXDATE → 4 emitted events.
pub fn count_then_exdate_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:count-exdate\r\n"
    <> "SUMMARY:Daily 5 -1\r\n"
    <> "DTSTART;VALUE=DATE:20260615\r\n"
    <> "DTEND;VALUE=DATE:20260616\r\n"
    <> "RRULE:FREQ=DAILY;COUNT=5\r\n"
    <> "EXDATE;VALUE=DATE:20260616\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = two_weeks()
  let events = ical.parse_events(ical_text, "Cal", s, e)
  let dates = event_dates(events)
  // 06-15, 06-17, 06-18, 06-19 (06-16 excluded by EXDATE).
  // The 6th day (06-20) must NOT appear: COUNT bounded at 5.
  assert list.length(dates) == 4
  assert list.contains(dates, calendar.Date(2026, calendar.June, 15))
  assert !list.contains(dates, calendar.Date(2026, calendar.June, 16))
  assert list.contains(dates, calendar.Date(2026, calendar.June, 17))
  assert list.contains(dates, calendar.Date(2026, calendar.June, 18))
  assert list.contains(dates, calendar.Date(2026, calendar.June, 19))
  assert !list.contains(dates, calendar.Date(2026, calendar.June, 20))
  Nil
}

// COUNT terminates expansion before window end. Daily COUNT=2 leaves 2 events,
// not 13.
pub fn count_terminates_before_window_end_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:count-2-stop\r\n"
    <> "SUMMARY:Stops Early\r\n"
    <> "DTSTART;VALUE=DATE:20260615\r\n"
    <> "DTEND;VALUE=DATE:20260616\r\n"
    <> "RRULE:FREQ=DAILY;COUNT=2\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = two_weeks()
  let events = ical.parse_events(ical_text, "Cal", s, e)
  let dates = event_dates(events)
  assert list.length(dates) == 2
  assert list.contains(dates, calendar.Date(2026, calendar.June, 15))
  assert list.contains(dates, calendar.Date(2026, calendar.June, 16))
  Nil
}

// All COUNT'd instances precede the window → no output.
pub fn count_entirely_before_window_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:count-before\r\n"
    <> "SUMMARY:Before window\r\n"
    <> "DTSTART;VALUE=DATE:20260601\r\n"
    <> "DTEND;VALUE=DATE:20260602\r\n"
    <> "RRULE:FREQ=DAILY;COUNT=3\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = two_weeks()
  let events = ical.parse_events(ical_text, "Cal", s, e)
  assert events == []
  Nil
}

// COUNT with WEEKLY+BYDAY where some BYDAY days in the first week fall
// BEFORE DTSTART must not be counted as occurrences. DTSTART is Wed 06-17,
// BYDAY=MO,WE,FR, COUNT=4. Phantom MO 06-15 must not consume a slot:
// expected emissions are WE 06-17, FR 06-19, MO 06-22, WE 06-24.
pub fn count_first_week_skips_pre_dtstart_byday_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:count-byday-first-week\r\n"
    <> "SUMMARY:MWF starting Wed\r\n"
    <> "DTSTART;TZID=America/New_York:20260617T100000\r\n"
    <> "DTEND;TZID=America/New_York:20260617T110000\r\n"
    <> "RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR;COUNT=4\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = two_weeks()
  let events = ical.parse_events(ical_text, "Cal", s, e)
  let dates = event_dates(events)
  assert list.length(dates) == 4
  assert list.contains(dates, calendar.Date(2026, calendar.June, 17))
  assert list.contains(dates, calendar.Date(2026, calendar.June, 19))
  assert list.contains(dates, calendar.Date(2026, calendar.June, 22))
  assert list.contains(dates, calendar.Date(2026, calendar.June, 24))
  // Friday 06-26 must NOT be the 5th, AND Mon 06-15 must NOT appear.
  assert !list.contains(dates, calendar.Date(2026, calendar.June, 15))
  assert !list.contains(dates, calendar.Date(2026, calendar.June, 26))
  Nil
}
