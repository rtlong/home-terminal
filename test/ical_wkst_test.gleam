//// Tests for RFC 5545 §3.3.10 WKST (Week Start) recurrence rule part.
////
//// WKST specifies which day starts the workweek. Default is MO. WKST is
//// significant only when:
////   * FREQ=WEEKLY with INTERVAL > 1 and BYDAY (different weeks have
////     different sets of "weekday" candidates depending on where the week
////     boundary falls), or
////   * FREQ=YEARLY with BYWEEKNO (week numbering depends on WKST).
////
//// For the WEEKLY+BYDAY case, candidates within each iteration are emitted
//// in chronological order regardless of BYDAY list order.

import cal.{AllDay, AtTime}
import gleam/list
import gleam/time/calendar
import gleam/time/duration
import gleam/time/timestamp
import ical

// Window: Sun 2026-06-14 00:00 ET -> Sun 2026-08-09 00:00 ET (8 weeks)
fn eight_weeks() -> #(timestamp.Timestamp, timestamp.Timestamp) {
  #(
    timestamp.from_unix_seconds(1_781_409_600),
    timestamp.from_unix_seconds(1_786_233_600),
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

pub fn wkst_default_is_monday_test() -> Nil {
  // No WKST → defaults to MO. With INTERVAL=2 and BYDAY=TU,SU and DTSTART=Tue,
  // both TU and SU should fall in the same MO-week (MO=Jun 15..SU=Jun 21),
  // then skip a week, then TU=Jun 30, SU=Jul 5.
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:wkst-default\r\n"
    <> "SUMMARY:Default WKST\r\n"
    <> "DTSTART;VALUE=DATE:20260616\r\n"
    <> "DTEND;VALUE=DATE:20260617\r\n"
    <> "RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,SU\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = eight_weeks()
  let dates = ical.parse_events(ical_text, "Cal", s, e) |> event_dates
  // MO-weeks containing Jun 16: Jun 15-21, then skip, Jun 29-Jul 5, skip, Jul 13-19, skip, Jul 27-Aug 2
  // TU,SU dates: Jun 16, Jun 21, Jun 30, Jul 5, Jul 14, Jul 19, Jul 28, Aug 2
  assert list.length(dates) == 8
  assert list.contains(dates, calendar.Date(2026, calendar.June, 16))
  assert list.contains(dates, calendar.Date(2026, calendar.June, 21))
  assert list.contains(dates, calendar.Date(2026, calendar.June, 30))
  assert list.contains(dates, calendar.Date(2026, calendar.July, 5))
  assert list.contains(dates, calendar.Date(2026, calendar.July, 14))
  assert list.contains(dates, calendar.Date(2026, calendar.July, 19))
  assert list.contains(dates, calendar.Date(2026, calendar.July, 28))
  assert list.contains(dates, calendar.Date(2026, calendar.August, 2))
  Nil
}

pub fn wkst_sunday_interval_2_test() -> Nil {
  // WKST=SU with INTERVAL=2 and BYDAY=TU,SU and DTSTART=Tue Jun 16:
  // SU-week containing Jun 16 is Jun 14 (Sun)..Jun 20 (Sat).
  //   - SU=Jun 14 is BEFORE DTSTART → dropped
  //   - TU=Jun 16 → emit
  // Skip week (interval=2). Next SU-week = Jun 28..Jul 4.
  //   - SU=Jun 28, TU=Jun 30 → emit (sorted)
  // Skip week. Next SU-week = Jul 12..Jul 18.
  //   - SU=Jul 12, TU=Jul 14 → emit
  // Skip week. Next SU-week = Jul 26..Aug 1.
  //   - SU=Jul 26, TU=Jul 28 → emit
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:wkst-sunday\r\n"
    <> "SUMMARY:WKST Sunday\r\n"
    <> "DTSTART;VALUE=DATE:20260616\r\n"
    <> "DTEND;VALUE=DATE:20260617\r\n"
    <> "RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,SU;WKST=SU\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = eight_weeks()
  let dates = ical.parse_events(ical_text, "Cal", s, e) |> event_dates
  assert list.length(dates) == 7
  assert list.contains(dates, calendar.Date(2026, calendar.June, 16))
  assert list.contains(dates, calendar.Date(2026, calendar.June, 28))
  assert list.contains(dates, calendar.Date(2026, calendar.June, 30))
  assert list.contains(dates, calendar.Date(2026, calendar.July, 12))
  assert list.contains(dates, calendar.Date(2026, calendar.July, 14))
  assert list.contains(dates, calendar.Date(2026, calendar.July, 26))
  assert list.contains(dates, calendar.Date(2026, calendar.July, 28))
  // Should NOT contain SU=Jun 14 (before DTSTART)
  assert !list.contains(dates, calendar.Date(2026, calendar.June, 14))
  Nil
}

