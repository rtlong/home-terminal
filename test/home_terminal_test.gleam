import cal.{AllDay, AtTime}
import gleam/list
import gleam/time/calendar
import gleam/time/duration
import gleam/time/timestamp
import gleeunit
import ical

pub fn main() -> Nil {
  gleeunit.main()
}

// Window covers the week of Sun 2026-06-14 00:00 ET to Sun 2026-06-21 00:00 ET
fn one_week_in_jun_2026() -> #(timestamp.Timestamp, timestamp.Timestamp) {
  let start = timestamp.from_unix_seconds(1_781_409_600)
  // 2026-06-14T00:00:00 ET (Sunday)
  let end_ = timestamp.from_unix_seconds(1_782_014_400)
  // 2026-06-21T00:00:00 ET (next Sunday)
  #(start, end_)
}

// 2-week window from Sun 2026-06-14 to Sun 2026-06-28
fn two_weeks_in_jun_2026() -> #(timestamp.Timestamp, timestamp.Timestamp) {
  let start = timestamp.from_unix_seconds(1_781_409_600)
  let end_ = timestamp.from_unix_seconds(1_782_619_200)
  #(start, end_)
}

// Decode an event start timestamp into a local-ET calendar date.
fn et_date(ts: timestamp.Timestamp) -> calendar.Date {
  // EDT in June is UTC-4
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

// REGRESSION: weekly RRULE with BYDAY=TU,TH only produced Tuesday instances.
// Now expects BOTH Tuesday and Thursday to be expanded each week.
pub fn weekly_byday_two_days_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:phoebe-puppy-school\r\n"
    <> "SUMMARY:Phoebe Puppy Daycare/School\r\n"
    <> "DTSTART;TZID=America/New_York:20260616T090000\r\n"
    <> "DTEND;TZID=America/New_York:20260616T150000\r\n"
    <> "RRULE:FREQ=WEEKLY;BYDAY=TU,TH\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(start, end_) = one_week_in_jun_2026()
  let events = ical.parse_events(ical_text, "Lucy", start, end_)

  // Expect Tue 06-16 and Thu 06-18
  let dates = event_dates(events)
  assert dates
    == [
      calendar.Date(2026, calendar.June, 16),
      calendar.Date(2026, calendar.June, 18),
    ]
  Nil
}

// Make sure plain weekly (no BYDAY) still emits exactly the DTSTART day.
pub fn weekly_without_byday_unchanged_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:weekly-no-byday\r\n"
    <> "SUMMARY:Weekly Standup\r\n"
    <> "DTSTART;TZID=America/New_York:20260616T100000\r\n"
    <> "DTEND;TZID=America/New_York:20260616T103000\r\n"
    <> "RRULE:FREQ=WEEKLY\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(start, end_) = two_weeks_in_jun_2026()
  let events = ical.parse_events(ical_text, "Work", start, end_)
  // Expect Tue 06-16 and Tue 06-23 only
  let dates = event_dates(events)
  assert dates
    == [
      calendar.Date(2026, calendar.June, 16),
      calendar.Date(2026, calendar.June, 23),
    ]
  Nil
}

// Multi-week BYDAY expansion across two weeks should produce 4 instances.
pub fn weekly_byday_multi_week_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:phoebe-puppy-school\r\n"
    <> "SUMMARY:Phoebe Puppy Daycare/School\r\n"
    <> "DTSTART;TZID=America/New_York:20260616T090000\r\n"
    <> "DTEND;TZID=America/New_York:20260616T150000\r\n"
    <> "RRULE:FREQ=WEEKLY;BYDAY=TU,TH\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(start, end_) = two_weeks_in_jun_2026()
  let events = ical.parse_events(ical_text, "Lucy", start, end_)
  let dates = event_dates(events)
  assert dates
    == [
      calendar.Date(2026, calendar.June, 16),
      calendar.Date(2026, calendar.June, 18),
      calendar.Date(2026, calendar.June, 23),
      calendar.Date(2026, calendar.June, 25),
    ]
  Nil
}

// BYDAY day-of-week ORDER independent (Th first, Tu second).
pub fn weekly_byday_order_independent_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:order-test\r\n"
    <> "SUMMARY:Order Test\r\n"
    <> "DTSTART;TZID=America/New_York:20260616T090000\r\n"
    <> "DTEND;TZID=America/New_York:20260616T100000\r\n"
    <> "RRULE:FREQ=WEEKLY;BYDAY=TH,TU\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(start, end_) = one_week_in_jun_2026()
  let events = ical.parse_events(ical_text, "Work", start, end_)
  let count = list.length(events)
  assert count == 2
  Nil
}

// BYDAY with INTERVAL=2 (biweekly) should skip every other week.
pub fn weekly_byday_biweekly_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:biweekly\r\n"
    <> "SUMMARY:Biweekly\r\n"
    <> "DTSTART;TZID=America/New_York:20260616T090000\r\n"
    <> "DTEND;TZID=America/New_York:20260616T100000\r\n"
    <> "RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,TH\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(start, end_) = two_weeks_in_jun_2026()
  let events = ical.parse_events(ical_text, "Work", start, end_)
  // Week 1 (containing DTSTART 06-16): Tu 06-16, Th 06-18
  // Week 2 (06-22..06-28) is SKIPPED because INTERVAL=2
  let dates = event_dates(events)
  assert dates
    == [
      calendar.Date(2026, calendar.June, 16),
      calendar.Date(2026, calendar.June, 18),
    ]
  Nil
}

// EXDATE on a BYDAY instance should suppress just that one occurrence.
pub fn weekly_byday_with_exdate_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:exdate-test\r\n"
    <> "SUMMARY:ExDate Test\r\n"
    <> "DTSTART;TZID=America/New_York:20260616T090000\r\n"
    <> "DTEND;TZID=America/New_York:20260616T100000\r\n"
    <> "RRULE:FREQ=WEEKLY;BYDAY=TU,TH\r\n"
    <> "EXDATE;TZID=America/New_York:20260618T090000\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(start, end_) = one_week_in_jun_2026()
  let events = ical.parse_events(ical_text, "Work", start, end_)
  // Thursday 06-18 is excluded → only Tue 06-16 remains
  let dates = event_dates(events)
  assert dates == [calendar.Date(2026, calendar.June, 16)]
  Nil
}

// All-day weekly+BYDAY recurrence should also expand correctly.
pub fn allday_weekly_byday_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:allday-byday\r\n"
    <> "SUMMARY:All Day BYDAY\r\n"
    <> "DTSTART;VALUE=DATE:20260616\r\n"
    <> "DTEND;VALUE=DATE:20260617\r\n"
    <> "RRULE:FREQ=WEEKLY;BYDAY=TU,TH\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(start, end_) = one_week_in_jun_2026()
  let events = ical.parse_events(ical_text, "Family", start, end_)
  let dates = event_dates(events)
  assert dates
    == [
      calendar.Date(2026, calendar.June, 16),
      calendar.Date(2026, calendar.June, 18),
    ]
  Nil
}

// Floating (no TZID) weekly+BYDAY should still expand correctly.
pub fn floating_weekly_byday_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:floating-byday\r\n"
    <> "SUMMARY:Floating BYDAY\r\n"
    <> "DTSTART:20260616T090000\r\n"
    <> "DTEND:20260616T100000\r\n"
    <> "RRULE:FREQ=WEEKLY;BYDAY=TU,TH\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(start, end_) = one_week_in_jun_2026()
  let events = ical.parse_events(ical_text, "Work", start, end_)
  let count = list.length(events)
  assert count == 2
  Nil
}
