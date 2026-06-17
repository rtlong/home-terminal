//// Tests for RFC 5545 §3.3.11 TEXT escape unescaping.
////
//// Per the spec, TEXT-typed property values escape the following:
////   \\  -> \
////   \;  -> ;
////   \,  -> ,
////   \N  -> LF (newline), also \n
////
//// Applies to SUMMARY, DESCRIPTION, LOCATION, COMMENT, CONTACT, etc.
//// URL is URI-typed and is NOT subject to TEXT escape rules.

import cal.{AtTime}
import gleam/time/timestamp
import ical

fn one_day() -> #(timestamp.Timestamp, timestamp.Timestamp) {
  #(
    timestamp.from_unix_seconds(1_781_409_600),
    timestamp.from_unix_seconds(1_781_496_000),
  )
}

fn first_event(events: List(cal.Event)) -> cal.Event {
  let assert [e, ..] = events
  e
}

// SUMMARY with \, should yield a literal comma.
pub fn summary_unescapes_comma_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:e\r\n"
    <> "SUMMARY:Lunch with Alice\\, Bob\\, and Carol\r\n"
    <> "DTSTART:20260614T120000Z\r\n"
    <> "DTEND:20260614T130000Z\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = one_day()
  let events = ical.parse_events(ical_text, "Cal", s, e)
  let evt = first_event(events)
  assert evt.summary == "Lunch with Alice, Bob, and Carol"
  Nil
}

// SUMMARY with \; should yield a literal semicolon.
pub fn summary_unescapes_semicolon_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:e\r\n"
    <> "SUMMARY:Meet\\; discuss\\; ship\r\n"
    <> "DTSTART:20260614T120000Z\r\n"
    <> "DTEND:20260614T130000Z\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = one_day()
  let events = ical.parse_events(ical_text, "Cal", s, e)
  let evt = first_event(events)
  assert evt.summary == "Meet; discuss; ship"
  Nil
}

// SUMMARY with \\ should yield a single backslash.
pub fn summary_unescapes_backslash_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:e\r\n"
    <> "SUMMARY:Path C:\\\\Users\\\\me\r\n"
    <> "DTSTART:20260614T120000Z\r\n"
    <> "DTEND:20260614T130000Z\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = one_day()
  let events = ical.parse_events(ical_text, "Cal", s, e)
  let evt = first_event(events)
  assert evt.summary == "Path C:\\Users\\me"
  Nil
}

// DESCRIPTION with \n should yield a newline.
pub fn description_unescapes_newline_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:e\r\n"
    <> "SUMMARY:Meeting\r\n"
    <> "DESCRIPTION:Line one\\nLine two\\nLine three\r\n"
    <> "DTSTART:20260614T120000Z\r\n"
    <> "DTEND:20260614T130000Z\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = one_day()
  let events = ical.parse_events(ical_text, "Cal", s, e)
  let evt = first_event(events)
  assert evt.description == "Line one\nLine two\nLine three"
  Nil
}

// \N (uppercase) is also a newline per the spec.
pub fn description_unescapes_uppercase_newline_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:e\r\n"
    <> "SUMMARY:Meeting\r\n"
    <> "DESCRIPTION:Line one\\NLine two\r\n"
    <> "DTSTART:20260614T120000Z\r\n"
    <> "DTEND:20260614T130000Z\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = one_day()
  let events = ical.parse_events(ical_text, "Cal", s, e)
  let evt = first_event(events)
  assert evt.description == "Line one\nLine two"
  Nil
}

// LOCATION is also TEXT-typed and should unescape.
pub fn location_unescapes_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:e\r\n"
    <> "SUMMARY:Meeting\r\n"
    <> "LOCATION:Conf Room A\\, 4th Floor\r\n"
    <> "DTSTART:20260614T120000Z\r\n"
    <> "DTEND:20260614T130000Z\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = one_day()
  let events = ical.parse_events(ical_text, "Cal", s, e)
  let evt = first_event(events)
  assert evt.location == "Conf Room A, 4th Floor"
  Nil
}

// Combined: all four escape forms in one DESCRIPTION value.
pub fn description_combined_escapes_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:e\r\n"
    <> "SUMMARY:Meeting\r\n"
    <> "DESCRIPTION:Tags: a\\,b\\;c\\\\d\\ne\r\n"
    <> "DTSTART:20260614T120000Z\r\n"
    <> "DTEND:20260614T130000Z\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = one_day()
  let events = ical.parse_events(ical_text, "Cal", s, e)
  let evt = first_event(events)
  assert evt.description == "Tags: a,b;c\\d\ne"
  Nil
}

// Critical edge case: an escaped backslash followed by the letter `n`
// should be a literal backslash + 'n', NOT a newline. (i.e. `\\n` = `\n`
// as two characters, not `\n` as a newline.) This requires the unescape
// to scan left-to-right with a state machine, not naive .replace() in any
// order that would conflate "\\" then "\n" -> backslash then newline.
pub fn description_double_backslash_then_n_not_newline_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:e\r\n"
    <> "SUMMARY:Meeting\r\n"
    <> "DESCRIPTION:lit\\\\nbreak\r\n"
    <> "DTSTART:20260614T120000Z\r\n"
    <> "DTEND:20260614T130000Z\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = one_day()
  let events = ical.parse_events(ical_text, "Cal", s, e)
  let evt = first_event(events)
  // Input bytes after iCal line-strip: lit\\nbreak  -> \\ = '\', then 'n' literal
  assert evt.description == "lit\\nbreak"
  Nil
}

// URL is URI-typed (not TEXT) — escapes should be left untouched.
pub fn url_is_not_text_escaped_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:e\r\n"
    <> "SUMMARY:Meeting\r\n"
    <> "URL:https://example.com/path\\,with-comma\r\n"
    <> "DTSTART:20260614T120000Z\r\n"
    <> "DTEND:20260614T130000Z\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = one_day()
  let events = ical.parse_events(ical_text, "Cal", s, e)
  let evt = first_event(events)
  // Leave the URL alone — backslash stays as-is for callers to handle.
  assert evt.url == "https://example.com/path\\,with-comma"
  Nil
}

// Sanity check: confirm DTSTART parsing still works alongside unescaping.
pub fn unescape_does_not_affect_datetime_test() -> Nil {
  let ical_text =
    "BEGIN:VCALENDAR\r\n"
    <> "VERSION:2.0\r\n"
    <> "BEGIN:VEVENT\r\n"
    <> "UID:e\r\n"
    <> "SUMMARY:Title with \\, comma\r\n"
    <> "DTSTART:20260614T120000Z\r\n"
    <> "DTEND:20260614T130000Z\r\n"
    <> "END:VEVENT\r\n"
    <> "END:VCALENDAR\r\n"

  let #(s, e) = one_day()
  let events = ical.parse_events(ical_text, "Cal", s, e)
  let evt = first_event(events)
  case evt.start {
    AtTime(_) -> Nil
    _ -> panic as "expected timed event"
  }
}