pub fn wkst_explicit_monday_matches_default_test() -> Nil {
  // Explicit WKST=MO must match default (no WKST) behavior.
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:wkst-mo\r\n"
    <> "SUMMARY:Explicit Monday\r\n"
    <> "DTSTART;VALUE=DATE:20260616\r\n"
    <> "DTEND;VALUE=DATE:20260617\r\n"
    <> "RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,SU;WKST=MO\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = eight_weeks()
  let dates = ical.parse_events(ical_text, "Cal", s, e) |> event_dates
  assert list.length(dates) == 8
  assert list.contains(dates, calendar.Date(2026, calendar.June, 16))
  assert list.contains(dates, calendar.Date(2026, calendar.June, 21))
  Nil
}

pub fn wkst_interval_1_unaffected_test() -> Nil {
  // WKST has no observable effect when INTERVAL=1: every weekday occurs each
  // week regardless of where the week boundary falls.
  let ical_mo =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:wkst-i1-mo\r\n"
    <> "SUMMARY:I1 Mon\r\n"
    <> "DTSTART;VALUE=DATE:20260616\r\n"
    <> "DTEND;VALUE=DATE:20260617\r\n"
    <> "RRULE:FREQ=WEEKLY;INTERVAL=1;BYDAY=TU,SU;WKST=MO\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"
  let ical_su =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:wkst-i1-su\r\n"
    <> "SUMMARY:I1 Sun\r\n"
    <> "DTSTART;VALUE=DATE:20260616\r\n"
    <> "DTEND;VALUE=DATE:20260617\r\n"
    <> "RRULE:FREQ=WEEKLY;INTERVAL=1;BYDAY=TU,SU;WKST=SU\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = two_weeks()
  let dates_mo = ical.parse_events(ical_mo, "Cal", s, e) |> event_dates
  let dates_su = ical.parse_events(ical_su, "Cal", s, e) |> event_dates
  // Both should produce the same set of dates (just possibly different order)
  // Window: Jun 14 → Jun 28. Tuesdays: Jun 16, 23. Sundays: Jun 21.
  // (Jun 14 SU is before DTSTART Jun 16, dropped; Jun 28 SU is at window end, dropped.)
  assert list.length(dates_mo) == 3
  assert list.length(dates_su) == 3
  assert list.contains(dates_mo, calendar.Date(2026, calendar.June, 16))
  assert list.contains(dates_mo, calendar.Date(2026, calendar.June, 21))
  assert list.contains(dates_mo, calendar.Date(2026, calendar.June, 23))
  assert list.contains(dates_su, calendar.Date(2026, calendar.June, 16))
  assert list.contains(dates_su, calendar.Date(2026, calendar.June, 21))
  assert list.contains(dates_su, calendar.Date(2026, calendar.June, 23))
  Nil
}

pub fn wkst_byday_order_does_not_affect_output_order_test() -> Nil {
  // Within a week, candidates must be emitted in chronological order
  // regardless of BYDAY list order.
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:wkst-order\r\n"
    <> "SUMMARY:Order test\r\n"
    <> "DTSTART;VALUE=DATE:20260616\r\n"
    <> "DTEND;VALUE=DATE:20260617\r\n"
    // BYDAY in reverse: SU, TU. With WKST=MO, both occur Jun 16 (Tue) and Jun 21 (Sun).
    <> "RRULE:FREQ=WEEKLY;INTERVAL=1;BYDAY=SU,TU\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = two_weeks()
  let dates = ical.parse_events(ical_text, "Cal", s, e) |> event_dates
  // First two emitted: Jun 16 (Tue), Jun 21 (Sun) — in date order, not BYDAY order.
  assert dates
    == [
      calendar.Date(2026, calendar.June, 16),
      calendar.Date(2026, calendar.June, 21),
      calendar.Date(2026, calendar.June, 23),
    ]
  Nil
}

pub fn wkst_invalid_value_falls_back_to_monday_test() -> Nil {
  // An unrecognized WKST value should be ignored (treated as default MO).
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:wkst-invalid\r\n"
    <> "SUMMARY:Invalid WKST\r\n"
    <> "DTSTART;VALUE=DATE:20260616\r\n"
    <> "DTEND;VALUE=DATE:20260617\r\n"
    <> "RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,SU;WKST=XX\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = eight_weeks()
  let dates = ical.parse_events(ical_text, "Cal", s, e) |> event_dates
  // Same as default WKST=MO case
  assert list.length(dates) == 8
  Nil
}
