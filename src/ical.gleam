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

import cal.{type Event, type EventTime, AllDay, AtTime, Event}
import gleam/float
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import gleam/time/calendar.{type Month, Date}
import gleam/time/duration
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
/// Also strip bare \r so that splitting on \n yields clean lines.
fn unfold_lines(text: String) -> String {
  text
  |> string.replace("\r\n ", "")
  |> string.replace("\r\n\t", "")
  |> string.replace("\n ", "")
  |> string.replace("\n\t", "")
  |> string.replace("\r", "")
}

// VEVENT SPLITTING ------------------------------------------------------------

/// Extract the raw content (lines between BEGIN:VEVENT and END:VEVENT) of
/// each VEVENT in the calendar text.
fn split_vevents(text: String) -> List(List(String)) {
  let lines = string.split(text, "\n")
  do_split_vevents(lines, False, [], [])
}

fn do_split_vevents(
  lines: List(String),
  in_vevent: Bool,
  current: List(String),
  acc: List(List(String)),
) -> List(List(String)) {
  case lines {
    [] -> acc
    [line, ..rest] -> {
      let trimmed = string.trim(line)
      case trimmed {
        "BEGIN:VEVENT" -> do_split_vevents(rest, True, [], acc)
        "END:VEVENT" ->
          do_split_vevents(rest, False, [], [list.reverse(current), ..acc])
        _ ->
          case in_vevent {
            False -> do_split_vevents(rest, False, [], acc)
            True -> do_split_vevents(rest, True, [trimmed, ..current], acc)
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
  let local_offset = calendar.local_offset()

  use uid <- result.try(get_prop(props, "UID"))
  use summary <- result.try(get_prop(props, "SUMMARY"))
  use dtstart_raw <- result.try(get_prop_prefix(props, "DTSTART"))
  use dtend_raw <- result.try(get_prop_prefix(props, "DTEND"))

  // Detect whether DTSTART/DTEND carry a TZID parameter (local wall-clock time)
  let dtstart_is_local = has_tzid_param(lines, "DTSTART")
  let dtend_is_local = has_tzid_param(lines, "DTEND")

  use start <- result.try(parse_event_time(
    dtstart_raw,
    dtstart_is_local,
    local_offset,
  ))
  use end <- result.try(parse_event_time(
    dtend_raw,
    dtend_is_local,
    local_offset,
  ))

  Ok(Event(uid:, summary:, start:, end:, calendar_name:))
}

/// Check whether a property line for `name` carries a ;TZID= parameter.
fn has_tzid_param(lines: List(String), prop_name: String) -> Bool {
  list.any(lines, fn(line) {
    let upper = string.uppercase(line)
    string.starts_with(upper, prop_name <> ";TZID=")
  })
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
/// If `is_local` is True, the datetime string is in wall-clock (TZID) time:
/// we store it shifted by -local_offset so that to_calendar(ts, local_offset)
/// recovers the original wall-clock time during display.
fn parse_event_time(
  value: String,
  is_local: Bool,
  local_offset: duration.Duration,
) -> Result(EventTime, Nil) {
  let trimmed = string.trim(value)
  case string.length(trimmed) {
    // DATE format: YYYYMMDD
    8 -> parse_date(trimmed) |> result.map(AllDay)
    // DATE-TIME: YYYYMMDDTHHMMSSZ (UTC) or YYYYMMDDTHHMMSS (floating/TZID)
    15 | 16 -> {
      use ts <- result.try(parse_datetime(trimmed))
      let adjusted = case is_local {
        // Subtract local offset so that to_calendar(ts, local_offset) = wall clock.
        // Duration has no negate(), so negate manually via seconds.
        True -> {
          let offset_secs = duration.to_seconds(local_offset)
          let neg_offset = duration.seconds(0 - float.truncate(offset_secs))
          timestamp.add(ts, neg_offset)
        }
        False -> ts
      }
      Ok(AtTime(adjusted))
    }
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
  let time =
    calendar.TimeOfDay(
      hours: hour,
      minutes: minute,
      seconds: second,
      nanoseconds: 0,
    )
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
