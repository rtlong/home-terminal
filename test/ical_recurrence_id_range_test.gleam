//// Tests for RFC 5545 §3.2.13 RANGE parameter on RECURRENCE-ID overrides.
////
//// When a RECURRENCE-ID is decorated with `RANGE=THISANDFUTURE`, the
//// override applies not only to the matched instance but also to every
//// subsequent instance of the same recurrence. This is the iCalendar way
//// of expressing "edit this and following events" without splitting the
//// master RRULE into two VEVENTs.
////
//// Semantics implemented:
//// * THISANDFUTURE + new SUMMARY/LOCATION/DESCRIPTION: those properties
////   replace the master values from the override's RECURRENCE-ID onward.
//// * THISANDFUTURE + STATUS:CANCELLED: the override's instance and all
////   subsequent instances are removed from the emitted set.
//// * Single-instance overrides (no RANGE) take precedence over
////   THISANDFUTURE overrides when both could match the same instance —
////   the more specific override wins.

import cal.{AllDay, AtTime}
import gleam/list
import gleam/order
import gleam/time/calendar
import gleam/time/timestamp
import ical

// Window: Sun 2026-06-14 00:00 EDT → Sun 2026-06-21 00:00 EDT (one week).
fn one_week() -> #(timestamp.Timestamp, timestamp.Timestamp) {
  #(
    timestamp.from_unix_seconds(1_781_409_600),
    timestamp.from_unix_seconds(1_782_014_400),
  )
}

fn sort_by_start(events: List(cal.Event)) -> List(cal.Event) {
  list.sort(events, fn(a, b) {
    case a.start, b.start {
      AtTime(ta), AtTime(tb) -> timestamp.compare(ta, tb)
      AllDay(da), AllDay(db) -> calendar.naive_date_compare(da, db)
      AtTime(_), AllDay(_) -> order.Lt
      AllDay(_), AtTime(_) -> order.Gt
    }
  })
}

// THISANDFUTURE with a new SUMMARY: from the override's RECURRENCE-ID
// onward, every instance carries the override's summary. Earlier
// instances keep the master's summary.
pub fn thisandfuture_summary_propagates_to_subsequent_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:taf-summary\r\n"
    <> "SUMMARY:Original\r\n"
    <> "DTSTART;TZID=America/New_York:20260615T100000\r\n"
    <> "DTEND;TZID=America/New_York:20260615T110000\r\n"
    <> "RRULE:FREQ=DAILY;COUNT=4\r\n"
    <> "END:VEVENT\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:taf-summary\r\n"
    <> "SUMMARY:Updated\r\n"
    <> "RECURRENCE-ID;TZID=America/New_York;RANGE=THISANDFUTURE:20260617T100000\r\n"
    <> "DTSTART;TZID=America/New_York:20260617T100000\r\n"
    <> "DTEND;TZID=America/New_York:20260617T110000\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"
  let #(s, e) = one_week()
  let events = ical.parse_events(ical_text, "Cal", s, e) |> sort_by_start
  assert list.length(events) == 4
  let names = list.map(events, fn(ev: cal.Event) { ev.summary })
  assert names == ["Original", "Original", "Updated", "Updated"]
  Nil
}

// THISANDFUTURE + STATUS:CANCELLED: cancels this instance and all
// subsequent ones from the recurrence set.
pub fn thisandfuture_cancelled_drops_this_and_all_subsequent_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:taf-cancel\r\n"
    <> "SUMMARY:Daily\r\n"
    <> "DTSTART;TZID=America/New_York:20260615T100000\r\n"
    <> "DTEND;TZID=America/New_York:20260615T110000\r\n"
    <> "RRULE:FREQ=DAILY;COUNT=4\r\n"
    <> "END:VEVENT\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:taf-cancel\r\n"
    <> "SUMMARY:Daily (cancelled from day 3 onward)\r\n"
    <> "RECURRENCE-ID;TZID=America/New_York;RANGE=THISANDFUTURE:20260617T100000\r\n"
    <> "DTSTART;TZID=America/New_York:20260617T100000\r\n"
    <> "DTEND;TZID=America/New_York:20260617T110000\r\n"
    <> "STATUS:CANCELLED\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"
  let #(s, e) = one_week()
  let events = ical.parse_events(ical_text, "Cal", s, e)
  // 4 master instances minus this-and-future cancellation at day 3 = 2 events.
  assert list.length(events) == 2
  Nil
}

// THISANDFUTURE override applied only to the matching instance and
// subsequent ones; earlier instances must remain unchanged.
pub fn thisandfuture_does_not_affect_prior_instances_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:taf-prior\r\n"
    <> "SUMMARY:Original\r\n"
    <> "DTSTART;TZID=America/New_York:20260615T100000\r\n"
    <> "DTEND;TZID=America/New_York:20260615T110000\r\n"
    <> "RRULE:FREQ=DAILY;COUNT=4\r\n"
    <> "END:VEVENT\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:taf-prior\r\n"
    <> "SUMMARY:Changed\r\n"
    <> "RECURRENCE-ID;TZID=America/New_York;RANGE=THISANDFUTURE:20260618T100000\r\n"
    <> "DTSTART;TZID=America/New_York:20260618T100000\r\n"
    <> "DTEND;TZID=America/New_York:20260618T110000\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"
  let #(s, e) = one_week()
  let events = ical.parse_events(ical_text, "Cal", s, e)
  assert list.length(events) == 4
  let originals = list.filter(events, fn(ev: cal.Event) { ev.summary == "Original" })
  let changed = list.filter(events, fn(ev: cal.Event) { ev.summary == "Changed" })
  assert list.length(originals) == 3
  assert list.length(changed) == 1
  Nil
}

// Single-instance override (no RANGE) for a specific date takes
// precedence over a THISANDFUTURE override that would otherwise also
// match the same instance.
pub fn single_override_beats_thisandfuture_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:taf-vs-single\r\n"
    <> "SUMMARY:Original\r\n"
    <> "DTSTART;TZID=America/New_York:20260615T100000\r\n"
    <> "DTEND;TZID=America/New_York:20260615T110000\r\n"
    <> "RRULE:FREQ=DAILY;COUNT=4\r\n"
    <> "END:VEVENT\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:taf-vs-single\r\n"
    <> "SUMMARY:All Future\r\n"
    <> "RECURRENCE-ID;TZID=America/New_York;RANGE=THISANDFUTURE:20260616T100000\r\n"
    <> "DTSTART;TZID=America/New_York:20260616T100000\r\n"
    <> "DTEND;TZID=America/New_York:20260616T110000\r\n"
    <> "END:VEVENT\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:taf-vs-single\r\n"
    <> "SUMMARY:Just Day 3\r\n"
    <> "RECURRENCE-ID;TZID=America/New_York:20260617T100000\r\n"
    <> "DTSTART;TZID=America/New_York:20260617T100000\r\n"
    <> "DTEND;TZID=America/New_York:20260617T110000\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"
  let #(s, e) = one_week()
  let events = ical.parse_events(ical_text, "Cal", s, e)
  assert list.length(events) == 4
  let just_day_3 =
    list.filter(events, fn(ev: cal.Event) { ev.summary == "Just Day 3" })
  let all_future =
    list.filter(events, fn(ev: cal.Event) { ev.summary == "All Future" })
  let originals =
    list.filter(events, fn(ev: cal.Event) { ev.summary == "Original" })
  // Day 1: Original. Days 2 & 4: All Future. Day 3: Just Day 3.
  assert list.length(originals) == 1
  assert list.length(all_future) == 2
  assert list.length(just_day_3) == 1
  Nil
}
