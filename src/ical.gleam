// Minimal iCalendar (RFC 5545) parser.
//
// Parses VEVENT components out of a VCALENDAR text block and maps them to
// cal.Event values. Only the fields used by the 7-day view are extracted:
//   UID, SUMMARY, DTSTART, DTEND.
//
// DTSTART/DTEND can be in one of three formats:
//   20240115           — all-day (DATE)
//   20240115T140000Z   — UTC datetime (DATE-TIME with Z suffix)
//   20240115T140000    — floating datetime (treated as UTC for simplicity)

// IMPORTS ---------------------------------------------------------------------

import cal.{type Event, AllDay, AtTime, Event, type EventTime}
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import gleam/time/calendar.{Date, type Month}
import gleam/time/timestamp

// PUBLIC API ------------------------------------------------------------------

/// Parse all VEVENT blocks found in `ical_text` and return the valid ones as
/// cal.Event values.  Malformed events are silently dropped.
pub fn parse_events(ical_text: String, calendar_name: String) -> List(Event) {
  ical_text
  |> unfold_lines
  |> split_vevents
  |> list.filter_map(fn(block) { parse_vevent(block, calendar_name) })
}

// LINE UNFOLDING --------------------------------------------------------------

/// RFC 5545 §3.1: long lines may be folded by inserting CRLF + whitespace.
/// Unfold by removing CRLF (or bare LF) followed by a space or tab.
fn unfold_lines(text: String) -> String {
  text
  |> string.replace("\r\n ", "")
  |> string.replace("\r\n\t", "")
  |> string.replace("\n ", "")
  |> string.replace("\n\t", "")
}

// VEVENT SPLITTING ------------------------------------------------------------

/// Extract the raw content (lines between BEGIN:VEVENT and END:VEVENT) of
/// each VEVENT in the calendar text.
fn split_vevents(text: String) -> List(List(String)) {
  let lines = string.split(text, "\n")
  do_split_vevents(lines, [], [])
}

fn do_split_vevents(
  lines: List(String),
  current: List(String),
  acc: List(List(String)),
) -> List(List(String)) {
  case lines {
    [] -> acc
    [line, ..rest] -> {
      let trimmed = string.trim(line)
      case trimmed {
        "BEGIN:VEVENT" -> do_split_vevents(rest, [], acc)
        "END:VEVENT" ->
          do_split_vevents(rest, [], [list.reverse(current), ..acc])
        _ ->
          case current {
            // We haven't entered a VEVENT block yet – skip
            [] -> do_split_vevents(rest, [], acc)
            _ -> do_split_vevents(rest, [trimmed, ..current], acc)
          }
      }
    }
  }
}

// VEVENT PARSING --------------------------------------------------------------

fn parse_vevent(
  lines: List(String),
  calendar_name: String,
) -> Result(Event, Nil) {
  let props = list.filter_map(lines, parse_property)

  use uid <- result.try(get_prop(props, "UID"))
  use summary <- result.try(get_prop(props, "SUMMARY"))
  use dtstart_raw <- result.try(get_prop_prefix(props, "DTSTART"))
  use dtend_raw <- result.try(get_prop_prefix(props, "DTEND"))

  use start <- result.try(parse_event_time(dtstart_raw))
  use end <- result.try(parse_event_time(dtend_raw))

  Ok(Event(uid:, summary:, start:, end:, calendar_name:))
}

// PROPERTY PARSING ------------------------------------------------------------

/// Parse a single iCal property line into a (name, value) pair.
/// Handles property parameters like DTSTART;TZID=America/Los_Angeles:value
/// by stripping everything before the final colon in the name part.
fn parse_property(line: String) -> Result(#(String, String), Nil) {
  case string.split_once(line, ":") {
    Ok(#(name_part, value)) -> {
      // Strip any parameters from the property name
      let name = case string.split_once(name_part, ";") {
        Ok(#(base, _params)) -> base
        Error(Nil) -> name_part
      }
      Ok(#(string.uppercase(name), value))
    }
    Error(Nil) -> Error(Nil)
  }
}

/// Find the value of the first property with exactly the given name.
fn get_prop(props: List(#(String, String)), name: String) -> Result(String, Nil) {
  list.find_map(props, fn(p) {
    case p.0 == name {
      True -> Ok(p.1)
      False -> Error(Nil)
    }
  })
}

/// Find the raw iCal string for a property whose name starts with `prefix`.
/// This is needed for DTSTART/DTEND which may carry ;TZID= parameters.
/// We return the *value* portion (after the colon) as parsed by parse_property.
fn get_prop_prefix(
  props: List(#(String, String)),
  prefix: String,
) -> Result(String, Nil) {
  list.find_map(props, fn(p) {
    case string.starts_with(p.0, prefix) {
      True -> Ok(p.1)
      False -> Error(Nil)
    }
  })
}

// DATETIME PARSING ------------------------------------------------------------

/// Parse an iCalendar date or datetime value into an EventTime.
fn parse_event_time(value: String) -> Result(EventTime, Nil) {
  let trimmed = string.trim(value)
  case string.length(trimmed) {
    // DATE format: YYYYMMDD
    8 -> parse_date(trimmed) |> result.map(AllDay)
    // DATE-TIME: YYYYMMDDTHHMMSSZ or YYYYMMDDTHHMMSS
    15 | 16 -> parse_datetime(trimmed) |> result.map(AtTime)
    _ -> Error(Nil)
  }
}

fn parse_date(s: String) -> Result(calendar.Date, Nil) {
  use year <- result.try(parse_int_slice(s, 0, 4))
  use month <- result.try(parse_int_slice(s, 4, 2) |> result.try(int_to_month))
  use day <- result.try(parse_int_slice(s, 6, 2))
  Ok(Date(year:, month:, day:))
}

fn parse_datetime(s: String) -> Result(timestamp.Timestamp, Nil) {
  // Format: YYYYMMDDTHHMMSS[Z]
  use year <- result.try(parse_int_slice(s, 0, 4))
  use month_int <- result.try(parse_int_slice(s, 4, 2))
  use day <- result.try(parse_int_slice(s, 6, 2))
  // position 8 is 'T'
  use hour <- result.try(parse_int_slice(s, 9, 2))
  use minute <- result.try(parse_int_slice(s, 11, 2))
  use second <- result.try(parse_int_slice(s, 13, 2))
  use month <- result.try(int_to_month(month_int))

  let date = Date(year:, month:, day:)
  let time = calendar.TimeOfDay(hours: hour, minutes: minute, seconds: second, nanoseconds: 0)
  Ok(timestamp.from_calendar(date:, time:, offset: calendar.utc_offset))
}

fn parse_int_slice(s: String, offset: Int, length: Int) -> Result(Int, Nil) {
  s
  |> string.slice(offset, length)
  |> int.parse
}

fn int_to_month(n: Int) -> Result(Month, Nil) {
  calendar.month_from_int(n)
}
