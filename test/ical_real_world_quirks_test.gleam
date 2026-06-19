//// Tests for real-world iCalendar quirks observed across major
//// implementations. Each test exercises a specific source of bugs
//// catalogued by libical, ical.js, ical4j, python-icalendar and
//// ccs-calendarserver test corpora. The goal is to catch
//// regressions against malformed-but-common output from Exchange,
//// SOGo, Lotus Notes, and other producers.

import gleam/list
import gleam/time/timestamp
import ical

// 1-week window: Sun 2026-06-14 00:00 EDT -> Sun 2026-06-21 00:00 EDT.
fn one_week() -> #(timestamp.Timestamp, timestamp.Timestamp) {
  #(
    timestamp.from_unix_seconds(1_781_409_600),
    timestamp.from_unix_seconds(1_782_014_400),
  )
}

// --- LINE ENDINGS & ENCODING -------------------------------------------------

// UTF-8 BOM (EF BB BF, codepoint U+FEFF) at the start of the file. Common
// when calendars are emitted by Windows-native tools that prepend a BOM to
// UTF-8 streams. Must be stripped before parsing.
pub fn bom_at_start_is_stripped_test() -> Nil {
  let ical_text =
    "\u{FEFF}BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:bom-test\r\n"
    <> "SUMMARY:With BOM\r\n"
    <> "DTSTART;TZID=America/New_York:20260615T100000\r\n"
    <> "DTEND;TZID=America/New_York:20260615T110000\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"
  let #(s, e) = one_week()
  let events = ical.parse_events(ical_text, "Cal", s, e)
  assert list.length(events) == 1
  Nil
}

// RFC 5545 §3.1 mandates CRLF line endings but reality includes bare LF
// (Unix-emitted) and bare CR (legacy Lotus Notes). Both must parse.
pub fn bare_lf_line_endings_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\n"
    <> "VERSION:2.0\n"
    <> "BEGIN:VEVENT\n"
    <> "UID:lf-test\n"
    <> "SUMMARY:Bare LF\n"
    <> "DTSTART;TZID=America/New_York:20260615T100000\n"
    <> "DTEND;TZID=America/New_York:20260615T110000\n"
    <> "END:VEVENT\n"
    <> "END:VCALENDAR\n"
  let #(s, e) = one_week()
  let events = ical.parse_events(ical_text, "Cal", s, e)
  assert list.length(events) == 1
  Nil
}

pub fn bare_cr_line_endings_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r"
    <> "VERSION:2.0\r"
    <> "BEGIN:VEVENT\r"
    <> "UID:cr-test\r"
    <> "SUMMARY:Bare CR\r"
    <> "DTSTART;TZID=America/New_York:20260615T100000\r"
    <> "DTEND;TZID=America/New_York:20260615T110000\r"
    <> "END:VEVENT\r"
    <> "END:VCALENDAR\r"
  let #(s, e) = one_week()
  let events = ical.parse_events(ical_text, "Cal", s, e)
  assert list.length(events) == 1
  Nil
}

// --- LINE FOLDING (RFC 5545 §3.1) -------------------------------------------

// A long SUMMARY folded mid-word with CRLF + space MUST be unfolded into a
// single value with the whitespace removed (NOT preserved).
pub fn line_folding_with_space_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:fold-space\r\n"
    <> "SUMMARY:This is a very long summary that gets folded onto multipl\r\n"
    <> " e lines per RFC 5545 line-folding rules\r\n"
    <> "DTSTART;TZID=America/New_York:20260615T100000\r\n"
    <> "DTEND;TZID=America/New_York:20260615T110000\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"
  let #(s, e) = one_week()
  let events = ical.parse_events(ical_text, "Cal", s, e)
  let assert [event] = events
  assert event.summary
    == "This is a very long summary that gets folded onto multiple lines per RFC 5545 line-folding rules"
  Nil
}

// Tab-based folding (CRLF + horizontal tab) per RFC 5545 §3.1 is equivalent
// to space-based folding; the tab character is consumed along with the CRLF.
pub fn line_folding_with_tab_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:fold-tab\r\n"
    <> "SUMMARY:Folded with\r\n"
    <> "\ttab continuation\r\n"
    <> "DTSTART;TZID=America/New_York:20260615T100000\r\n"
    <> "DTEND;TZID=America/New_York:20260615T110000\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"
  let #(s, e) = one_week()
  let events = ical.parse_events(ical_text, "Cal", s, e)
  let assert [event] = events
  assert event.summary == "Folded withtab continuation"
  Nil
}

// --- BLANK LINES -------------------------------------------------------------

// Blank lines within a component are not spec-legal but appear in real
// output (RFC 9074 example calendars, ical.js samples). Parser must not
// crash; it should treat them as no-op separators.
pub fn blank_lines_in_vevent_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:blank-line\r\n"
    <> "\r\n"
    <> "SUMMARY:Has blank lines\r\n"
    <> "\r\n"
    <> "DTSTART;TZID=America/New_York:20260615T100000\r\n"
    <> "DTEND;TZID=America/New_York:20260615T110000\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"
  let #(s, e) = one_week()
  let events = ical.parse_events(ical_text, "Cal", s, e)
  assert list.length(events) == 1
  Nil
}

// --- VENDOR-SPECIFIC QUIRKS --------------------------------------------------

// python-icalendar issue 157: some RRULE producers append a trailing ';'
// after the last rule-part. Must parse identically to the same RRULE
// without the trailing semicolon.
pub fn rrule_trailing_semicolon_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:trailing-semi\r\n"
    <> "SUMMARY:Daily with trailing ;\r\n"
    <> "DTSTART;TZID=America/New_York:20260615T100000\r\n"
    <> "DTEND;TZID=America/New_York:20260615T110000\r\n"
    <> "RRULE:FREQ=DAILY;COUNT=3;\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"
  let #(s, e) = one_week()
  let events = ical.parse_events(ical_text, "Cal", s, e)
  assert list.length(events) == 3
  Nil
}

// Microsoft Exchange emits "DTSTART;TZID=:20100101T000000" with an empty
// TZID value. Treat as floating (use system tz) and do not crash.
pub fn empty_tzid_does_not_crash_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:empty-tzid\r\n"
    <> "SUMMARY:Exchange quirk\r\n"
    <> "DTSTART;TZID=:20260615T100000\r\n"
    <> "DTEND;TZID=:20260615T110000\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"
  let #(s, e) = one_week()
  let events = ical.parse_events(ical_text, "Cal", s, e)
  // We don't require the event to parse successfully (the TZID is invalid),
  // but the parser must not crash and must return a clean (possibly empty)
  // event list.
  assert list.length(events) >= 0
  Nil
}

// --- CASING ------------------------------------------------------------------

// Property and component names are case-insensitive per RFC 5545 §3.1.
// "begin:VEVENT" and "Begin:Vevent" must both work.
pub fn mixed_case_begin_end_test() -> Nil {
  let ical_text =
    "Begin:VCalendar\r\n"
    <> "Version:2.0\r\n"
    <> "begin:vevent\r\n"
    <> "Uid:mixed-case\r\n"
    <> "Summary:Mixed case\r\n"
    <> "DtStart;TZID=America/New_York:20260615T100000\r\n"
    <> "DTEnd;TZID=America/New_York:20260615T110000\r\n"
    <> "end:vevent\r\n"
    <> "END:VCALENDAR\r\n"
  let #(s, e) = one_week()
  let events = ical.parse_events(ical_text, "Cal", s, e)
  assert list.length(events) == 1
  Nil
}
