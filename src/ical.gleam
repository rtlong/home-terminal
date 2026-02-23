// Minimal iCalendar (RFC 5545) parser.
//
// Parses VEVENT components out of a VCALENDAR text block and maps them to
// cal.Event values. Only the fields used by the 7-day view are extracted:
//   UID, SUMMARY, DTSTART, DTEND, LOCATION.
//
// Recurring events (RRULE:FREQ=WEEKLY) are expanded into individual instances
// within the supplied time window. EXDATE exclusions are respected.
// RECURRENCE-ID overrides replace the corresponding generated instance.
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
import gleam/order.{Eq, Lt}
import gleam/result
import gleam/string
import gleam/time/calendar.{type Month, Date}
import gleam/time/duration
import gleam/time/timestamp

// PUBLIC API ------------------------------------------------------------------

/// Parse all VEVENT blocks found in `ical_text` and return events that fall
/// within [window_start, window_end). Recurring events are expanded.
pub fn parse_events(
  ical_text: String,
  calendar_name: String,
  window_start: timestamp.Timestamp,
  window_end: timestamp.Timestamp,
) -> List(Event) {
  let local_offset = calendar.local_offset()
  let raw_vevents =
    ical_text
    |> unfold_lines
    |> split_vevents

  // Separate masters from overrides
  let masters =
    list.filter(raw_vevents, fn(lines) { !has_prop(lines, "RECURRENCE-ID") })
  let overrides =
    list.filter(raw_vevents, fn(lines) { has_prop(lines, "RECURRENCE-ID") })

  list.flat_map(masters, fn(lines) {
    expand_vevent(
      lines,
      overrides,
      calendar_name,
      local_offset,
      window_start,
      window_end,
    )
  })
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

// VEVENT EXPANSION ------------------------------------------------------------

/// Expand a master VEVENT into one or more Events within the window.
/// If it has RRULE:FREQ=WEEKLY, generate weekly instances.
/// Applies EXDATE exclusions and RECURRENCE-ID overrides.
fn expand_vevent(
  lines: List(String),
  overrides: List(List(String)),
  calendar_name: String,
  local_offset: duration.Duration,
  window_start: timestamp.Timestamp,
  window_end: timestamp.Timestamp,
) -> List(Event) {
  let props = list.filter_map(lines, parse_property)

  case get_prop(props, "UID"), get_prop(props, "SUMMARY") {
    Ok(uid), Ok(summary) -> {
      let location = get_prop(props, "LOCATION") |> result.unwrap("")
      let dtstart_is_local = has_tzid_param(lines, "DTSTART")
      let dtend_is_local =
        has_tzid_param(lines, "DTEND")
        // If DTSTART has TZID and DTEND is floating (no TZID, no Z), treat
        // DTEND as local too — some servers emit mixed-type start/end.
        || {
          dtstart_is_local
          && !has_tzid_param(lines, "DTEND")
          && case get_prop_prefix(props, "DTEND") {
            Ok(v) -> is_floating_datetime(v)
            Error(Nil) -> False
          }
        }

      case get_prop_prefix(props, "DTSTART"), get_prop_prefix(props, "DTEND") {
        Ok(dtstart_raw), Ok(dtend_raw) -> {
          case
            parse_event_time(dtstart_raw, dtstart_is_local, local_offset),
            parse_event_time(dtend_raw, dtend_is_local, local_offset)
          {
            Ok(start), Ok(end) -> {
              // Check for RRULE:FREQ=WEEKLY
              let has_weekly_rrule = case get_prop(props, "RRULE") {
                Ok(rrule) ->
                  string.contains(string.uppercase(rrule), "FREQ=WEEKLY")
                Error(Nil) -> False
              }

              case has_weekly_rrule {
                False -> {
                  // Non-recurring: include if it overlaps the window
                  case event_in_window(start, end, window_start, window_end) {
                    True -> [
                      Event(
                        uid:,
                        summary:,
                        start:,
                        end:,
                        calendar_name:,
                        location:,
                      ),
                    ]
                    False -> []
                  }
                }
                True -> {
                  // Collect EXDATEs as a list of raw date strings to exclude
                  let exdates = collect_exdates(lines, local_offset)

                  // Find overrides for this UID
                  let uid_overrides =
                    list.filter(overrides, fn(ol) {
                      let oprops = list.filter_map(ol, parse_property)
                      get_prop(oprops, "UID") == Ok(uid)
                    })

                  // Compute event duration to apply to each instance
                  let duration_secs = event_duration_secs(start, end)

                  // Generate weekly instances within window
                  expand_weekly(
                    uid,
                    summary,
                    calendar_name,
                    location,
                    start,
                    end,
                    duration_secs,
                    exdates,
                    uid_overrides,
                    local_offset,
                    window_start,
                    window_end,
                  )
                }
              }
            }
            _, _ -> []
          }
        }
        _, _ -> []
      }
    }
    _, _ -> []
  }
}

/// Generate weekly occurrences of a recurring event within [window_start, window_end).
/// - Skip dates in exdates
/// - Replace instances that have a matching RECURRENCE-ID override
/// Dispatches to timed or all-day expansion based on master_start type.
fn expand_weekly(
  uid: String,
  summary: String,
  calendar_name: String,
  location: String,
  master_start: EventTime,
  master_end: EventTime,
  duration_secs: Int,
  exdates: List(timestamp.Timestamp),
  uid_overrides: List(List(String)),
  local_offset: duration.Duration,
  window_start: timestamp.Timestamp,
  window_end: timestamp.Timestamp,
) -> List(Event) {
  let override_events =
    list.filter_map(uid_overrides, fn(lines) {
      parse_override_event(lines, uid, calendar_name, local_offset)
    })

  let instances = case master_start {
    AtTime(base_ts) ->
      // Timed recurring event: expand by advancing timestamps weekly.
      generate_weekly_timed(
        base_ts,
        duration_secs,
        exdates,
        uid_overrides,
        uid,
        summary,
        calendar_name,
        location,
        local_offset,
        window_start,
        window_end,
        [],
      )
    AllDay(base_date) -> {
      // All-day recurring event: compute the event's day-count duration,
      // then expand by advancing the date by 7 days at a time.
      let day_count = case master_end {
        AllDay(end_date) -> date_day_count(base_date, end_date)
        _ -> 1
      }
      let window_start_date =
        timestamp.to_calendar(window_start, local_offset).0
      let window_end_date = timestamp.to_calendar(window_end, local_offset).0
      generate_weekly_allday(
        base_date,
        day_count,
        exdates,
        uid_overrides,
        uid,
        summary,
        calendar_name,
        location,
        local_offset,
        window_start_date,
        window_end_date,
        [],
      )
    }
  }

  // Also include override events that fall in the window but weren't covered
  // by the generated instances (e.g. the original occurrence was outside the
  // window but the override's actual DTSTART is inside).
  let override_in_window =
    list.filter(override_events, fn(e) {
      event_in_window(e.start, e.end, window_start, window_end)
      && !list.any(instances, fn(i) {
        i.uid == e.uid && times_equal(i.start, e.start)
      })
    })

  list.append(instances, override_in_window)
}

/// Advance a Date by exactly `n` days using calendar arithmetic.
fn advance_date_by_n(date: calendar.Date, n: Int) -> calendar.Date {
  case n <= 0 {
    True -> date
    False -> advance_date_by_n(advance_one_day(date), n - 1)
  }
}

fn advance_one_day(date: calendar.Date) -> calendar.Date {
  let days_in = days_in_month(date.month, date.year)
  case date.day < days_in {
    True -> calendar.Date(..date, day: date.day + 1)
    False ->
      case date.month {
        calendar.December ->
          calendar.Date(year: date.year + 1, month: calendar.January, day: 1)
        _ -> calendar.Date(..date, month: next_month_cal(date.month), day: 1)
      }
  }
}

fn days_in_month(month: calendar.Month, year: Int) -> Int {
  case month {
    calendar.January -> 31
    calendar.February ->
      case calendar.is_leap_year(year) {
        True -> 29
        False -> 28
      }
    calendar.March -> 31
    calendar.April -> 30
    calendar.May -> 31
    calendar.June -> 30
    calendar.July -> 31
    calendar.August -> 31
    calendar.September -> 30
    calendar.October -> 31
    calendar.November -> 30
    calendar.December -> 31
  }
}

fn next_month_cal(m: calendar.Month) -> calendar.Month {
  case m {
    calendar.January -> calendar.February
    calendar.February -> calendar.March
    calendar.March -> calendar.April
    calendar.April -> calendar.May
    calendar.May -> calendar.June
    calendar.June -> calendar.July
    calendar.July -> calendar.August
    calendar.August -> calendar.September
    calendar.September -> calendar.October
    calendar.October -> calendar.November
    calendar.November -> calendar.December
    calendar.December -> calendar.January
  }
}

/// Compute how many days from `start` to `end` (exclusive end, as in iCal).
/// Returns at least 1.
fn date_day_count(start: calendar.Date, end: calendar.Date) -> Int {
  // Convert both to approximate timestamps for the diff (UTC midnight).
  let midnight =
    calendar.TimeOfDay(hours: 0, minutes: 0, seconds: 0, nanoseconds: 0)
  let ts_start =
    timestamp.from_calendar(
      date: start,
      time: midnight,
      offset: calendar.utc_offset,
    )
  let ts_end =
    timestamp.from_calendar(
      date: end,
      time: midnight,
      offset: calendar.utc_offset,
    )
  let diff_secs = duration.to_seconds(timestamp.difference(ts_start, ts_end))
  let days = float.truncate(diff_secs) / 86_400
  int.max(days, 1)
}

/// Compare two dates: True if a < b.
fn date_before(a: calendar.Date, b: calendar.Date) -> Bool {
  calendar.naive_date_compare(a, b) == order.Lt
}

/// Expand an all-day weekly recurring event within [window_start_date, window_end_date).
fn generate_weekly_allday(
  current_date: calendar.Date,
  day_count: Int,
  exdates: List(timestamp.Timestamp),
  uid_overrides: List(List(String)),
  uid: String,
  summary: String,
  calendar_name: String,
  location: String,
  local_offset: duration.Duration,
  window_start_date: calendar.Date,
  window_end_date: calendar.Date,
  acc: List(Event),
) -> List(Event) {
  // Stop when current_date >= window_end_date (no more overlap possible).
  // Guard against infinite loops: if we've gone more than 500 weeks past the window.
  let past_end = !date_before(current_date, window_end_date)
  let too_far =
    !date_before(current_date, advance_date_by_n(window_end_date, 500 * 7))

  case past_end || too_far {
    True -> list.reverse(acc)
    False -> {
      let next_date = advance_date_by_n(current_date, 7)
      let instance_end_date = advance_date_by_n(current_date, day_count)

      // In window if instance start < window_end AND instance end > window_start
      let in_window =
        date_before(current_date, window_end_date)
        && !date_before(instance_end_date, window_start_date)
        && calendar.naive_date_compare(instance_end_date, window_start_date)
        != order.Eq

      let new_acc = case in_window {
        False ->
          generate_weekly_allday(
            next_date,
            day_count,
            exdates,
            uid_overrides,
            uid,
            summary,
            calendar_name,
            location,
            local_offset,
            window_start_date,
            window_end_date,
            acc,
          )
        True -> {
          // Check EXDATE: an EXDATE matching this date excludes the instance.
          let is_excluded =
            list.any(exdates, fn(ex) {
              let #(ex_date, _) = timestamp.to_calendar(ex, local_offset)
              ex_date == current_date
            })

          case is_excluded {
            True ->
              generate_weekly_allday(
                next_date,
                day_count,
                exdates,
                uid_overrides,
                uid,
                summary,
                calendar_name,
                location,
                local_offset,
                window_start_date,
                window_end_date,
                acc,
              )
            False -> {
              // Check for RECURRENCE-ID override matching this date.
              let override_event =
                list.find_map(uid_overrides, fn(ol) {
                  let oprops = list.filter_map(ol, parse_property)
                  case get_prop_prefix(oprops, "RECURRENCE-ID") {
                    Ok(rec_raw) -> {
                      case parse_event_time(rec_raw, False, local_offset) {
                        Ok(AllDay(rec_date)) ->
                          case rec_date == current_date {
                            True ->
                              parse_override_event(
                                ol,
                                uid,
                                calendar_name,
                                local_offset,
                              )
                            False -> Error(Nil)
                          }
                        Ok(AtTime(rec_ts)) -> {
                          let #(rec_date, _) =
                            timestamp.to_calendar(rec_ts, local_offset)
                          case rec_date == current_date {
                            True ->
                              parse_override_event(
                                ol,
                                uid,
                                calendar_name,
                                local_offset,
                              )
                            False -> Error(Nil)
                          }
                        }
                        Error(Nil) -> Error(Nil)
                      }
                    }
                    Error(Nil) -> Error(Nil)
                  }
                })

              let event = case override_event {
                Ok(e) -> e
                Error(Nil) ->
                  Event(
                    uid:,
                    summary:,
                    start: AllDay(current_date),
                    end: AllDay(instance_end_date),
                    calendar_name:,
                    location:,
                  )
              }

              generate_weekly_allday(
                next_date,
                day_count,
                exdates,
                uid_overrides,
                uid,
                summary,
                calendar_name,
                location,
                local_offset,
                window_start_date,
                window_end_date,
                [event, ..acc],
              )
            }
          }
        }
      }
      new_acc
    }
  }
}

fn generate_weekly_timed(
  current_ts: timestamp.Timestamp,
  duration_secs: Int,
  exdates: List(timestamp.Timestamp),
  uid_overrides: List(List(String)),
  uid: String,
  summary: String,
  calendar_name: String,
  location: String,
  local_offset: duration.Duration,
  window_start: timestamp.Timestamp,
  window_end: timestamp.Timestamp,
  acc: List(Event),
) -> List(Event) {
  // Stop if we've gone past window_end or too far beyond it (loop guard)
  let past_end = timestamp.compare(current_ts, window_end) != Lt
  let too_far =
    timestamp.compare(
      current_ts,
      timestamp.add(window_end, duration.seconds(500 * 7 * 86_400)),
    )
    != Lt

  case past_end || too_far {
    True -> list.reverse(acc)
    False -> {
      let week = duration.seconds(7 * 86_400)
      let next_ts = timestamp.add(current_ts, week)

      // Only emit if current_ts is within or overlapping the window
      let instance_end_ts =
        timestamp.add(current_ts, duration.seconds(duration_secs))
      let in_window =
        timestamp.compare(instance_end_ts, window_start) != Lt
        && timestamp.compare(current_ts, window_end) == Lt

      let new_acc = case in_window {
        False ->
          generate_weekly_timed(
            next_ts,
            duration_secs,
            exdates,
            uid_overrides,
            uid,
            summary,
            calendar_name,
            location,
            local_offset,
            window_start,
            window_end,
            acc,
          )
        True -> {
          // Check if this occurrence is excluded
          let is_excluded =
            list.any(exdates, fn(ex) {
              same_day_ts(current_ts, ex, local_offset)
            })

          case is_excluded {
            True ->
              generate_weekly_timed(
                next_ts,
                duration_secs,
                exdates,
                uid_overrides,
                uid,
                summary,
                calendar_name,
                location,
                local_offset,
                window_start,
                window_end,
                acc,
              )
            False -> {
              // Check for a RECURRENCE-ID override matching this date
              let override_event =
                list.find_map(uid_overrides, fn(ol) {
                  let oprops = list.filter_map(ol, parse_property)
                  let rec_id_is_local = has_tzid_param(ol, "RECURRENCE-ID")
                  case get_prop_prefix(oprops, "RECURRENCE-ID") {
                    Ok(rec_raw) -> {
                      case
                        parse_event_time(rec_raw, rec_id_is_local, local_offset)
                      {
                        Ok(rec_time) -> {
                          case
                            same_day_event_time(
                              current_ts,
                              rec_time,
                              local_offset,
                            )
                          {
                            True ->
                              parse_override_event(
                                ol,
                                uid,
                                calendar_name,
                                local_offset,
                              )
                            False -> Error(Nil)
                          }
                        }
                        Error(Nil) -> Error(Nil)
                      }
                    }
                    Error(Nil) -> Error(Nil)
                  }
                })

              let event = case override_event {
                Ok(e) -> e
                Error(Nil) ->
                  Event(
                    uid:,
                    summary:,
                    start: AtTime(current_ts),
                    end: AtTime(instance_end_ts),
                    calendar_name:,
                    location:,
                  )
              }

              generate_weekly_timed(
                next_ts,
                duration_secs,
                exdates,
                uid_overrides,
                uid,
                summary,
                calendar_name,
                location,
                local_offset,
                window_start,
                window_end,
                [event, ..acc],
              )
            }
          }
        }
      }
      new_acc
    }
  }
}

fn parse_override_event(
  lines: List(String),
  uid: String,
  calendar_name: String,
  local_offset: duration.Duration,
) -> Result(Event, Nil) {
  let props = list.filter_map(lines, parse_property)
  use summary <- result.try(get_prop(props, "SUMMARY"))
  use dtstart_raw <- result.try(get_prop_prefix(props, "DTSTART"))
  use dtend_raw <- result.try(get_prop_prefix(props, "DTEND"))
  let dtstart_is_local = has_tzid_param(lines, "DTSTART")
  let dtend_is_local =
    has_tzid_param(lines, "DTEND")
    || {
      dtstart_is_local
      && !has_tzid_param(lines, "DTEND")
      && is_floating_datetime(dtend_raw)
    }
  let location = get_prop(props, "LOCATION") |> result.unwrap("")
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
  Ok(Event(uid:, summary:, start:, end:, calendar_name:, location:))
}

/// Collect all EXDATE values as Timestamps.
fn collect_exdates(
  lines: List(String),
  local_offset: duration.Duration,
) -> List(timestamp.Timestamp) {
  list.filter_map(lines, fn(line) {
    let upper = string.uppercase(line)
    case string.starts_with(upper, "EXDATE"), string.split_once(line, ":") {
      True, Ok(#(param_part, value)) -> {
        let is_local = string.contains(string.uppercase(param_part), "TZID=")
        parse_event_time(string.trim(value), is_local, local_offset)
        |> result.try(fn(et) {
          case et {
            AtTime(ts) -> Ok(ts)
            AllDay(_) -> Error(Nil)
          }
        })
      }
      _, _ -> Error(Nil)
    }
  })
}

/// Compute the duration in seconds between two EventTimes.
fn event_duration_secs(start: EventTime, end: EventTime) -> Int {
  case start, end {
    AtTime(s), AtTime(e) -> {
      let diff = duration.to_seconds(timestamp.difference(s, e))
      float.truncate(diff)
    }
    _, _ -> 3600
    // default 1 hour for all-day
  }
}

/// True if ts_a and ts_b fall on the same local calendar day.
fn same_day_ts(
  a: timestamp.Timestamp,
  b: timestamp.Timestamp,
  local_offset: duration.Duration,
) -> Bool {
  let #(date_a, _) = timestamp.to_calendar(a, local_offset)
  let #(date_b, _) = timestamp.to_calendar(b, local_offset)
  date_a == date_b
}

/// True if a timestamp and an EventTime fall on the same local calendar day.
fn same_day_event_time(
  ts: timestamp.Timestamp,
  et: EventTime,
  local_offset: duration.Duration,
) -> Bool {
  case et {
    AtTime(ts2) -> same_day_ts(ts, ts2, local_offset)
    AllDay(date) -> {
      let #(date_a, _) = timestamp.to_calendar(ts, local_offset)
      date_a == date
    }
  }
}

fn times_equal(a: EventTime, b: EventTime) -> Bool {
  case a, b {
    AtTime(ta), AtTime(tb) -> timestamp.compare(ta, tb) == Eq
    AllDay(da), AllDay(db) -> da == db
    _, _ -> False
  }
}

fn event_in_window(
  start: EventTime,
  end: EventTime,
  window_start: timestamp.Timestamp,
  window_end: timestamp.Timestamp,
) -> Bool {
  case start, end {
    AtTime(s), AtTime(e) ->
      timestamp.compare(e, window_start) != Lt
      && timestamp.compare(s, window_end) == Lt
    AllDay(_), _ -> True
    // include all-day events always (server already filtered)
    _, _ -> True
  }
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

/// Check whether any line in `lines` contains `prop_name` as a property.
fn has_prop(lines: List(String), prop_name: String) -> Bool {
  let upper_name = string.uppercase(prop_name)
  list.any(lines, fn(line) {
    let upper = string.uppercase(line)
    string.starts_with(upper, upper_name <> ":")
    || string.starts_with(upper, upper_name <> ";")
  })
}

/// Check whether a property line for `name` carries a ;TZID= parameter.
fn has_tzid_param(lines: List(String), prop_name: String) -> Bool {
  list.any(lines, fn(line) {
    let upper = string.uppercase(line)
    string.starts_with(upper, prop_name <> ";TZID=")
  })
}

/// True if a datetime value string is a floating local time (no Z suffix, 15 chars).
/// YYYYMMDDTHHMMSS (15 chars) = floating; YYYYMMDDTHHMMSSZ (16 chars) = UTC.
fn is_floating_datetime(value: String) -> Bool {
  let trimmed = string.trim(value)
  string.length(trimmed) == 15
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
