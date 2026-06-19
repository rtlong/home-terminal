// Minimal iCalendar (RFC 5545) parser.
//
// Parses VEVENT components out of a VCALENDAR text block and maps them to
// cal.Event values. Only the fields used by the 7-day view are extracted:
//   UID, SUMMARY, DTSTART, DTEND, LOCATION.
//
// Recurring events (RRULE with FREQ=DAILY/WEEKLY/MONTHLY/YEARLY) are expanded 
// into individual instances within the supplied time window. EXDATE exclusions 
// are respected. RECURRENCE-ID overrides replace the corresponding generated instance.
// Recurrence expansion is DST-aware: events maintain their wall-clock time across 
// DST transitions (e.g., "5:00 PM every week" stays at 5:00 PM regardless of DST).
//
// DTSTART/DTEND can be in one of three formats:
//   20240115              — all-day (DATE)
//   20240115T140000Z      — UTC datetime (DATE-TIME with Z suffix)
//   20240115T140000       — floating datetime (treated as server local time)
//   DTSTART;TZID=America/Chicago:20240115T140000
//                         — TZID-annotated (converted via qdate_localtime FFI)

// IMPORTS ---------------------------------------------------------------------

import cal.{type Event, type EventTime, AllDay, AtTime, Event}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order.{Eq, Lt}
import gleam/result
import gleam/string
import gleam/string_tree
import gleam/time/calendar.{type Month, Date}
import gleam/time/duration
import gleam/time/timestamp

// FFI -------------------------------------------------------------------------

/// Convert a wall-clock date/time in the named IANA timezone to Gregorian seconds (UTC).
/// On unknown timezone or impossible time (spring-forward gap), falls back to treating
/// the wall-clock time as UTC (same degradation as the old server-offset approach).
/// Gregorian seconds = seconds since year 0000-01-01 (calendar:datetime_to_gregorian_seconds/1).
@external(erlang, "tz_ffi", "local_to_utc")
fn tz_local_to_utc(
  year: Int,
  month: Int,
  day: Int,
  hour: Int,
  minute: Int,
  second: Int,
  tz: String,
) -> Int

/// Convert a UTC date/time to wall-clock time in the named IANA timezone.
/// Returns Gregorian seconds representing the local time.
/// On unknown timezone, returns the input as-is (treats as UTC).
@external(erlang, "tz_ffi", "utc_to_local")
fn tz_utc_to_local(
  year: Int,
  month: Int,
  day: Int,
  hour: Int,
  minute: Int,
  second: Int,
  tz: String,
) -> Int

/// Get the system's IANA timezone identifier (e.g., "America/New_York").
/// Returns an atom that can be checked with is_atom/1 - if it's the atom 'undefined',
/// no system timezone could be determined.
@external(erlang, "tz_ffi", "system_timezone")
fn tz_system_timezone() -> a

@external(erlang, "erlang", "is_binary")
fn is_binary(a: a) -> Bool

@external(erlang, "gleam_stdlib", "identity")
fn unsafe_coerce(a: a) -> b

/// Get the system timezone as a String, or Error if unavailable.
fn get_system_timezone() -> Result(String, Nil) {
  let tz = tz_system_timezone()
  case is_binary(tz) {
    True -> {
      // SAFETY: We just checked it's a binary with is_binary/1.
      // In Gleam/Erlang, binaries and Strings are the same type at runtime.
      Ok(unsafe_coerce(tz))
    }
    False -> Error(Nil)
  }
}

/// Convert Gregorian seconds to a datetime tuple.
/// Returns {{Year, Month, Day}, {Hour, Minute, Second}}
@external(erlang, "calendar", "gregorian_seconds_to_datetime")
fn gregorian_seconds_to_datetime(
  gregorian_secs: Int,
) -> #(#(Int, Int, Int), #(Int, Int, Int))

/// Convert a datetime tuple to Gregorian seconds.
/// Erlang signature: calendar:datetime_to_gregorian_seconds({{Y,M,D},{H,Mi,S}}) -> Int.
@external(erlang, "tz_ffi", "datetime_to_gregorian_seconds")
fn datetime_to_gregorian_seconds(
  year: Int,
  month: Int,
  day: Int,
  hour: Int,
  minute: Int,
  second: Int,
) -> Int

// RECURRENCE TYPES ------------------------------------------------------------

/// Recurrence frequency types from RRULE
type RecurrenceFreq {
  Daily
  Weekly
  Monthly
  Yearly
}

/// Result of a RECURRENCE-ID override lookup for a generated instance.
///
/// * `NoOverride` — no override matched; emit the master-derived instance.
/// * `CancellingOverride` — an override matched and carries STATUS:CANCELLED;
///   skip the instance entirely (RFC 5545 §3.8.1.11).
/// * `ReplacingOverride(Event)` — an override matched; emit it in place of
///   the master-derived instance.
type OverrideResult {
  NoOverride
  CancellingOverride
  ReplacingOverride(Event)
}

/// Days of the week (used for RRULE BYDAY).
type Weekday {
  Monday
  Tuesday
  Wednesday
  Thursday
  Friday
  Saturday
  Sunday
}

/// Parsed RRULE data
type RecurrenceRule {
  RecurrenceRule(
    freq: RecurrenceFreq,
    interval: Int,
    /// BYDAY entries with optional positional prefix (RFC 5545 §3.3.10).
    /// Empty list means "use DTSTART's day-of-week" for weekly, or "use
    /// DTSTART's day-of-month" for monthly.
    ///
    /// Positional prefix semantics:
    ///   * FREQ=MONTHLY: positive N = Nth occurrence of weekday in month;
    ///     negative N = Nth-from-last; absent = every occurrence in month.
    ///   * FREQ=WEEKLY: prefix MUST be ignored (no concept of Nth-in-week).
    byday: List(BydayElem),
    /// BYMONTHDAY values (RFC 5545 §3.3.10). Positive = day of month (1-31);
    /// negative = counting from end (-1 = last day, -2 = second-to-last).
    /// Empty list means "use DTSTART's day-of-month".
    bymonthday: List(Int),
    /// COUNT bound on the recurrence set (RFC 5545 §3.3.10). None = unbounded.
    /// DTSTART always counts as the first occurrence.
    count: Option(Int),
    /// UNTIL bound on the recurrence set (RFC 5545 §3.3.10). None = unbounded.
    /// Inclusive: the last occurrence whose DTSTART equals UNTIL is part of the set.
    /// Same value-type as DTSTART: AllDay for DATE form, AtTime for UTC DATE-TIME form.
    until: Option(EventTime),
    /// WKST (RFC 5545 §3.3.10). The day on which the workweek starts. Default
    /// is Monday. Significant only for FREQ=WEEKLY with INTERVAL>1+BYDAY (and
    /// FREQ=YEARLY with BYWEEKNO, not yet supported). Unrecognized values fall
    /// back to Monday.
    wkst: Weekday,
    /// BYMONTH values (RFC 5545 §3.3.10). Each entry is a month number 1..12.
    /// Empty list means "use DTSTART's month" for FREQ=YEARLY, or no
    /// month-based filter for FREQ=MONTHLY/WEEKLY/DAILY.
    ///
    /// Semantics by FREQ:
    ///   * FREQ=YEARLY: expands — emit one candidate per BYMONTH per year
    ///     (intersected with BYDAY/BYMONTHDAY if present).
    ///   * FREQ=MONTHLY/WEEKLY/DAILY: limits — only candidates whose month
    ///     is in BYMONTH are emitted.
    ///
    /// Invalid entries (≤0 or >12) are silently dropped at parse time.
    bymonth: List(Int),
    /// BYSETPOS values (RFC 5545 §3.3.10). Each entry is a position in the
    /// candidate set generated by other BYxxx rules within one FREQ interval.
    /// Range is 1..366 or -366..-1 (negative counts from end). Empty list
    /// means no position selection.
    ///
    /// Per RFC 5545: BYSETPOS MUST only be used in conjunction with another
    /// BYxxx rule part. When no other BY rule is present, BYSETPOS is ignored.
    ///
    /// Invalid entries (0 or |x| > 366) are silently dropped at parse time.
    bysetpos: List(Int),
    /// BYYEARDAY values (RFC 5545 §3.3.10). Each entry is a day-of-year
    /// ordinal (1..366 or -366..-1; negative counts from the end of the
    /// year). Empty list means no day-of-year filter.
    ///
    /// Per RFC: BYYEARDAY MUST NOT be specified with FREQ=DAILY/WEEKLY/MONTHLY.
    /// We silently ignore it for those frequencies. Only honored for
    /// FREQ=YEARLY.
    ///
    /// Invalid entries (0 or |x| > 366) and unresolvable day-of-year for the
    /// current year (e.g. day 366 in a non-leap year) are dropped.
    byyearday: List(Int),
    /// BYWEEKNO values (RFC 5545 §3.3.10). Each entry is an ISO 8601 week
    /// number (1..53 or -53..-1; negative counts from the end). Empty list
    /// means no week-of-year filter.
    ///
    /// Per RFC: BYWEEKNO MUST NOT be specified with FREQ other than YEARLY.
    /// We silently ignore it for non-YEARLY. ISO 8601: week 1 contains Jan 4.
    /// A year has 53 weeks if Jan 1 is Thursday (or Wednesday in a leap year).
    /// Currently only WKST=MO is supported for BYWEEKNO computations.
    ///
    /// When BYWEEKNO is given without BYDAY, DTSTART's day-of-week is used to
    /// pick the day within each selected week.
    ///
    /// Invalid entries (0 or |x| > 53) and weeks that don't exist in a given
    /// year (e.g. week 53 in a 52-week year) are dropped.
    byweekno: List(Int),
    /// BYHOUR values (RFC 5545 §3.3.10). Each entry is an hour-of-day in
    /// 0..23. Empty list means "use DTSTART's local hour".
    ///
    /// For FREQ=DAILY/WEEKLY/MONTHLY/YEARLY this is an EXPANSION rule: each
    /// candidate timestamp is replaced by one occurrence per BYHOUR entry,
    /// keeping the candidate's local date. (We do not support FREQ=HOURLY/
    /// MINUTELY/SECONDLY where it would act as a limit.)
    ///
    /// Has no effect on AllDay events.
    ///
    /// Invalid entries (<0 or >23) are silently dropped at parse time.
    byhour: List(Int),
    /// BYMINUTE values (RFC 5545 §3.3.10). Each entry is a minute-of-hour in
    /// 0..59. Empty list means "use the candidate's minute". Expansion rule;
    /// see BYHOUR above. Invalid entries are dropped at parse time.
    byminute: List(Int),
    /// BYSECOND values (RFC 5545 §3.3.10). Each entry is a second-of-minute
    /// in 0..60 (60 permitted for leap seconds). Empty list means "use the
    /// candidate's second". Expansion rule; see BYHOUR above. Invalid entries
    /// are dropped at parse time.
    bysecond: List(Int),
  )
}

/// A single BYDAY entry with optional positional prefix (RFC 5545 §3.3.10).
/// Examples: "MO" -> BydayElem(None, Monday); "1MO" -> BydayElem(Some(1), Monday);
/// "-1FR" -> BydayElem(Some(-1), Friday).
type BydayElem {
  BydayElem(pos: Option(Int), day: Weekday)
}

/// Parse an RRULE string to extract FREQ, INTERVAL, BYDAY, COUNT, and UNTIL.
/// Example: "FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,TH;COUNT=10" ->
///   RecurrenceRule(Weekly, 2, [Tuesday, Thursday], Some(10), None)
/// Returns Error if FREQ is missing or unrecognized.
fn parse_rrule(rrule: String) -> Result(RecurrenceRule, Nil) {
  let upper = string.uppercase(rrule)
  let parts = string.split(upper, ";")
  
  // Extract FREQ
  let freq_result = {
    list.find(parts, fn(part) { string.starts_with(part, "FREQ=") })
    |> result.try(fn(freq_part) {
      case string.replace(freq_part, "FREQ=", "") {
        "DAILY" -> Ok(Daily)
        "WEEKLY" -> Ok(Weekly)
        "MONTHLY" -> Ok(Monthly)
        "YEARLY" -> Ok(Yearly)
        _ -> Error(Nil)
      }
    })
  }
  
  // Extract INTERVAL (default to 1 if not present)
  let interval = {
    list.find(parts, fn(part) { string.starts_with(part, "INTERVAL=") })
    |> result.try(fn(interval_part) {
      string.replace(interval_part, "INTERVAL=", "")
      |> int.parse
    })
    |> result.unwrap(1)
  }

  // Extract BYDAY (only honoured for weekly recurrence below).
  // Format: BYDAY=MO,TU,WE  or BYDAY=-1FR,2MO (we ignore the numeric prefix).
  let byday =
    list.find(parts, fn(part) { string.starts_with(part, "BYDAY=") })
    |> result.map(fn(byday_part) {
      string.replace(byday_part, "BYDAY=", "")
      |> parse_byday
    })
    |> result.unwrap([])

  // Extract BYMONTHDAY (optional; RFC 5545 §3.3.10). Comma-separated list of
  // day numbers: positive = day of month (1-31); negative = from end (-1 = last).
  // Invalid entries are silently dropped.
  let bymonthday =
    list.find(parts, fn(part) { string.starts_with(part, "BYMONTHDAY=") })
    |> result.map(fn(part) {
      string.replace(part, "BYMONTHDAY=", "")
      |> string.split(",")
      |> list.filter_map(fn(s) { int.parse(string.trim(s)) })
    })
    |> result.unwrap([])

  // Extract COUNT (optional; RFC 5545 §3.3.10). Invalid integer → ignored.
  let count =
    list.find(parts, fn(part) { string.starts_with(part, "COUNT=") })
    |> result.try(fn(count_part) {
      string.replace(count_part, "COUNT=", "") |> int.parse
    })
    |> option.from_result

  // Extract UNTIL (optional; RFC 5545 §3.3.10). Same value-type as DTSTART:
  // DATE form (8 digits) → AllDay; UTC DATE-TIME form (ending "Z") → AtTime.
  // Malformed UNTIL → ignored (None).
  let until =
    list.find(parts, fn(part) { string.starts_with(part, "UNTIL=") })
    |> result.map(fn(until_part) {
      string.replace(until_part, "UNTIL=", "")
    })
    |> option.from_result
    |> option.then(fn(until_str) {
      case string.ends_with(until_str, "Z") {
        True ->
          parse_datetime(until_str)
          |> result.map(AtTime)
          |> option.from_result
        False ->
          parse_date(until_str)
          |> result.map(AllDay)
          |> option.from_result
      }
    })

  // Extract WKST (optional; RFC 5545 §3.3.10). Default Monday. Unrecognized
  // values fall back to Monday.
  let wkst =
    list.find(parts, fn(part) { string.starts_with(part, "WKST=") })
    |> result.try(fn(part) {
      string.replace(part, "WKST=", "")
      |> parse_weekday
    })
    |> result.unwrap(Monday)

  // Extract BYMONTH (optional; RFC 5545 §3.3.10). Comma-separated list of
  // month numbers 1..12. Invalid entries are dropped.
  let bymonth =
    list.find(parts, fn(part) { string.starts_with(part, "BYMONTH=") })
    |> result.map(fn(part) {
      string.replace(part, "BYMONTH=", "")
      |> string.split(",")
      |> list.filter_map(fn(s) {
        case int.parse(string.trim(s)) {
          Ok(n) ->
            case n >= 1 && n <= 12 {
              True -> Ok(n)
              False -> Error(Nil)
            }
          Error(Nil) -> Error(Nil)
        }
      })
    })
    |> result.unwrap([])

  // Extract BYSETPOS (optional; RFC 5545 §3.3.10). Comma-separated list of
  // positions in the candidate set. Valid range: 1..366 or -366..-1.
  // Invalid entries (0 or |x| > 366) are silently dropped.
  let bysetpos =
    list.find(parts, fn(part) { string.starts_with(part, "BYSETPOS=") })
    |> result.map(fn(part) {
      string.replace(part, "BYSETPOS=", "")
      |> string.split(",")
      |> list.filter_map(fn(s) {
        case int.parse(string.trim(s)) {
          Ok(n) ->
            case n != 0 && n >= -366 && n <= 366 {
              True -> Ok(n)
              False -> Error(Nil)
            }
          Error(Nil) -> Error(Nil)
        }
      })
    })
    |> result.unwrap([])

  // Extract BYYEARDAY (optional; RFC 5545 §3.3.10). Comma-separated list of
  // day-of-year ordinals. Valid range: 1..366 or -366..-1.
  // Invalid entries (0 or |x| > 366) are silently dropped.
  let byyearday =
    list.find(parts, fn(part) { string.starts_with(part, "BYYEARDAY=") })
    |> result.map(fn(part) {
      string.replace(part, "BYYEARDAY=", "")
      |> string.split(",")
      |> list.filter_map(fn(s) {
        case int.parse(string.trim(s)) {
          Ok(n) ->
            case n != 0 && n >= -366 && n <= 366 {
              True -> Ok(n)
              False -> Error(Nil)
            }
          Error(Nil) -> Error(Nil)
        }
      })
    })
    |> result.unwrap([])

  // Extract BYWEEKNO (optional; RFC 5545 §3.3.10). Comma-separated list of
  // ISO 8601 week numbers. Valid range: 1..53 or -53..-1.
  // Invalid entries (0 or |x| > 53) are silently dropped.
  let byweekno =
    list.find(parts, fn(part) { string.starts_with(part, "BYWEEKNO=") })
    |> result.map(fn(part) {
      string.replace(part, "BYWEEKNO=", "")
      |> string.split(",")
      |> list.filter_map(fn(s) {
        case int.parse(string.trim(s)) {
          Ok(n) ->
            case n != 0 && n >= -53 && n <= 53 {
              True -> Ok(n)
              False -> Error(Nil)
            }
          Error(Nil) -> Error(Nil)
        }
      })
    })
    |> result.unwrap([])

  // Extract BYHOUR (optional; RFC 5545 §3.3.10). Comma-separated list of
  // hours 0..23. Invalid entries are silently dropped.
  let byhour =
    list.find(parts, fn(part) { string.starts_with(part, "BYHOUR=") })
    |> result.map(fn(part) {
      string.replace(part, "BYHOUR=", "")
      |> string.split(",")
      |> list.filter_map(fn(s) {
        case int.parse(string.trim(s)) {
          Ok(n) ->
            case n >= 0 && n <= 23 {
              True -> Ok(n)
              False -> Error(Nil)
            }
          Error(Nil) -> Error(Nil)
        }
      })
    })
    |> result.unwrap([])

  // Extract BYMINUTE (optional; RFC 5545 §3.3.10). Comma-separated list of
  // minutes 0..59. Invalid entries are silently dropped.
  let byminute =
    list.find(parts, fn(part) { string.starts_with(part, "BYMINUTE=") })
    |> result.map(fn(part) {
      string.replace(part, "BYMINUTE=", "")
      |> string.split(",")
      |> list.filter_map(fn(s) {
        case int.parse(string.trim(s)) {
          Ok(n) ->
            case n >= 0 && n <= 59 {
              True -> Ok(n)
              False -> Error(Nil)
            }
          Error(Nil) -> Error(Nil)
        }
      })
    })
    |> result.unwrap([])

  // Extract BYSECOND (optional; RFC 5545 §3.3.10). Comma-separated list of
  // seconds 0..60 (60 permitted for leap seconds). Invalid entries dropped.
  let bysecond =
    list.find(parts, fn(part) { string.starts_with(part, "BYSECOND=") })
    |> result.map(fn(part) {
      string.replace(part, "BYSECOND=", "")
      |> string.split(",")
      |> list.filter_map(fn(s) {
        case int.parse(string.trim(s)) {
          Ok(n) ->
            case n >= 0 && n <= 60 {
              True -> Ok(n)
              False -> Error(Nil)
            }
          Error(Nil) -> Error(Nil)
        }
      })
    })
    |> result.unwrap([])

  use freq <- result.try(freq_result)
  Ok(RecurrenceRule(
    freq:,
    interval:,
    byday:,
    bymonthday:,
    count:,
    until:,
    wkst:,
    bymonth:,
    bysetpos:,
    byyearday:,
    byweekno:,
    byhour:,
    byminute:,
    bysecond:,
  ))
}

/// Parse a BYDAY value list (comma-separated). Returns BydayElems preserving
/// any positional prefix (e.g. "-1FR" -> BydayElem(Some(-1), Friday)).
/// Plain entries (e.g. "MO") have pos=None.
fn parse_byday(s: String) -> List(BydayElem) {
  string.split(s, ",")
  |> list.filter_map(fn(part) { parse_byday_elem(string.trim(part)) })
}

/// Parse one BYDAY entry: optional signed integer prefix followed by a
/// 2-letter weekday code. "1MO" -> Some(1) + Monday; "MO" -> None + Monday;
/// "-1FR" -> Some(-1) + Friday. Invalid entries return Error(Nil).
fn parse_byday_elem(s: String) -> Result(BydayElem, Nil) {
  let len = string.length(s)
  case len < 2 {
    True -> Error(Nil)
    False -> {
      let day_str = string.slice(s, len - 2, 2)
      let prefix_str = string.slice(s, 0, len - 2)
      use day <- result.try(parse_weekday(day_str))
      let pos = case string.is_empty(prefix_str) {
        True -> None
        False ->
          int.parse(prefix_str)
          |> option.from_result
      }
      Ok(BydayElem(pos:, day:))
    }
  }
}

/// Parse an RFC 5545 weekday code: MO/TU/WE/TH/FR/SA/SU (case-insensitive).
fn parse_weekday(s: String) -> Result(Weekday, Nil) {
  case string.uppercase(s) {
    "MO" -> Ok(Monday)
    "TU" -> Ok(Tuesday)
    "WE" -> Ok(Wednesday)
    "TH" -> Ok(Thursday)
    "FR" -> Ok(Friday)
    "SA" -> Ok(Saturday)
    "SU" -> Ok(Sunday)
    _ -> Error(Nil)
  }
}

/// Index 0=Mon..6=Sun (matches WKST=MO weekly semantics).
fn weekday_to_mon0(w: Weekday) -> Int {
  case w {
    Monday -> 0
    Tuesday -> 1
    Wednesday -> 2
    Thursday -> 3
    Friday -> 4
    Saturday -> 5
    Sunday -> 6
  }
}

/// Index 0..6 where 0 is the WKST day, increasing through the week.
/// Examples (WKST=SU): SU=0, MO=1, TU=2, ..., SA=6.
fn weekday_to_wkst_index(w: Weekday, wkst: Weekday) -> Int {
  let w_mon0 = weekday_to_mon0(w)
  let wkst_mon0 = weekday_to_mon0(wkst)
  let diff = w_mon0 - wkst_mon0
  case diff < 0 {
    True -> diff + 7
    False -> diff
  }
}

/// WKST-relative index (0..6) for the week containing `date`. Returns the
/// number of days from the WKST-week start to `date`.
fn date_weekday_wkst_index(date: calendar.Date, wkst: Weekday) -> Int {
  let mon0 = date_weekday_mon0(date)
  let wkst_mon0 = weekday_to_mon0(wkst)
  let diff = mon0 - wkst_mon0
  case diff < 0 {
    True -> diff + 7
    False -> diff
  }
}

/// Compute day-of-week for a Date using Sakamoto's algorithm. 0=Mon..6=Sun.
fn date_weekday_mon0(date: calendar.Date) -> Int {
  let t = [0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4]
  let y = case calendar.month_to_int(date.month) < 3 {
    True -> date.year - 1
    False -> date.year
  }
  let m_idx = calendar.month_to_int(date.month) - 1
  let tm = case list.take(list.drop(t, m_idx), 1) {
    [v] -> v
    _ -> 0
  }
  // Zeller-style: returns 0=Sun..6=Sat. Convert to 0=Mon..6=Sun.
  let sun0 =
    { y + y / 4 - y / 100 + y / 400 + tm + date.day }
    |> int.remainder(7)
    |> result.unwrap(0)
  let sun0_pos = case sun0 < 0 {
    True -> sun0 + 7
    False -> sun0
  }
  // 0=Sun..6=Sat → 0=Mon..6=Sun
  case sun0_pos {
    0 -> 6
    _ -> sun0_pos - 1
  }
}

/// Move a Date by exactly `n` days (n may be negative).
fn shift_date_days(date: calendar.Date, n: Int) -> calendar.Date {
  case int.compare(n, 0) {
    order.Eq -> date
    order.Gt -> shift_date_days(advance_one_day(date), n - 1)
    order.Lt -> shift_date_days(retreat_one_day(date), n + 1)
  }
}

fn retreat_one_day(date: calendar.Date) -> calendar.Date {
  case date.day > 1 {
    True -> calendar.Date(..date, day: date.day - 1)
    False ->
      case date.month {
        calendar.January ->
          calendar.Date(
            year: date.year - 1,
            month: calendar.December,
            day: 31,
          )
        _ -> {
          let prev = prev_month_cal(date.month)
          calendar.Date(..date, month: prev, day: days_in_month(prev, date.year))
        }
      }
  }
}

fn prev_month_cal(m: calendar.Month) -> calendar.Month {
  case m {
    calendar.January -> calendar.December
    calendar.February -> calendar.January
    calendar.March -> calendar.February
    calendar.April -> calendar.March
    calendar.May -> calendar.April
    calendar.June -> calendar.May
    calendar.July -> calendar.June
    calendar.August -> calendar.July
    calendar.September -> calendar.August
    calendar.October -> calendar.September
    calendar.November -> calendar.October
    calendar.December -> calendar.November
  }
}

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
  let system_tz = get_system_timezone()

  let raw_vevents =
    ical_text
    |> unfold_lines
    |> split_vevents

  // Separate masters from overrides
  let masters =
    raw_vevents
    |> list.filter(fn(lines) { !has_prop(lines, "RECURRENCE-ID") })
    // Drop masters with STATUS:CANCELLED — the entire series is suppressed
    // (RFC 5545 §3.8.1.11). For non-recurring events this also drops the
    // single instance.
    |> list.filter(fn(lines) {
      let props = list.filter_map(lines, parse_property)
      !props_status_cancelled(props)
    })
  let overrides =
    list.filter(raw_vevents, fn(lines) { has_prop(lines, "RECURRENCE-ID") })

  list.flat_map(masters, fn(lines) {
    expand_vevent(
      lines,
      overrides,
      calendar_name,
      local_offset,
      system_tz,
      window_start,
      window_end,
    )
  })
}

// LINE UNFOLDING --------------------------------------------------------------

/// RFC 5545 §3.1: long lines may be folded by inserting CRLF + whitespace.
/// Also normalizes line endings: CRLF and bare CR (legacy Lotus Notes) are
/// both converted to bare LF so that downstream `string.split(_, "\n")`
/// produces clean lines. Folding continuations (LF + space/tab) are then
/// collapsed.
fn unfold_lines(text: String) -> String {
  text
  // Normalize line endings to LF first so the folding step only has to
  // handle one form. Order matters: CRLF must be collapsed before bare CR
  // is rewritten, otherwise the LF half of a CRLF pair becomes a duplicate
  // line break.
  |> string.replace("\r\n", "\n")
  |> string.replace("\r", "\n")
  // Now unfold: LF followed by a single space or tab continues the
  // previous logical line. Per RFC 5545 the leading whitespace itself
  // is consumed along with the line break.
  |> string.replace("\n ", "")
  |> string.replace("\n\t", "")
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
      // RFC 5545 §3.1: property and component names are case-insensitive.
      // Match BEGIN/END markers on the uppercased line so producers that
      // emit "begin:vevent" or "Begin:VEvent" parse correctly.
      case string.uppercase(trimmed) {
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
  system_tz: Result(String, Nil),
  window_start: timestamp.Timestamp,
  window_end: timestamp.Timestamp,
) -> List(Event) {
  let props = list.filter_map(lines, parse_property)

  case get_prop(props, "UID"), get_prop(props, "SUMMARY") {
    Ok(uid), Ok(summary_raw) -> {
      let summary = unescape_text(summary_raw)
      let location =
        get_prop(props, "LOCATION") |> result.unwrap("") |> unescape_text
      let description =
        get_prop(props, "DESCRIPTION") |> result.unwrap("") |> unescape_text
      let url = get_prop(props, "URL") |> result.unwrap("")
      // TRANSP:TRANSPARENT means the event does not block the person as busy.
      let free =
        get_prop(props, "TRANSP")
        |> result.unwrap("OPAQUE")
        |> string.uppercase
        == "TRANSPARENT"
      let dtstart_tzid = get_tzid_param(lines, "DTSTART")
      // If DTSTART has TZID and DTEND is floating (no TZID, no Z), inherit
      // DTSTART's timezone for DTEND — some servers emit mixed-type start/end.
      let dtend_tzid = case get_tzid_param(lines, "DTEND") {
        Ok(tz) -> Ok(tz)
        Error(Nil) ->
          // If DTSTART has TZID and DTEND is floating (no TZID, no Z), inherit
          // DTSTART's timezone for DTEND — some servers emit mixed-type start/end.
          case dtstart_tzid, get_prop_prefix(props, "DTEND") {
            Ok(tz), Ok(v) ->
              case is_floating_datetime(v) {
                True -> Ok(tz)
                False -> Error(Nil)
              }
            _, _ -> Error(Nil)
          }
      }

      case get_prop_prefix(props, "DTSTART") {
        Ok(dtstart_raw) -> {
          case parse_event_time(dtstart_raw, dtstart_tzid, system_tz) {
            Ok(start) -> {
              case derive_event_end(start, props, lines, dtend_tzid, system_tz)
              {
                Ok(end) -> {
              // Parse RRULE to check for recurrence
              let recurrence = case get_prop(props, "RRULE") {
                Ok(rrule) -> parse_rrule(rrule)
                Error(Nil) -> Error(Nil)
              }

              // Collect EXDATEs and RDATEs (used by both branches)
              let exdates = collect_exdates(lines, system_tz)
              let rdates = collect_rdates(lines, system_tz)
              let duration_secs = event_duration_secs(start, end)

              case recurrence {
                Error(Nil) -> {
                  // Non-recurring: emit the master event (if in window),
                  // plus any RDATE-derived events. Apply EXDATE filter.
                  let master_event = Event(
                    uid:,
                    summary:,
                    start:,
                    end:,
                    calendar_name:,
                    location:,
                    free:,
                    description:,
                    url:,
                  )
                  let master_in_window =
                    event_in_window(start, end, window_start, window_end)
                  let base_events = case master_in_window {
                    True -> [master_event]
                    False -> []
                  }
                  // Generate RDATE events, then merge + dedupe
                  let merged =
                    merge_rdate_events(
                      rdates,
                      base_events,
                      duration_secs,
                      uid,
                      summary,
                      calendar_name,
                      location,
                      free,
                      description,
                      url,
                      local_offset,
                      window_start,
                      window_end,
                    )
                  // Apply EXDATE filter
                  list.filter(merged, fn(e) {
                    !list.any(exdates, fn(ex) {
                      event_times_equal(e.start, ex)
                    })
                  })
                }
                Ok(rrule) -> {
                  // Find overrides for this UID
                  let uid_overrides =
                    list.filter(overrides, fn(ol) {
                      let oprops = list.filter_map(ol, parse_property)
                      get_prop(oprops, "UID") == Ok(uid)
                    })

                  // Generate recurring instances within window
                  // Determine the event timezone: TZID if present, otherwise system_tz for floating
                  let event_tz = result.or(dtstart_tzid, system_tz)
                  expand_recurring(
                    rrule,
                    uid,
                    summary,
                    calendar_name,
                    location,
                    free,
                    description,
                    url,
                    start,
                    end,
                    duration_secs,
                    exdates,
                    rdates,
                    uid_overrides,
                    local_offset,
                    system_tz,
                    event_tz,
                    window_start,
                    window_end,
                  )
                }
              }
                }
                Error(Nil) -> []
              }
            }
            Error(Nil) -> []
          }
        }
        Error(Nil) -> []
      }
    }
    _, _ -> []
  }
}

/// Generate recurring occurrences of an event within [window_start, window_end).
/// - Skip dates in exdates
/// - Replace instances that have a matching RECURRENCE-ID override
/// - Add explicit RDATE occurrences (deduped vs RRULE results)
/// Dispatches to timed or all-day expansion based on master_start type.
fn expand_recurring(
  rrule: RecurrenceRule,
  uid: String,
  summary: String,
  calendar_name: String,
  location: String,
  free: Bool,
  description: String,
  url: String,
  master_start: EventTime,
  master_end: EventTime,
  duration_secs: Int,
  exdates: List(EventTime),
  rdates: List(EventTime),
  uid_overrides: List(List(String)),
  local_offset: duration.Duration,
  system_tz: Result(String, Nil),
  event_tz: Result(String, Nil),
  window_start: timestamp.Timestamp,
  window_end: timestamp.Timestamp,
) -> List(Event) {
  let override_events =
    list.filter_map(uid_overrides, fn(lines) {
      parse_override_event(lines, uid, calendar_name, local_offset, system_tz)
    })

  let instances = case master_start {
    AtTime(base_ts) ->
      // Timed recurring event: expand by advancing timestamps.
      generate_recurring_timed(
        rrule,
        base_ts,
        base_ts,
        rrule.count,
        duration_secs,
        exdates,
        uid_overrides,
        uid,
        summary,
        calendar_name,
        location,
        free,
        description,
        url,
        local_offset,
        system_tz,
        event_tz,
        window_start,
        window_end,
        [],
      )
    AllDay(base_date) -> {
      // All-day recurring event: compute the event's day-count duration,
      // then expand by advancing the date.
      let day_count = case master_end {
        AllDay(end_date) -> date_day_count(base_date, end_date)
        _ -> 1
      }
      let window_start_date =
        timestamp.to_calendar(window_start, local_offset).0
      let window_end_date = timestamp.to_calendar(window_end, local_offset).0
      generate_recurring_allday(
        rrule,
        base_date,
        base_date,
        rrule.count,
        day_count,
        exdates,
        uid_overrides,
        uid,
        summary,
        calendar_name,
        location,
        free,
        description,
        url,
        local_offset,
        system_tz,
        window_start_date,
        window_end_date,
        [],
      )
    }
  }

  // Merge RDATE-derived events with RRULE instances (deduplicated by start).
  // RDATE events that match an EXDATE are excluded.
  let rdates_filtered =
    list.filter(rdates, fn(rd) {
      !list.any(exdates, fn(ex) { event_times_equal(rd, ex) })
    })
  let instances_with_rdates =
    merge_rdate_events(
      rdates_filtered,
      instances,
      duration_secs,
      uid,
      summary,
      calendar_name,
      location,
      free,
      description,
      url,
      local_offset,
      window_start,
      window_end,
    )

  // Also include override events that fall in the window but weren't covered
  // by the generated instances (e.g. the original occurrence was outside the
  // window but the override's actual DTSTART is inside).
  let override_in_window =
    list.filter(override_events, fn(e) {
      event_in_window(e.start, e.end, window_start, window_end)
      &&       !list.any(instances_with_rdates, fn(i) {
        i.uid == e.uid && times_equal(i.start, e.start)
      })
    })

  list.append(instances_with_rdates, override_in_window)
}

/// Advance a Date by exactly `n` days using calendar arithmetic.
fn advance_date_by_n(date: calendar.Date, n: Int) -> calendar.Date {
  case n <= 0 {
    True -> date
    False -> advance_date_by_n(advance_one_day(date), n - 1)
  }
}

/// Advance a Date by exactly `n` months using calendar arithmetic.
fn advance_date_by_months(date: calendar.Date, n: Int) -> calendar.Date {
  case n <= 0 {
    True -> date
    False -> advance_date_by_months(advance_one_month(date), n - 1)
  }
}

/// Advance a Date by exactly `n` years using calendar arithmetic.
fn advance_date_by_years(date: calendar.Date, n: Int) -> calendar.Date {
  calendar.Date(..date, year: date.year + n)
}

fn advance_one_month(date: calendar.Date) -> calendar.Date {
  case date.month {
    calendar.December ->
      calendar.Date(year: date.year + 1, month: calendar.January, day: date.day)
    _ -> calendar.Date(..date, month: next_month_cal(date.month))
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

/// Expand an all-day recurring event within [window_start_date, window_end_date).
fn generate_recurring_allday(
  rrule: RecurrenceRule,
  current_date: calendar.Date,
  master_start_date: calendar.Date,
  remaining: Option(Int),
  day_count: Int,
  exdates: List(EventTime),
  uid_overrides: List(List(String)),
  uid: String,
  summary: String,
  calendar_name: String,
  location: String,
  free: Bool,
  description: String,
  url: String,
  local_offset: duration.Duration,
  system_tz: Result(String, Nil),
  window_start_date: calendar.Date,
  window_end_date: calendar.Date,
  acc: List(Event),
) -> List(Event) {
  let RecurrenceRule(
    freq,
    interval,
    byday,
    bymonthday,
    _count,
    until,
    wkst,
    bymonth,
    bysetpos,
    byyearday,
    byweekno,
    _byhour,
    _byminute,
    _bysecond,
  ) = rrule

  // When BYDAY is used, an iteration's emitted days may fall outside the
  // anchor's date itself: by up to 6 days for weekly+BYDAY (the BYDAY week
  // straddles the anchor) and up to ~30 days for monthly+BYDAY (e.g. anchor
  // on the 1st with BYDAY=-1FR landing near the 30th, or vice versa).
  // Extend the termination guard accordingly to avoid skipping in-window
  // emissions on the final iteration before window_end.
  let buffer_days = case freq, byday, bymonthday, bymonth, byyearday, byweekno {
    Weekly, [_, ..], _, _, _, _ -> 7
    Monthly, [_, ..], _, _, _, _ -> 31
    Monthly, [], [_, ..], _, _, _ -> 31
    Yearly, _, _, [_, ..], _, _ -> 366
    Yearly, _, _, _, [_, ..], _ -> 366
    Yearly, _, _, _, _, [_, ..] -> 366
    _, _, _, _, _, _ -> 0
  }
  let buffered_window_end_date =
    advance_date_by_n(window_end_date, buffer_days)

  // Stop when current_date >= window_end_date (no more overlap possible).
  // Guard against infinite loops: if we've gone more than 500 intervals past the window.
  let past_end = !date_before(current_date, buffered_window_end_date)
  let too_far =
    !date_before(current_date, advance_date_by_n(window_end_date, 500 * 7))
  let count_done = remaining == Some(0)
  // Stop when current_date is past UNTIL (plus BYDAY buffer) — no candidate
  // can be ≤ UNTIL after that point. Only honoured when UNTIL has the same
  // value-type as DTSTART (DATE here).
  let until_done = case until {
    Some(AllDay(u_date)) -> {
      let cutoff = advance_date_by_n(u_date, buffer_days)
      date_before(cutoff, current_date)
    }
    _ -> False
  }

  case past_end || too_far || count_done || until_done {
    True -> list.reverse(acc)
    False -> {
      // Advance the date based on frequency and interval
      let next_date = case freq {
        Daily -> advance_date_by_n(current_date, interval)
        Weekly -> advance_date_by_n(current_date, interval * 7)
        Monthly -> advance_date_by_months(current_date, interval)
        Yearly -> advance_date_by_years(current_date, interval)
      }

      // Determine all candidate dates for this iteration's expansion, then
      // drop any that fall before DTSTART (phantom first-week/month BYDAY days
      // that are not part of the recurrence set) or after UNTIL (RFC 5545
      // §3.3.10 bound; UNTIL is inclusive).
      let raw_candidates = case
        freq, byday, bymonthday, bymonth, byyearday, byweekno
      {
        // Yearly + BYYEARDAY: expand per yearday position (highest priority
        // for Yearly).
        Yearly, _, _, _, [_, ..], _ ->
          yearly_byyearday_dates(current_date, byyearday)
        // Yearly + BYWEEKNO: expand per ISO week (after BYYEARDAY).
        Yearly, _, _, _, [], [_, ..] ->
          yearly_byweekno_dates(current_date, byweekno, master_start_date)
        // Yearly + BYMONTH (without BYYEARDAY/BYWEEKNO): expand per month.
        Yearly, _, _, [_, ..], [], [] ->
          yearly_bymonth_dates(current_date, byday, bymonthday, bymonth)
        Weekly, [_, ..], _, _, _, _ ->
          weekly_byday_dates(current_date, byday, wkst)
        Monthly, [_, ..], _, _, _, _ ->
          monthly_byday_dates(current_date, byday)
        Monthly, [], [_, ..], _, _, _ -> {
          let year = current_date.year
          let month = current_date.month
          monthly_bymonthday_dates(year, month, bymonthday)
        }
        _, _, _, _, _, _ -> [current_date]
      }
      // For non-Yearly frequencies with BYMONTH, filter candidates by month.
      // (Yearly+BYMONTH/BYYEARDAY were already expanded above.)
      let raw_candidates = case freq, bymonth {
        Yearly, _ -> raw_candidates
        _, [] -> raw_candidates
        _, _ ->
          list.filter(raw_candidates, fn(d) {
            list.contains(bymonth, calendar.month_to_int(d.month))
          })
      }
      // BYSETPOS post-filter (RFC 5545 §3.3.10). Must be used in conjunction
      // with another BYxxx rule; otherwise ignored.
      let raw_candidates = case bysetpos, byday, bymonthday, bymonth {
        [], _, _, _ -> raw_candidates
        _, [], [], [] -> raw_candidates
        _, _, _, _ -> apply_bysetpos_dates(raw_candidates, bysetpos)
      }
      let candidate_dates =
        list.filter(raw_candidates, fn(d) {
          let after_start = !date_before(d, master_start_date)
          let until_ok = case until {
            Some(AllDay(u_date)) -> !date_before(u_date, d)
            _ -> True
          }
          after_start && until_ok
        })

      // Apply COUNT bound: take at most `remaining` candidates this iteration.
      // Each taken candidate consumes one slot regardless of EXDATE / window.
      let to_emit = case remaining {
        Some(n) -> list.take(candidate_dates, n)
        None -> candidate_dates
      }
      let new_remaining = case remaining {
        Some(n) -> Some(n - list.length(to_emit))
        None -> None
      }

      let new_events =
        list.filter_map(to_emit, fn(d) {
          allday_instance_for_date(
            d,
            day_count,
            exdates,
            uid_overrides,
            uid,
            summary,
            calendar_name,
            location,
            free,
            description,
            url,
            local_offset,
            system_tz,
            window_start_date,
            window_end_date,
          )
        })

      let new_acc = list.fold(new_events, acc, fn(a, e) { [e, ..a] })

      generate_recurring_allday(
        rrule,
        next_date,
        master_start_date,
        new_remaining,
        day_count,
        exdates,
        uid_overrides,
        uid,
        summary,
        calendar_name,
        location,
        free,
        description,
        url,
        local_offset,
        system_tz,
        window_start_date,
        window_end_date,
        new_acc,
      )
    }
  }
}

/// Build an Event from a candidate all-day date, applying window, EXDATE, and
/// RECURRENCE-ID override checks.
fn allday_instance_for_date(
  current_date: calendar.Date,
  day_count: Int,
  exdates: List(EventTime),
  uid_overrides: List(List(String)),
  uid: String,
  summary: String,
  calendar_name: String,
  location: String,
  free: Bool,
  description: String,
  url: String,
  local_offset: duration.Duration,
  system_tz: Result(String, Nil),
  window_start_date: calendar.Date,
  window_end_date: calendar.Date,
) -> Result(Event, Nil) {
  let instance_end_date = advance_date_by_n(current_date, day_count)

  // In window if instance start < window_end AND instance end > window_start
  let in_window =
    date_before(current_date, window_end_date)
    && !date_before(instance_end_date, window_start_date)
    && calendar.naive_date_compare(instance_end_date, window_start_date)
    != order.Eq

  case in_window {
    False -> Error(Nil)
    True -> {
      // Check EXDATE: an EXDATE matching this date excludes the instance.
      let is_excluded =
        list.any(exdates, fn(ex) {
          exdate_matches_date(current_date, ex, local_offset)
        })

      case is_excluded {
        True -> Error(Nil)
        False ->
          case
            find_allday_override_for_date(
              current_date,
              uid_overrides,
              uid,
              calendar_name,
              local_offset,
              system_tz,
            )
          {
            CancellingOverride -> Error(Nil)
            ReplacingOverride(override_evt) -> Ok(override_evt)
            NoOverride ->
              Ok(Event(
                uid:,
                summary:,
                start: AllDay(current_date),
                end: AllDay(instance_end_date),
                calendar_name:,
                location:,
                free:,
                description:,
                url:,
              ))
          }
      }
    }
  }
}

/// All-day variant of `find_override_for_ts`. Matches an override whose
/// RECURRENCE-ID's local date equals `current_date`. Returns NoOverride,
/// CancellingOverride, or ReplacingOverride per the same semantics.
///
/// THISANDFUTURE handling for all-day series: the override's properties
/// (summary, location, description, etc.) propagate to the matched date
/// and all subsequent ones, but dates are NOT shifted even if the
/// override's DTSTART differs from its RECURRENCE-ID. Date-shifting an
/// all-day recurrence via THISANDFUTURE is not a well-defined transform
/// and is silently ignored; only the metadata change is honored.
fn find_allday_override_for_date(
  current_date: calendar.Date,
  uid_overrides: List(List(String)),
  uid: String,
  calendar_name: String,
  local_offset: duration.Duration,
  system_tz: Result(String, Nil),
) -> OverrideResult {
  // Parse each override into (lines, props, rec_id_date, is_thisandfuture).
  let parsed =
    list.filter_map(uid_overrides, fn(ol) {
      let oprops = list.filter_map(ol, parse_property)
      case get_prop_prefix(oprops, "RECURRENCE-ID") {
        Ok(rec_raw) ->
          case parse_event_time(rec_raw, Error(Nil), system_tz) {
            Ok(AllDay(rec_date)) ->
              Ok(#(ol, oprops, rec_date, has_thisandfuture_range(ol)))
            Ok(AtTime(rec_ts)) -> {
              let #(rec_date, _) =
                timestamp.to_calendar(rec_ts, local_offset)
              Ok(#(ol, oprops, rec_date, has_thisandfuture_range(ol)))
            }
            Error(Nil) -> Error(Nil)
          }
        Error(Nil) -> Error(Nil)
      }
    })

  // (1) Single-instance match (RANGE absent).
  let single =
    list.find(parsed, fn(p) {
      let #(_, _, rec_date, is_taf) = p
      !is_taf && rec_date == current_date
    })

  case single {
    Ok(#(ol, oprops, _, _)) ->
      apply_allday_override(
        ol,
        oprops,
        uid,
        calendar_name,
        local_offset,
        system_tz,
      )
    Error(Nil) -> {
      // (2) Most recent THISANDFUTURE with rec_date <= current_date.
      let candidate =
        list.fold(parsed, Error(Nil), fn(acc, p) {
          let #(_, _, rec_date, is_taf) = p
          case
            is_taf
            && calendar.naive_date_compare(rec_date, current_date) != order.Gt
          {
            False -> acc
            True ->
              case acc {
                Error(Nil) -> Ok(p)
                Ok(#(_, _, best_date, _)) ->
                  case calendar.naive_date_compare(rec_date, best_date) {
                    order.Gt -> Ok(p)
                    _ -> acc
                  }
              }
          }
        })
      case candidate {
        Ok(#(ol, oprops, _, _)) ->
          apply_allday_override(
            ol,
            oprops,
            uid,
            calendar_name,
            local_offset,
            system_tz,
          )
        Error(Nil) -> NoOverride
      }
    }
  }
}

/// All-day variant of apply_timed_override. No date-shifting is performed
/// because all-day THISANDFUTURE overrides reasonably only change metadata,
/// not the schedule.
fn apply_allday_override(
  ol: List(String),
  oprops: List(#(String, String)),
  uid: String,
  calendar_name: String,
  local_offset: duration.Duration,
  system_tz: Result(String, Nil),
) -> OverrideResult {
  case props_status_cancelled(oprops) {
    True -> CancellingOverride
    False ->
      case
        parse_override_event(ol, uid, calendar_name, local_offset, system_tz)
      {
        Ok(evt) -> ReplacingOverride(evt)
        Error(Nil) -> NoOverride
      }
  }
}

/// For a weekly+BYDAY all-day recurrence, compute each BYDAY day's date in
/// the iteration anchor's (Monday-start) week. Positional prefixes are
/// ignored per RFC 5545 (FREQ=WEEKLY has no Nth-in-week semantics).
/// For a weekly+BYDAY recurrence, compute the set of candidate dates within
/// the WKST-week containing `current_date`. Per RFC 5545 §3.3.10, the WKST
/// rule part defines the week boundary; with WKST=MO the week runs Monday→
/// Sunday, with WKST=SU it runs Sunday→Saturday, etc.
///
/// Candidates are returned in chronological (date) order so that emission is
/// deterministic regardless of BYDAY list ordering and consistent across
/// WKST values.
fn weekly_byday_dates(
  current_date: calendar.Date,
  byday: List(BydayElem),
  wkst: Weekday,
) -> List(calendar.Date) {
  let current_idx = date_weekday_wkst_index(current_date, wkst)
  list.map(byday, fn(b) {
    let target_idx = weekday_to_wkst_index(b.day, wkst)
    let offset = target_idx - current_idx
    shift_date_days(current_date, offset)
  })
  |> list.sort(calendar.naive_date_compare)
}

/// For a monthly+BYDAY recurrence, compute candidate dates in the same month
/// as `current_date` per RFC 5545 §3.3.10:
///   * Some(n), n > 0 → the Nth occurrence of the weekday in the month.
///   * Some(n), n < 0 → the Nth-from-last occurrence.
///   * None → every occurrence of the weekday in the month.
///   * Some(0) → invalid; entry dropped.
/// Entries that don't exist in the given month (e.g. a 5th Monday in a
/// 4-Monday month) are silently dropped.
fn monthly_byday_dates(
  current_date: calendar.Date,
  byday: List(BydayElem),
) -> List(calendar.Date) {
  let year = current_date.year
  let month = current_date.month
  list.flat_map(byday, fn(b) {
    case b.pos {
      Some(n) ->
        case int.compare(n, 0) {
          order.Gt ->
            case nth_weekday_of_month(year, month, b.day, n) {
              Ok(d) -> [d]
              Error(Nil) -> []
            }
          order.Lt ->
            case nth_from_last_weekday_of_month(year, month, b.day, -n) {
              Ok(d) -> [d]
              Error(Nil) -> []
            }
          order.Eq -> []
        }
      None -> all_weekdays_in_month(year, month, b.day)
    }
  })
}

/// Return the date of the Nth occurrence of `target` weekday in the given
/// month (N ≥ 1). Error if N is < 1 or exceeds the count of that weekday.
fn nth_weekday_of_month(
  year: Int,
  month: calendar.Month,
  target: Weekday,
  n: Int,
) -> Result(calendar.Date, Nil) {
  case n < 1 {
    True -> Error(Nil)
    False -> {
      let first = Date(year: year, month: month, day: 1)
      let first_dow = date_weekday_mon0(first)
      let target_dow = weekday_to_mon0(target)
      let raw_offset = target_dow - first_dow
      let offset = case raw_offset < 0 {
        True -> raw_offset + 7
        False -> raw_offset
      }
      let day_num = 1 + offset + 7 * { n - 1 }
      case day_num <= days_in_month(month, year) {
        True -> Ok(Date(year: year, month: month, day: day_num))
        False -> Error(Nil)
      }
    }
  }
}

/// Return the date of the Nth-from-last occurrence of `target` weekday in
/// the given month (N ≥ 1, where 1 = last, 2 = second-to-last). Error if N
/// is < 1 or exceeds the count of that weekday in the month.
fn nth_from_last_weekday_of_month(
  year: Int,
  month: calendar.Month,
  target: Weekday,
  n: Int,
) -> Result(calendar.Date, Nil) {
  case n < 1 {
    True -> Error(Nil)
    False -> {
      let last_day_num = days_in_month(month, year)
      let last = Date(year: year, month: month, day: last_day_num)
      let last_dow = date_weekday_mon0(last)
      let target_dow = weekday_to_mon0(target)
      let raw_offset = last_dow - target_dow
      let offset = case raw_offset < 0 {
        True -> raw_offset + 7
        False -> raw_offset
      }
      let day_num = last_day_num - offset - 7 * { n - 1 }
      case day_num >= 1 {
        True -> Ok(Date(year: year, month: month, day: day_num))
        False -> Error(Nil)
      }
    }
  }
}

/// All dates in the given month that fall on the specified weekday (4 or 5).
fn all_weekdays_in_month(
  year: Int,
  month: calendar.Month,
  target: Weekday,
) -> List(calendar.Date) {
  case nth_weekday_of_month(year, month, target, 1) {
    Error(Nil) -> []
    Ok(first) -> collect_weekdays_in_month(first, days_in_month(month, year), [])
  }
}

/// Tail-recursive helper for `all_weekdays_in_month` — appends each successive
/// same-weekday date by adding 7 days until past month-end. Returns ascending.
fn collect_weekdays_in_month(
  date: calendar.Date,
  month_last_day: Int,
  acc: List(calendar.Date),
) -> List(calendar.Date) {
  case date.day > month_last_day {
    True -> list.reverse(acc)
    False ->
      collect_weekdays_in_month(
        Date(..date, day: date.day + 7),
        month_last_day,
        [date, ..acc],
      )
  }
}

/// Resolve a BYMONTHDAY value to an actual day of month.
/// Positive: 1-31 (clamped to month length).
/// Negative: -1 = last day, -2 = second-to-last, etc.
/// Returns Error if the resolved day is outside 1..days_in_month.
fn resolve_bymonthday(
  year: Int,
  month: calendar.Month,
  bymonthday: Int,
) -> Result(Int, Nil) {
  let days_in = days_in_month(month, year)
  case int.compare(bymonthday, 0) {
    order.Gt -> {
      // Positive: day of month (1-31)
      case bymonthday <= days_in {
        True -> Ok(bymonthday)
        False -> Error(Nil)
      }
    }
    order.Lt -> {
      // Negative: counting from end (-1 = last, -2 = second-to-last)
      let day_num = days_in + bymonthday + 1
      case day_num >= 1 {
        True -> Ok(day_num)
        False -> Error(Nil)
      }
    }
    order.Eq -> Error(Nil)
  }
}

/// Generate candidate dates for monthly recurrence using BYMONTHDAY values.
/// Each valid BYMONTHDAY is resolved to a date in the current month.
/// Invalid days (e.g., Feb 30) are silently dropped.
fn monthly_bymonthday_dates(
  year: Int,
  month: calendar.Month,
  bymonthday: List(Int),
) -> List(calendar.Date) {
  list.filter_map(bymonthday, fn(day_val) {
    use day <- result.try(resolve_bymonthday(year, month, day_val))
    Ok(Date(year: year, month: month, day: day))
  })
}

/// For a yearly+BYMONTH recurrence, expand candidates by month within the
/// current_date's year. Each BYMONTH entry yields one or more dates depending
/// on the BYDAY/BYMONTHDAY combination:
///   * BYDAY: nth-weekday-of-month per RFC 5545 §3.3.10
///   * BYMONTHDAY: specific days-of-month
///   * Neither: DTSTART's day-of-month in each BYMONTH (Feb 30-style invalid
///     dates are dropped)
/// Results are sorted chronologically.
fn yearly_bymonth_dates(
  current_date: calendar.Date,
  byday: List(BydayElem),
  bymonthday: List(Int),
  bymonths: List(Int),
) -> List(calendar.Date) {
  let year = current_date.year
  let day = current_date.day
  list.flat_map(bymonths, fn(m_int) {
    case int_to_month(m_int) {
      Ok(month) ->
        case byday, bymonthday {
          [_, ..], _ ->
            monthly_byday_dates(
              Date(year: year, month: month, day: 1),
              byday,
            )
          [], [_, ..] -> monthly_bymonthday_dates(year, month, bymonthday)
          [], [] -> {
            let max_day = days_in_month(month, year)
            case day <= max_day {
              True -> [Date(year: year, month: month, day: day)]
              False -> []
            }
          }
        }
      Error(Nil) -> []
    }
  })
  |> list.sort(calendar.naive_date_compare)
}

/// Like `monthly_byday_timestamps`, but for FREQ=YEARLY+BYMONTH expansion.
/// For each BYMONTH within the anchor's year, generates candidate timestamps
/// preserving the anchor's local wall-clock time-of-day.
fn yearly_bymonth_timestamps(
  current_ts: timestamp.Timestamp,
  byday: List(BydayElem),
  bymonthday: List(Int),
  bymonths: List(Int),
  event_tz: Result(String, Nil),
) -> List(timestamp.Timestamp) {
  case event_tz {
    Ok(tz) -> {
      let unix_secs =
        duration.to_seconds(
          timestamp.difference(timestamp.unix_epoch, current_ts),
        )
      let utc_greg = float.truncate(unix_secs) + gregorian_epoch_offset
      let #(#(y, m_int, d), #(h, mi, s)) =
        gregorian_seconds_to_datetime(utc_greg)
      let local_greg = tz_utc_to_local(y, m_int, d, h, mi, s, tz)
      let #(#(ly, lm_int, ld), #(lh, lmi, ls)) =
        gregorian_seconds_to_datetime(local_greg)
      let lm = case int_to_month(lm_int) {
        Ok(mo) -> mo
        Error(Nil) -> calendar.January
      }
      let local_date = Date(year: ly, month: lm, day: ld)
      let candidate_dates =
        yearly_bymonth_dates(local_date, byday, bymonthday, bymonths)
      list.map(candidate_dates, fn(target_date) {
        let Date(ty, tm, td) = target_date
        let tm_int = calendar.month_to_int(tm)
        let target_utc_greg =
          tz_local_to_utc(ty, tm_int, td, lh, lmi, ls, tz)
        timestamp.from_unix_seconds(target_utc_greg - gregorian_epoch_offset)
      })
    }
    Error(Nil) -> {
      // Floating event (no tz): treat current_ts as naive UTC.
      let unix_secs =
        duration.to_seconds(
          timestamp.difference(timestamp.unix_epoch, current_ts),
        )
      let utc_greg = float.truncate(unix_secs) + gregorian_epoch_offset
      let #(#(y, m_int, d), #(h, mi, s)) =
        gregorian_seconds_to_datetime(utc_greg)
      let m = case int_to_month(m_int) {
        Ok(mo) -> mo
        Error(Nil) -> calendar.January
      }
      let anchor_date = Date(year: y, month: m, day: d)
      let candidate_dates =
        yearly_bymonth_dates(anchor_date, byday, bymonthday, bymonths)
      list.map(candidate_dates, fn(target_date) {
        let Date(ty, tm, td) = target_date
        let tm_int = calendar.month_to_int(tm)
        let target_greg =
          datetime_to_gregorian_seconds(ty, tm_int, td, h, mi, s)
        timestamp.from_unix_seconds(target_greg - gregorian_epoch_offset)
      })
    }
  }
}

/// Number of days in a given year (365 or 366). Gregorian leap rule:
/// divisible by 4 except centuries not divisible by 400.
fn days_in_year(year: Int) -> Int {
  let is_leap =
    year % 4 == 0 && { year % 100 != 0 || year % 400 == 0 }
  case is_leap {
    True -> 366
    False -> 365
  }
}

/// Convert a 1-based day-of-year to a calendar.Date. Returns Error(Nil) if
/// `yday` is outside 1..days_in_year(year).
fn date_from_year_yday(
  year: Int,
  yday: Int,
) -> Result(calendar.Date, Nil) {
  case yday >= 1 && yday <= days_in_year(year) {
    False -> Error(Nil)
    True -> step_year_yday(year, 1, yday)
  }
}

fn step_year_yday(
  year: Int,
  month_int: Int,
  remaining: Int,
) -> Result(calendar.Date, Nil) {
  case month_int > 12 {
    True -> Error(Nil)
    False ->
      case int_to_month(month_int) {
        Ok(month) -> {
          let dim = days_in_month(month, year)
          case remaining <= dim {
            True -> Ok(Date(year: year, month: month, day: remaining))
            False -> step_year_yday(year, month_int + 1, remaining - dim)
          }
        }
        Error(Nil) -> Error(Nil)
      }
  }
}

/// Resolve a BYYEARDAY position (1..366 or -366..-1) for a specific year.
/// Negative positions count from the end (-1 = last day). Returns Error(Nil)
/// if the position is out of range for the given year.
fn resolve_byyearday(
  year: Int,
  position: Int,
) -> Result(calendar.Date, Nil) {
  let total = days_in_year(year)
  let yday = case position {
    p if p > 0 && p <= total -> p
    p if p < 0 && p >= 0 - total -> total + p + 1
    _ -> 0
  }
  case yday {
    0 -> Error(Nil)
    _ -> date_from_year_yday(year, yday)
  }
}

/// Generate candidate dates for FREQ=YEARLY+BYYEARDAY: each entry resolved
/// against the anchor's year. Out-of-range positions silently dropped.
/// Result sorted chronologically.
fn yearly_byyearday_dates(
  current_date: calendar.Date,
  byyeardays: List(Int),
) -> List(calendar.Date) {
  let year = current_date.year
  list.filter_map(byyeardays, fn(p) { resolve_byyearday(year, p) })
  |> list.sort(calendar.naive_date_compare)
}

/// Like `yearly_bymonth_timestamps`, but for BYYEARDAY: each candidate
/// preserves the anchor's local wall-clock time-of-day.
fn yearly_byyearday_timestamps(
  current_ts: timestamp.Timestamp,
  byyeardays: List(Int),
  event_tz: Result(String, Nil),
) -> List(timestamp.Timestamp) {
  case event_tz {
    Ok(tz) -> {
      let unix_secs =
        duration.to_seconds(
          timestamp.difference(timestamp.unix_epoch, current_ts),
        )
      let utc_greg = float.truncate(unix_secs) + gregorian_epoch_offset
      let #(#(y, m_int, d), #(h, mi, s)) =
        gregorian_seconds_to_datetime(utc_greg)
      let local_greg = tz_utc_to_local(y, m_int, d, h, mi, s, tz)
      let #(#(ly, lm_int, ld), #(lh, lmi, ls)) =
        gregorian_seconds_to_datetime(local_greg)
      let lm = case int_to_month(lm_int) {
        Ok(mo) -> mo
        Error(Nil) -> calendar.January
      }
      let local_date = Date(year: ly, month: lm, day: ld)
      let candidate_dates = yearly_byyearday_dates(local_date, byyeardays)
      list.map(candidate_dates, fn(target_date) {
        let Date(ty, tm, td) = target_date
        let tm_int = calendar.month_to_int(tm)
        let target_utc_greg =
          tz_local_to_utc(ty, tm_int, td, lh, lmi, ls, tz)
        timestamp.from_unix_seconds(target_utc_greg - gregorian_epoch_offset)
      })
    }
    Error(Nil) -> {
      let unix_secs =
        duration.to_seconds(
          timestamp.difference(timestamp.unix_epoch, current_ts),
        )
      let utc_greg = float.truncate(unix_secs) + gregorian_epoch_offset
      let #(#(y, m_int, d), #(h, mi, s)) =
        gregorian_seconds_to_datetime(utc_greg)
      let m = case int_to_month(m_int) {
        Ok(mo) -> mo
        Error(Nil) -> calendar.January
      }
      let anchor_date = Date(year: y, month: m, day: d)
      let candidate_dates = yearly_byyearday_dates(anchor_date, byyeardays)
      list.map(candidate_dates, fn(target_date) {
        let Date(ty, tm, td) = target_date
        let tm_int = calendar.month_to_int(tm)
        let target_greg =
          datetime_to_gregorian_seconds(ty, tm_int, td, h, mi, s)
        timestamp.from_unix_seconds(target_greg - gregorian_epoch_offset)
      })
    }
  }
}

/// Compute the date of the Monday starting ISO 8601 week 1 of the given year.
/// Per RFC 5545 §3.3.10 / ISO 8601: week 1 contains January 4. The Monday
/// of week 1 is "the Monday on or before Jan 4".
///
/// Currently hardcoded to WKST=Monday (ISO 8601 standard).
fn iso_week_one_monday(year: Int) -> calendar.Date {
  let jan_4 = Date(year: year, month: calendar.January, day: 4)
  let mon_idx = date_weekday_wkst_index(jan_4, Monday)
  shift_date_days(jan_4, 0 - mon_idx)
}

/// Number of ISO 8601 weeks in a given year (52 or 53). A year has 53 weeks
/// if Jan 1 is Thursday OR if Jan 1 is Wednesday in a leap year.
fn iso_weeks_in_year(year: Int) -> Int {
  let jan_1 = Date(year: year, month: calendar.January, day: 1)
  let mon_idx = date_weekday_wkst_index(jan_1, Monday)
  let leap = days_in_year(year) == 366
  case mon_idx == 3 || { mon_idx == 2 && leap } {
    True -> 53
    False -> 52
  }
}

/// Resolve a BYWEEKNO position (1..53 or -53..-1) and a Monday-relative
/// day-of-week index (0=Mon..6=Sun) to a calendar Date in the given year.
/// Returns Error(Nil) if the requested week doesn't exist (e.g. week 53 in
/// a 52-week year).
fn iso_resolve_byweekno(
  year: Int,
  week_pos: Int,
  dow_idx_mon0: Int,
) -> Result(calendar.Date, Nil) {
  let total_weeks = iso_weeks_in_year(year)
  let week_num = case week_pos {
    w if w > 0 && w <= total_weeks -> Ok(w)
    w if w < 0 && w >= 0 - total_weeks -> Ok(total_weeks + w + 1)
    _ -> Error(Nil)
  }
  use w <- result.try(week_num)
  let week_one_mon = iso_week_one_monday(year)
  let week_n_mon = shift_date_days(week_one_mon, { w - 1 } * 7)
  Ok(shift_date_days(week_n_mon, dow_idx_mon0))
}

/// Generate candidate dates for FREQ=YEARLY+BYWEEKNO. Each entry resolves to
/// the day-of-week of `master_start_date` within the corresponding ISO week
/// of the current year. Out-of-range or non-existent weeks are dropped.
fn yearly_byweekno_dates(
  current_date: calendar.Date,
  byweeknos: List(Int),
  master_start_date: calendar.Date,
) -> List(calendar.Date) {
  let year = current_date.year
  let dow_idx = date_weekday_wkst_index(master_start_date, Monday)
  list.filter_map(byweeknos, fn(p) {
    iso_resolve_byweekno(year, p, dow_idx)
  })
  |> list.sort(calendar.naive_date_compare)
}

/// Like `yearly_byyearday_timestamps`, but for BYWEEKNO. Each candidate
/// preserves the anchor's local wall-clock time-of-day. The day-of-week is
/// taken from `master_start_ts` (i.e. the original DTSTART).
fn yearly_byweekno_timestamps(
  current_ts: timestamp.Timestamp,
  byweeknos: List(Int),
  master_start_ts: timestamp.Timestamp,
  event_tz: Result(String, Nil),
) -> List(timestamp.Timestamp) {
  let master_start_date = local_date_of_timestamp(master_start_ts, event_tz)
  case event_tz {
    Ok(tz) -> {
      let unix_secs =
        duration.to_seconds(
          timestamp.difference(timestamp.unix_epoch, current_ts),
        )
      let utc_greg = float.truncate(unix_secs) + gregorian_epoch_offset
      let #(#(y, m_int, d), #(h, mi, s)) =
        gregorian_seconds_to_datetime(utc_greg)
      let local_greg = tz_utc_to_local(y, m_int, d, h, mi, s, tz)
      let #(#(ly, lm_int, ld), #(lh, lmi, ls)) =
        gregorian_seconds_to_datetime(local_greg)
      let lm = case int_to_month(lm_int) {
        Ok(mo) -> mo
        Error(Nil) -> calendar.January
      }
      let local_date = Date(year: ly, month: lm, day: ld)
      let candidate_dates =
        yearly_byweekno_dates(local_date, byweeknos, master_start_date)
      list.map(candidate_dates, fn(target_date) {
        let Date(ty, tm, td) = target_date
        let tm_int = calendar.month_to_int(tm)
        let target_utc_greg =
          tz_local_to_utc(ty, tm_int, td, lh, lmi, ls, tz)
        timestamp.from_unix_seconds(target_utc_greg - gregorian_epoch_offset)
      })
    }
    Error(Nil) -> {
      let unix_secs =
        duration.to_seconds(
          timestamp.difference(timestamp.unix_epoch, current_ts),
        )
      let utc_greg = float.truncate(unix_secs) + gregorian_epoch_offset
      let #(#(y, m_int, d), #(h, mi, s)) =
        gregorian_seconds_to_datetime(utc_greg)
      let m = case int_to_month(m_int) {
        Ok(mo) -> mo
        Error(Nil) -> calendar.January
      }
      let anchor_date = Date(year: y, month: m, day: d)
      let candidate_dates =
        yearly_byweekno_dates(anchor_date, byweeknos, master_start_date)
      list.map(candidate_dates, fn(target_date) {
        let Date(ty, tm, td) = target_date
        let tm_int = calendar.month_to_int(tm)
        let target_greg =
          datetime_to_gregorian_seconds(ty, tm_int, td, h, mi, s)
        timestamp.from_unix_seconds(target_greg - gregorian_epoch_offset)
      })
    }
  }
}

/// Convert a timestamp to its local-tz date. For floating events (no tz),
/// the timestamp is treated as naive UTC.
fn local_date_of_timestamp(
  ts: timestamp.Timestamp,
  event_tz: Result(String, Nil),
) -> calendar.Date {
  let unix_secs =
    duration.to_seconds(timestamp.difference(timestamp.unix_epoch, ts))
  let utc_greg = float.truncate(unix_secs) + gregorian_epoch_offset
  let #(#(y, m_int, d), #(h, mi, s)) =
    gregorian_seconds_to_datetime(utc_greg)
  case event_tz {
    Ok(tz) -> {
      let local_greg = tz_utc_to_local(y, m_int, d, h, mi, s, tz)
      let #(#(ly, lm_int, ld), _) =
        gregorian_seconds_to_datetime(local_greg)
      let lm = case int_to_month(lm_int) {
        Ok(mo) -> mo
        Error(Nil) -> calendar.January
      }
      Date(year: ly, month: lm, day: ld)
    }
    Error(Nil) -> {
      let m = case int_to_month(m_int) {
        Ok(mo) -> mo
        Error(Nil) -> calendar.January
      }
      Date(year: y, month: m, day: d)
    }
  }
}

/// Return the local-time month (1..12) for a given timestamp. Used to filter
/// candidate timestamps by BYMONTH for FREQ=MONTHLY/WEEKLY/DAILY.
fn timestamp_local_month_int(
  ts: timestamp.Timestamp,
  event_tz: Result(String, Nil),
) -> Int {
  let unix_secs =
    duration.to_seconds(timestamp.difference(timestamp.unix_epoch, ts))
  let utc_greg = float.truncate(unix_secs) + gregorian_epoch_offset
  let #(#(y, m_int, d), #(h, mi, s)) =
    gregorian_seconds_to_datetime(utc_greg)
  case event_tz {
    Ok(tz) -> {
      let local_greg = tz_utc_to_local(y, m_int, d, h, mi, s, tz)
      let #(#(_, lm_int, _), _) = gregorian_seconds_to_datetime(local_greg)
      lm_int
    }
    Error(Nil) -> m_int
  }
}

/// Pick the element at a 1-indexed BYSETPOS position in a sorted list.
/// Positive position counts from the start (1 = first); negative counts from
/// the end (-1 = last). Out-of-range positions return Error(Nil).
fn pick_at_position(
  sorted: List(a),
  position: Int,
  length: Int,
) -> Result(a, Nil) {
  let idx = case position {
    p if p > 0 -> p - 1
    p if p < 0 -> length + p
    _ -> -1
  }
  case idx >= 0 && idx < length {
    True ->
      list.drop(sorted, idx)
      |> list.first
    False -> Error(Nil)
  }
}

/// Apply BYSETPOS to a list of candidate dates. Sorts chronologically, then
/// selects positions per RFC 5545 §3.3.10. Out-of-range positions are dropped.
/// Returns the picked dates in chronological order with duplicates removed.
fn apply_bysetpos_dates(
  candidates: List(calendar.Date),
  positions: List(Int),
) -> List(calendar.Date) {
  let sorted = list.sort(candidates, calendar.naive_date_compare)
  let n = list.length(sorted)
  list.filter_map(positions, fn(p) { pick_at_position(sorted, p, n) })
  |> list.unique
  |> list.sort(calendar.naive_date_compare)
}

/// Apply BYSETPOS to a list of candidate timestamps. Sorts chronologically,
/// then selects positions per RFC 5545 §3.3.10.
fn apply_bysetpos_timestamps(
  candidates: List(timestamp.Timestamp),
  positions: List(Int),
) -> List(timestamp.Timestamp) {
  let sorted = list.sort(candidates, timestamp.compare)
  let n = list.length(sorted)
  list.filter_map(positions, fn(p) { pick_at_position(sorted, p, n) })
  |> list.unique
  |> list.sort(timestamp.compare)
}

/// Expand each candidate timestamp by replacing its local time-of-day with
/// every combination in the cartesian product byhour × byminute × bysecond
/// (RFC 5545 §3.3.10). For FREQ=DAILY/WEEKLY/MONTHLY/YEARLY these rule parts
/// EXPAND the candidate set; we don't support FREQ=HOURLY/MINUTELY/SECONDLY
/// where they would act as filters.
///
/// An empty list for any of the three preserves the candidate's existing
/// component for that field. When all three are empty, candidates pass
/// through unchanged.
///
/// Result is deduplicated and sorted chronologically.
fn expand_by_hour_minute_second(
  candidates: List(timestamp.Timestamp),
  byhour: List(Int),
  byminute: List(Int),
  bysecond: List(Int),
  event_tz: Result(String, Nil),
) -> List(timestamp.Timestamp) {
  case byhour, byminute, bysecond {
    [], [], [] -> candidates
    _, _, _ ->
      list.flat_map(candidates, fn(ts) {
        let #(y, m_int, d, h, mi, s) =
          timestamp_local_components(ts, event_tz)
        let hours = case byhour {
          [] -> [h]
          xs -> xs
        }
        let minutes = case byminute {
          [] -> [mi]
          xs -> xs
        }
        let seconds = case bysecond {
          [] -> [s]
          xs -> xs
        }
        list.flat_map(hours, fn(nh) {
          list.flat_map(minutes, fn(nmi) {
            list.map(seconds, fn(ns) {
              timestamp_from_local_components(
                y,
                m_int,
                d,
                nh,
                nmi,
                ns,
                event_tz,
              )
            })
          })
        })
      })
      |> list.unique
      |> list.sort(timestamp.compare)
  }
}

/// Decompose a UTC timestamp into local-time #(year, month_int, day, hour,
/// minute, second) using the given timezone (or naive UTC if event_tz is
/// Error(Nil)).
fn timestamp_local_components(
  ts: timestamp.Timestamp,
  event_tz: Result(String, Nil),
) -> #(Int, Int, Int, Int, Int, Int) {
  let unix_secs =
    duration.to_seconds(timestamp.difference(timestamp.unix_epoch, ts))
  let utc_greg = float.truncate(unix_secs) + gregorian_epoch_offset
  let #(#(y, m_int, d), #(h, mi, s)) =
    gregorian_seconds_to_datetime(utc_greg)
  case event_tz {
    Ok(tz) -> {
      let local_greg = tz_utc_to_local(y, m_int, d, h, mi, s, tz)
      let #(#(ly, lm_int, ld), #(lh, lmi, ls)) =
        gregorian_seconds_to_datetime(local_greg)
      #(ly, lm_int, ld, lh, lmi, ls)
    }
    Error(Nil) -> #(y, m_int, d, h, mi, s)
  }
}

/// Recompose a UTC timestamp from local-time #(year, month_int, day, hour,
/// minute, second). When event_tz is Ok(tz), interprets the components in
/// that timezone and converts to UTC. Otherwise treats them as naive UTC.
fn timestamp_from_local_components(
  y: Int,
  m_int: Int,
  d: Int,
  h: Int,
  mi: Int,
  s: Int,
  event_tz: Result(String, Nil),
) -> timestamp.Timestamp {
  case event_tz {
    Ok(tz) -> {
      let utc_greg = tz_local_to_utc(y, m_int, d, h, mi, s, tz)
      timestamp.from_unix_seconds(utc_greg - gregorian_epoch_offset)
    }
    Error(Nil) -> {
      let greg = datetime_to_gregorian_seconds(y, m_int, d, h, mi, s)
      timestamp.from_unix_seconds(greg - gregorian_epoch_offset)
    }
  }
}

/// Like `monthly_byday_dates`, but produces UTC timestamps for each candidate
/// preserving the anchor's local wall-clock time-of-day. Mirrors the
/// decode/re-encode dance in `weekly_byday_timestamps`.
fn monthly_byday_timestamps(
  current_ts: timestamp.Timestamp,
  byday: List(BydayElem),
  event_tz: Result(String, Nil),
) -> List(timestamp.Timestamp) {
  case event_tz {
    Ok(tz) -> {
      let unix_secs =
        duration.to_seconds(
          timestamp.difference(timestamp.unix_epoch, current_ts),
        )
      let utc_greg = float.truncate(unix_secs) + gregorian_epoch_offset
      let #(#(y, m_int, d), #(h, mi, s)) =
        gregorian_seconds_to_datetime(utc_greg)
      let local_greg = tz_utc_to_local(y, m_int, d, h, mi, s, tz)
      let #(#(ly, lm_int, ld), #(lh, lmi, ls)) =
        gregorian_seconds_to_datetime(local_greg)
      let lm = case int_to_month(lm_int) {
        Ok(mo) -> mo
        Error(Nil) -> calendar.January
      }
      let local_date = Date(year: ly, month: lm, day: ld)
      let candidate_dates = monthly_byday_dates(local_date, byday)
      list.map(candidate_dates, fn(target_date) {
        let Date(ty, tm, td) = target_date
        let tm_int = calendar.month_to_int(tm)
        let target_utc_greg =
          tz_local_to_utc(ty, tm_int, td, lh, lmi, ls, tz)
        timestamp.from_unix_seconds(target_utc_greg - gregorian_epoch_offset)
      })
    }
    Error(Nil) -> {
      // Floating event (no tz): treat current_ts as naive UTC.
      let unix_secs =
        duration.to_seconds(
          timestamp.difference(timestamp.unix_epoch, current_ts),
        )
      let utc_greg = float.truncate(unix_secs) + gregorian_epoch_offset
      let #(#(y, m_int, d), #(h, mi, s)) =
        gregorian_seconds_to_datetime(utc_greg)
      let m = case int_to_month(m_int) {
        Ok(mo) -> mo
        Error(Nil) -> calendar.January
      }
      let anchor_date = Date(year: y, month: m, day: d)
      let candidate_dates = monthly_byday_dates(anchor_date, byday)
      list.map(candidate_dates, fn(target_date) {
        let Date(ty, tm, td) = target_date
        let tm_int = calendar.month_to_int(tm)
        let target_greg =
          datetime_to_gregorian_seconds(ty, tm_int, td, h, mi, s)
        timestamp.from_unix_seconds(target_greg - gregorian_epoch_offset)
      })
    }
  }
}

/// Like `monthly_bymonthday_dates`, but produces UTC timestamps preserving
/// the anchor's local wall-clock time-of-day.
fn monthly_bymonthday_timestamps(
  current_ts: timestamp.Timestamp,
  bymonthday: List(Int),
  event_tz: Result(String, Nil),
) -> List(timestamp.Timestamp) {
  case event_tz {
    Ok(tz) -> {
      let unix_secs =
        duration.to_seconds(
          timestamp.difference(timestamp.unix_epoch, current_ts),
        )
      let utc_greg = float.truncate(unix_secs) + gregorian_epoch_offset
      let #(#(y, m_int, d), #(h, mi, s)) =
        gregorian_seconds_to_datetime(utc_greg)
      let local_greg = tz_utc_to_local(y, m_int, d, h, mi, s, tz)
      let #(#(ly, lm_int, _ld), #(lh, lmi, ls)) =
        gregorian_seconds_to_datetime(local_greg)
      let lm = case int_to_month(lm_int) {
        Ok(mo) -> mo
        Error(Nil) -> calendar.January
      }
      let candidate_dates = monthly_bymonthday_dates(ly, lm, bymonthday)
      list.map(candidate_dates, fn(target_date) {
        let Date(ty, tm, td) = target_date
        let tm_int = calendar.month_to_int(tm)
        let target_utc_greg =
          tz_local_to_utc(ty, tm_int, td, lh, lmi, ls, tz)
        timestamp.from_unix_seconds(target_utc_greg - gregorian_epoch_offset)
      })
    }
    Error(Nil) -> {
      // Floating event (no tz): treat current_ts as naive UTC.
      let unix_secs =
        duration.to_seconds(
          timestamp.difference(timestamp.unix_epoch, current_ts),
        )
      let utc_greg = float.truncate(unix_secs) + gregorian_epoch_offset
      let #(#(y, m_int, _d), #(h, mi, s)) =
        gregorian_seconds_to_datetime(utc_greg)
      let m = case int_to_month(m_int) {
        Ok(mo) -> mo
        Error(Nil) -> calendar.January
      }
      let candidate_dates = monthly_bymonthday_dates(y, m, bymonthday)
      list.map(candidate_dates, fn(target_date) {
        let Date(ty, tm, td) = target_date
        let tm_int = calendar.month_to_int(tm)
        let target_greg =
          datetime_to_gregorian_seconds(ty, tm_int, td, h, mi, s)
        timestamp.from_unix_seconds(target_greg - gregorian_epoch_offset)
      })
    }
  }
}

fn generate_recurring_timed(
  rrule: RecurrenceRule,
  current_ts: timestamp.Timestamp,
  master_start_ts: timestamp.Timestamp,
  remaining: Option(Int),
  duration_secs: Int,
  exdates: List(EventTime),
  uid_overrides: List(List(String)),
  uid: String,
  summary: String,
  calendar_name: String,
  location: String,
  free: Bool,
  description: String,
  url: String,
  local_offset: duration.Duration,
  system_tz: Result(String, Nil),
  event_tz: Result(String, Nil),
  window_start: timestamp.Timestamp,
  window_end: timestamp.Timestamp,
  acc: List(Event),
) -> List(Event) {
  let RecurrenceRule(
    freq,
    interval,
    byday,
    bymonthday,
    _count,
    until,
    wkst,
    bymonth,
    bysetpos,
    byyearday,
    byweekno,
    byhour,
    byminute,
    bysecond,
  ) = rrule

  // When BYDAY or BYMONTHDAY is used, an iteration's emitted days may fall
  // outside the anchor's date itself. Extend the termination guard to avoid
  // skipping in-window emissions on the final iteration before window_end.
  let lookahead_buffer = case freq, byday, bymonthday, bymonth, byyearday, byweekno {
    Weekly, [_, ..], _, _, _, _ -> 7 * 86_400
    Monthly, [_, ..], _, _, _, _ -> 31 * 86_400
    Monthly, [], [_, ..], _, _, _ -> 31 * 86_400
    Yearly, _, _, [_, ..], _, _ -> 366 * 86_400
    Yearly, _, _, _, [_, ..], _ -> 366 * 86_400
    Yearly, _, _, _, _, [_, ..] -> 366 * 86_400
    _, _, _, _, _, _ -> 0
  }
  let buffered_window_end =
    timestamp.add(window_end, duration.seconds(lookahead_buffer))

  // Stop if we've gone past window_end or too far beyond it (loop guard)
  let past_end = timestamp.compare(current_ts, buffered_window_end) != Lt
  let too_far =
    timestamp.compare(
      current_ts,
      timestamp.add(window_end, duration.seconds(500 * 7 * 86_400)),
    )
    != Lt
  let count_done = remaining == Some(0)
  // Stop when current_ts is past UNTIL (plus BYDAY buffer) — no candidate can
  // be ≤ UNTIL after that point. Only honoured when UNTIL has the same
  // value-type as DTSTART (AtTime here).
  let until_done = case until {
    Some(AtTime(u_ts)) -> {
      let cutoff_ts =
        timestamp.add(u_ts, duration.seconds(lookahead_buffer))
      timestamp.compare(cutoff_ts, current_ts) == Lt
    }
    _ -> False
  }

  case past_end || too_far || count_done || until_done {
    True -> list.reverse(acc)
    False -> {
      // Advance by the recurrence interval while preserving wall-clock time across DST transitions
      let next_ts = add_recurrence_dst_aware(current_ts, freq, interval, event_tz, local_offset)

      // Determine all candidate timestamps for this iteration's expansion.
      // For weekly+BYDAY, emit one event per BYDAY day in the iteration's week.
      // For monthly+BYDAY, emit one event per BYDAY entry resolved within the
      // iteration's local month (e.g. Nth-or-last-of-weekday). For monthly+BYMONTHDAY
      // (without BYDAY), emit one event per specified day-of-month. Otherwise, emit
      // one event at current_ts. Phantom pre-DTSTART candidates are dropped so they
      // do not consume COUNT slots. Candidates after UNTIL are likewise dropped
      // (RFC 5545 §3.3.10; UNTIL is inclusive).
      let raw_candidate_tses = case
        freq, byday, bymonthday, bymonth, byyearday, byweekno
      {
        // Yearly + BYYEARDAY: expand per yearday position (highest priority).
        Yearly, _, _, _, [_, ..], _ ->
          yearly_byyearday_timestamps(current_ts, byyearday, event_tz)
        // Yearly + BYWEEKNO: expand per ISO week.
        Yearly, _, _, _, [], [_, ..] ->
          yearly_byweekno_timestamps(
            current_ts,
            byweekno,
            master_start_ts,
            event_tz,
          )
        // Yearly + BYMONTH (without BYYEARDAY/BYWEEKNO): expand per month.
        Yearly, _, _, [_, ..], [], [] ->
          yearly_bymonth_timestamps(
            current_ts,
            byday,
            bymonthday,
            bymonth,
            event_tz,
          )
        Weekly, [_, ..], _, _, _, _ ->
          weekly_byday_timestamps(current_ts, byday, event_tz, wkst)
        Monthly, [_, ..], _, _, _, _ ->
          monthly_byday_timestamps(current_ts, byday, event_tz)
        Monthly, [], [_, ..], _, _, _ ->
          monthly_bymonthday_timestamps(current_ts, bymonthday, event_tz)
        _, _, _, _, _, _ -> [current_ts]
      }
      // For non-Yearly frequencies with BYMONTH, filter candidates by month.
      // (Yearly+BYMONTH was already expanded above.)
      let raw_candidate_tses = case freq, bymonth {
        Yearly, _ -> raw_candidate_tses
        _, [] -> raw_candidate_tses
        _, _ ->
          list.filter(raw_candidate_tses, fn(ts) {
            list.contains(
              bymonth,
              timestamp_local_month_int(ts, event_tz),
            )
          })
      }
      // BYHOUR/BYMINUTE/BYSECOND expansion (RFC 5545 §3.3.10). Replaces each
      // candidate's local time-of-day with the cartesian product. No-op when
      // all three lists are empty.
      let raw_candidate_tses =
        expand_by_hour_minute_second(
          raw_candidate_tses,
          byhour,
          byminute,
          bysecond,
          event_tz,
        )
      // BYSETPOS post-filter (RFC 5545 §3.3.10). Must be used in conjunction
      // with another BYxxx rule; otherwise ignored.
      let raw_candidate_tses = case
        bysetpos,
        byday,
        bymonthday,
        bymonth,
        byhour,
        byminute,
        bysecond
      {
        [], _, _, _, _, _, _ -> raw_candidate_tses
        _, [], [], [], [], [], [] -> raw_candidate_tses
        _, _, _, _, _, _, _ ->
          apply_bysetpos_timestamps(raw_candidate_tses, bysetpos)
      }
      let candidate_tses =
        list.filter(raw_candidate_tses, fn(ts) {
          let after_start = timestamp.compare(ts, master_start_ts) != Lt
          let until_ok = case until {
            Some(AtTime(u_ts)) -> timestamp.compare(ts, u_ts) != order.Gt
            _ -> True
          }
          after_start && until_ok
        })

      // Apply COUNT bound: take at most `remaining` candidates this iteration.
      let to_emit = case remaining {
        Some(n) -> list.take(candidate_tses, n)
        None -> candidate_tses
      }
      let new_remaining = case remaining {
        Some(n) -> Some(n - list.length(to_emit))
        None -> None
      }

      // Build events for each candidate that passes all checks.
      let new_events =
        list.filter_map(to_emit, fn(ts) {
          instance_for_ts(
            ts,
            duration_secs,
            exdates,
            uid_overrides,
            uid,
            summary,
            calendar_name,
            location,
            free,
            description,
            url,
            local_offset,
            system_tz,
            window_start,
            window_end,
          )
        })

      // Prepend new events to acc preserving chronological order through the
      // final list.reverse. fold processes left→right and prepends each, so
      // candidates ordered [Tu, Th] become [Th, Tu, ..acc] and reverse to [.., Tu, Th].
      let new_acc =
        list.fold(new_events, acc, fn(a, e) { [e, ..a] })

      generate_recurring_timed(
        rrule,
        next_ts,
        master_start_ts,
        new_remaining,
        duration_secs,
        exdates,
        uid_overrides,
        uid,
        summary,
        calendar_name,
        location,
        free,
        description,
        url,
        local_offset,
        system_tz,
        event_tz,
        window_start,
        window_end,
        new_acc,
      )
    }
  }
}

/// Build an Event from a candidate timestamp, applying window, EXDATE, and
/// RECURRENCE-ID override checks. Returns Error(Nil) if the instance should
/// be skipped (not in window or excluded).
fn instance_for_ts(
  ts: timestamp.Timestamp,
  duration_secs: Int,
  exdates: List(EventTime),
  uid_overrides: List(List(String)),
  uid: String,
  summary: String,
  calendar_name: String,
  location: String,
  free: Bool,
  description: String,
  url: String,
  local_offset: duration.Duration,
  system_tz: Result(String, Nil),
  window_start: timestamp.Timestamp,
  window_end: timestamp.Timestamp,
) -> Result(Event, Nil) {
  let instance_end_ts =
    timestamp.add(ts, duration.seconds(duration_secs))
  let in_window =
    timestamp.compare(instance_end_ts, window_start) != Lt
    && timestamp.compare(ts, window_end) == Lt

  case in_window {
    False -> Error(Nil)
    True -> {
      let is_excluded =
        list.any(exdates, fn(ex) {
          same_day_event_time(ts, ex, local_offset)
        })
      case is_excluded {
        True -> Error(Nil)
        False ->
          case
            find_override_for_ts(
              ts,
              uid_overrides,
              uid,
              calendar_name,
              local_offset,
              system_tz,
            )
          {
            CancellingOverride -> Error(Nil)
            ReplacingOverride(override_evt) -> Ok(override_evt)
            NoOverride ->
              Ok(Event(
                uid:,
                summary:,
                start: AtTime(ts),
                end: AtTime(instance_end_ts),
                calendar_name:,
                location:,
                free:,
                description:,
                url:,
              ))
          }
      }
    }
  }
}

/// Look for a RECURRENCE-ID override that applies to the generated instance
/// at `ts`. Override resolution order per RFC 5545 §3.2.13:
///
/// 1. Exact single-instance override (RANGE parameter absent). This is the
///    most specific match; if any same-day override has no RANGE, it wins.
/// 2. THISANDFUTURE override whose RECURRENCE-ID is on or before `ts`. If
///    multiple THISANDFUTURE overrides qualify, the one with the latest
///    RECURRENCE-ID wins (it represents the most recent "edit this and
///    following" action).
///
/// For THISANDFUTURE matches whose RECURRENCE-ID is strictly before `ts`,
/// the override's properties are applied and DTSTART/DTEND are shifted by
/// `ts - rec_id` so that the new schedule preserves the original
/// occurrence cadence while adopting any time-of-day change embedded in
/// the override.
fn find_override_for_ts(
  ts: timestamp.Timestamp,
  uid_overrides: List(List(String)),
  uid: String,
  calendar_name: String,
  local_offset: duration.Duration,
  system_tz: Result(String, Nil),
) -> OverrideResult {
  // Parse each override once into (lines, props, rec_id_ts,
  // is_thisandfuture). Skip overrides whose RECURRENCE-ID is all-day —
  // those belong to all-day masters and never apply to a timed instance.
  let parsed =
    list.filter_map(uid_overrides, fn(ol) {
      let oprops = list.filter_map(ol, parse_property)
      let rec_id_tzid = get_tzid_param(ol, "RECURRENCE-ID")
      case get_prop_prefix(oprops, "RECURRENCE-ID") {
        Ok(rec_raw) ->
          case parse_event_time(rec_raw, rec_id_tzid, system_tz) {
            Ok(AtTime(rec_ts)) ->
              Ok(#(ol, oprops, rec_ts, has_thisandfuture_range(ol)))
            _ -> Error(Nil)
          }
        Error(Nil) -> Error(Nil)
      }
    })

  // (1) Single-instance match (RANGE absent) on the same local day.
  let single =
    list.find(parsed, fn(p) {
      let #(_, _, rec_ts, is_taf) = p
      !is_taf && same_day_ts(ts, rec_ts, local_offset)
    })

  case single {
    Ok(#(ol, oprops, rec_ts, _)) ->
      apply_timed_override(
        ol,
        oprops,
        ts,
        rec_ts,
        uid,
        calendar_name,
        local_offset,
        system_tz,
      )
    Error(Nil) -> {
      // (2) Most recent THISANDFUTURE with rec_ts <= ts.
      let candidate =
        list.fold(parsed, Error(Nil), fn(acc, p) {
          let #(_, _, rec_ts, is_taf) = p
          case is_taf && timestamp.compare(rec_ts, ts) != order.Gt {
            False -> acc
            True ->
              case acc {
                Error(Nil) -> Ok(p)
                Ok(#(_, _, best_ts, _)) ->
                  case timestamp.compare(rec_ts, best_ts) {
                    order.Gt -> Ok(p)
                    _ -> acc
                  }
              }
          }
        })
      case candidate {
        Ok(#(ol, oprops, rec_ts, _)) ->
          apply_timed_override(
            ol,
            oprops,
            ts,
            rec_ts,
            uid,
            calendar_name,
            local_offset,
            system_tz,
          )
        Error(Nil) -> NoOverride
      }
    }
  }
}

/// Apply a matched override (whether single-instance or THISANDFUTURE) to
/// an instance at `current_ts`. STATUS:CANCELLED produces CancellingOverride.
/// Otherwise we parse the override into an Event; if `current_ts` differs
/// from the override's `rec_ts` (the THISANDFUTURE non-matching case), the
/// resulting Event's DTSTART/DTEND are shifted by `current_ts - rec_ts`.
fn apply_timed_override(
  ol: List(String),
  oprops: List(#(String, String)),
  current_ts: timestamp.Timestamp,
  rec_ts: timestamp.Timestamp,
  uid: String,
  calendar_name: String,
  local_offset: duration.Duration,
  system_tz: Result(String, Nil),
) -> OverrideResult {
  case props_status_cancelled(oprops) {
    True -> CancellingOverride
    False ->
      case
        parse_override_event(ol, uid, calendar_name, local_offset, system_tz)
      {
        Ok(evt) ->
          case timestamp.compare(current_ts, rec_ts) {
            order.Eq -> ReplacingOverride(evt)
            _ -> {
              let delta = timestamp.difference(rec_ts, current_ts)
              ReplacingOverride(shift_event_times(evt, delta))
            }
          }
        // Malformed override (e.g. missing SUMMARY): fall back to the
        // master-derived instance rather than silently dropping.
        Error(Nil) -> NoOverride
      }
  }
}

/// Shift the start and end of an Event by `delta`. Used to translate a
/// THISANDFUTURE override's properties onto an instance whose original
/// recurrence-set timestamp differs from the override's RECURRENCE-ID.
/// All-day EventTimes are returned unchanged because date-shifting an
/// all-day series via THISANDFUTURE is not a well-defined transformation.
fn shift_event_times(evt: Event, delta: duration.Duration) -> Event {
  let new_start = case evt.start {
    AtTime(ts) -> AtTime(timestamp.add(ts, delta))
    AllDay(d) -> AllDay(d)
  }
  let new_end = case evt.end {
    AtTime(ts) -> AtTime(timestamp.add(ts, delta))
    AllDay(d) -> AllDay(d)
  }
  Event(..evt, start: new_start, end: new_end)
}

/// Given an iteration's anchor timestamp and a list of BYDAY entries, compute
/// the corresponding UTC timestamps for each BYDAY day within the anchor's
/// (Monday-start) week, preserving the anchor's wall-clock time-of-day.
/// Positional prefixes are ignored per RFC 5545 (FREQ=WEEKLY has no
/// Nth-in-week semantics).
fn weekly_byday_timestamps(
  current_ts: timestamp.Timestamp,
  byday: List(BydayElem),
  event_tz: Result(String, Nil),
  wkst: Weekday,
) -> List(timestamp.Timestamp) {
  case event_tz {
    Ok(tz) -> {
      // Decode the anchor timestamp into local date + time-of-day.
      let unix_secs =
        duration.to_seconds(
          timestamp.difference(timestamp.unix_epoch, current_ts),
        )
      let utc_greg = float.truncate(unix_secs) + gregorian_epoch_offset
      let #(#(y, m_int, d), #(h, mi, s)) =
        gregorian_seconds_to_datetime(utc_greg)
      let local_greg = tz_utc_to_local(y, m_int, d, h, mi, s, tz)
      let #(#(ly, lm_int, ld), #(lh, lmi, ls)) =
        gregorian_seconds_to_datetime(local_greg)
      let lm = case int_to_month(lm_int) {
        Ok(mo) -> mo
        Error(Nil) -> calendar.January
      }
      let local_date = Date(year: ly, month: lm, day: ld)
      let current_idx = date_weekday_wkst_index(local_date, wkst)

      list.map(byday, fn(b) {
        let target_idx = weekday_to_wkst_index(b.day, wkst)
        let offset = target_idx - current_idx
        let target_date = shift_date_days(local_date, offset)
        let Date(ty, tm, td) = target_date
        let tm_int = calendar.month_to_int(tm)
        let target_utc_greg =
          tz_local_to_utc(ty, tm_int, td, lh, lmi, ls, tz)
        timestamp.from_unix_seconds(target_utc_greg - gregorian_epoch_offset)
      })
      |> list.sort(timestamp.compare)
    }
    Error(Nil) -> {
      // Floating event (no tz): treat current_ts as naive UTC for dow arithmetic.
      let unix_secs =
        duration.to_seconds(
          timestamp.difference(timestamp.unix_epoch, current_ts),
        )
      let days_since_epoch = float.truncate(unix_secs) / 86_400
      // 1970-01-01 was a Thursday → index 3 in 0=Mon..6=Sun
      let current_dow_raw =
        { days_since_epoch + 3 }
        |> int.remainder(7)
        |> result.unwrap(0)
      let current_dow_mon0 = case current_dow_raw < 0 {
        True -> current_dow_raw + 7
        False -> current_dow_raw
      }
      // Convert mon0 → wkst-relative
      let wkst_mon0 = weekday_to_mon0(wkst)
      let diff = current_dow_mon0 - wkst_mon0
      let current_idx = case diff < 0 {
        True -> diff + 7
        False -> diff
      }
      list.map(byday, fn(b) {
        let target_idx = weekday_to_wkst_index(b.day, wkst)
        let offset = target_idx - current_idx
        timestamp.add(current_ts, duration.seconds(offset * 86_400))
      })
      |> list.sort(timestamp.compare)
    }
  }
}

fn parse_override_event(
  lines: List(String),
  uid: String,
  calendar_name: String,
  _local_offset: duration.Duration,
  system_tz: Result(String, Nil),
) -> Result(Event, Nil) {
  let props = list.filter_map(lines, parse_property)
  // RFC 5545 §3.8.1.11: STATUS:CANCELLED on an override means the master
  // instance at that RECURRENCE-ID is removed; the override itself produces
  // no event. Drop it here so callers can rely on `override_events` carrying
  // only events meant to surface.
  case props_status_cancelled(props) {
    True -> Error(Nil)
    False -> parse_override_event_active(lines, props, uid, calendar_name, system_tz)
  }
}

fn parse_override_event_active(
  lines: List(String),
  props: List(#(String, String)),
  uid: String,
  calendar_name: String,
  system_tz: Result(String, Nil),
) -> Result(Event, Nil) {
  use summary_raw <- result.try(get_prop(props, "SUMMARY"))
  let summary = unescape_text(summary_raw)
  use dtstart_raw <- result.try(get_prop_prefix(props, "DTSTART"))
  let dtstart_tzid = get_tzid_param(lines, "DTSTART")
  // DTEND tzid: if DTEND is present and floating, inherit DTSTART's tzid.
  let dtend_tzid = case get_tzid_param(lines, "DTEND") {
    Ok(tz) -> Ok(tz)
    Error(Nil) ->
      case dtstart_tzid, get_prop_prefix(props, "DTEND") {
        Ok(tz), Ok(v) ->
          case is_floating_datetime(v) {
            True -> Ok(tz)
            False -> Error(Nil)
          }
        _, _ -> Error(Nil)
      }
  }
  let location =
    get_prop(props, "LOCATION") |> result.unwrap("") |> unescape_text
  let description =
    get_prop(props, "DESCRIPTION") |> result.unwrap("") |> unescape_text
  let url = get_prop(props, "URL") |> result.unwrap("")
  let free =
    get_prop(props, "TRANSP")
    |> result.unwrap("OPAQUE")
    |> string.uppercase
    == "TRANSPARENT"
  use start <- result.try(parse_event_time(
    dtstart_raw,
    dtstart_tzid,
    system_tz,
  ))
  use end <- result.try(derive_event_end(
    start,
    props,
    lines,
    dtend_tzid,
    system_tz,
  ))
  Ok(Event(
    uid:,
    summary:,
    start:,
    end:,
    calendar_name:,
    location:,
    free:,
    description:,
    url:,
  ))
}

/// Collect all EXDATE values, preserving both timed (AtTime) and all-day
/// (AllDay) forms. Per RFC 5545 §3.8.5.1, a single EXDATE line may carry
/// multiple comma-separated values; this splits them.
fn collect_exdates(
  lines: List(String),
  system_tz: Result(String, Nil),
) -> List(EventTime) {
  list.flat_map(lines, fn(line) {
    let upper = string.uppercase(line)
    case string.starts_with(upper, "EXDATE"), string.split_once(line, ":") {
      True, Ok(#(_param_part, value)) -> {
        let tzid = get_tzid_param([line], "EXDATE")
        string.split(value, ",")
        |> list.filter_map(fn(v) {
          parse_event_time(string.trim(v), tzid, system_tz)
        })
      }
      _, _ -> []
    }
  })
}

/// Collect all RDATE values, preserving both timed (AtTime) and all-day
/// (AllDay) forms. Per RFC 5545 §3.8.5.2, RDATE adds explicit recurrence
/// dates beyond the RRULE set. Multiple RDATE lines are merged.
fn collect_rdates(
  lines: List(String),
  system_tz: Result(String, Nil),
) -> List(EventTime) {
  list.flat_map(lines, fn(line) {
    let upper = string.uppercase(line)
    case string.starts_with(upper, "RDATE"), string.split_once(line, ":") {
      True, Ok(#(_param_part, value)) -> {
        let tzid = get_tzid_param([line], "RDATE")
        string.split(value, ",")
        |> list.filter_map(fn(v) {
          parse_event_time(string.trim(v), tzid, system_tz)
        })
      }
      _, _ -> []
    }
  })
}

/// Build an Event from an RDATE EventTime, using the master event's
/// properties (summary, location, etc.) and computing the end time
/// based on the master's duration.
fn event_from_rdate(
  rdate: EventTime,
  duration_secs: Int,
  uid: String,
  summary: String,
  calendar_name: String,
  location: String,
  free: Bool,
  description: String,
  url: String,
) -> Event {
  let end_time = case rdate {
    AtTime(ts) -> AtTime(timestamp.add(ts, duration.seconds(duration_secs)))
    AllDay(d) -> {
      // For all-day, duration is in days; convert seconds to days
      let days = int.max(duration_secs / 86_400, 1)
      AllDay(advance_date_by_n(d, days))
    }
  }
  Event(
    uid: uid,
    summary: summary,
    start: rdate,
    end: end_time,
    calendar_name: calendar_name,
    location: location,
    free: free,
    description: description,
    url: url,
  )
}

/// Filter RDATE events to those within the window, then deduplicate
/// against RRULE-generated events (by start time equality).
fn merge_rdate_events(
  rdates: List(EventTime),
  rrule_events: List(Event),
  duration_secs: Int,
  uid: String,
  summary: String,
  calendar_name: String,
  location: String,
  free: Bool,
  description: String,
  url: String,
  local_offset: duration.Duration,
  window_start: timestamp.Timestamp,
  window_end: timestamp.Timestamp,
) -> List(Event) {
  // Generate events from RDATE values
  let rdate_events =
    list.filter_map(rdates, fn(rdate) {
      let evt =
        event_from_rdate(
          rdate,
          duration_secs,
          uid,
          summary,
          calendar_name,
          location,
          free,
          description,
          url,
        )
      // Keep only events that overlap the window (date-aware for AllDay)
      case
        rdate_event_overlaps_window(
          evt.start,
          evt.end,
          window_start,
          window_end,
          local_offset,
        )
      {
        True -> Ok(evt)
        False -> Error(Nil)
      }
    })

  // Deduplicate: remove RDATE events that match an RRULE event by start time
  list.filter(rdate_events, fn(r_evt) {
    !list.any(rrule_events, fn(rule_evt) {
      event_times_equal(r_evt.start, rule_evt.start)
    })
  })
  |> list.append(rrule_events)
}

/// Window overlap test that handles AllDay events using calendar dates.
/// Equivalent to event_in_window but doesn't unconditionally include AllDay.
fn rdate_event_overlaps_window(
  start: EventTime,
  end: EventTime,
  window_start: timestamp.Timestamp,
  window_end: timestamp.Timestamp,
  local_offset: duration.Duration,
) -> Bool {
  case start, end {
    AtTime(s), AtTime(e) ->
      timestamp.compare(e, window_start) != Lt
      && timestamp.compare(s, window_end) == Lt
    AllDay(s), AllDay(en) -> {
      let ws_date = timestamp.to_calendar(window_start, local_offset).0
      let we_date = timestamp.to_calendar(window_end, local_offset).0
      // Overlap of [s, en) with [ws_date, we_date) requires en >= ws AND s < we
      calendar.naive_date_compare(en, ws_date) != order.Lt
      && calendar.naive_date_compare(s, we_date) == order.Lt
    }
    _, _ -> True
  }
}

/// True if two EventTime values represent the same instant or date.
fn event_times_equal(a: EventTime, b: EventTime) -> Bool {
  case a, b {
    AtTime(ts_a), AtTime(ts_b) -> timestamp.compare(ts_a, ts_b) == order.Eq
    AllDay(d_a), AllDay(d_b) -> d_a == d_b
    _, _ -> False
  }
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

/// True if `date` matches the local-date of an `EventTime` (used for EXDATE
/// matching against an all-day candidate).
fn exdate_matches_date(
  date: calendar.Date,
  et: EventTime,
  local_offset: duration.Duration,
) -> Bool {
  case et {
    AllDay(d) -> d == date
    AtTime(ts) -> {
      let #(d, _) = timestamp.to_calendar(ts, local_offset)
      d == date
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

/// Unescape an RFC 5545 §3.3.11 TEXT value. Walks the string left-to-right
/// (via graphemes) so that `\\n` correctly yields a literal backslash + 'n'
/// rather than being mis-coalesced into a newline by naive replacement.
///
/// Recognized sequences:
///   \\  -> \
///   \;  -> ;
///   \,  -> ,
///   \n  -> LF
///   \N  -> LF
/// Any other `\x` is left as `\x` (per spec: unrecognised escapes are
/// implementation-defined; preserving the bytes is the least lossy choice).
fn unescape_text(s: String) -> String {
  case string.contains(s, "\\") {
    False -> s
    True ->
      string.to_graphemes(s)
      |> unescape_text_loop(string_tree.new())
      |> string_tree.to_string
  }
}

fn unescape_text_loop(
  chars: List(String),
  acc: string_tree.StringTree,
) -> string_tree.StringTree {
  case chars {
    [] -> acc
    ["\\", "n", ..rest] | ["\\", "N", ..rest] ->
      unescape_text_loop(rest, string_tree.append(acc, "\n"))
    ["\\", "\\", ..rest] ->
      unescape_text_loop(rest, string_tree.append(acc, "\\"))
    ["\\", ",", ..rest] ->
      unescape_text_loop(rest, string_tree.append(acc, ","))
    ["\\", ";", ..rest] ->
      unescape_text_loop(rest, string_tree.append(acc, ";"))
    [c, ..rest] -> unescape_text_loop(rest, string_tree.append(acc, c))
  }
}

/// Parse an RFC 5545 §3.3.6 DURATION value into a count of whole seconds.
///
/// Grammar (subset, the spec also allows date+time combos and an explicit
/// sign):
///   dur-value  = ["+" / "-"] "P" ( dur-week / dur-date / dur-time )
///   dur-week   = 1*DIGIT "W"
///   dur-date   = dur-day [dur-time]
///   dur-day    = 1*DIGIT "D"
///   dur-time   = "T" ( dur-hour / dur-minute / dur-second )
///   dur-hour   = 1*DIGIT "H" [dur-minute]
///   dur-minute = 1*DIGIT "M" [dur-second]
///   dur-second = 1*DIGIT "S"
///
/// Examples: PT1H30M, PT45S, P3D, P1W, P1DT12H, -PT15M
fn parse_duration(s: String) -> Result(Int, Nil) {
  let trimmed = string.trim(s)
  let chars = string.to_graphemes(trimmed)
  let #(sign, after_sign) = case chars {
    ["-", ..rest] -> #(-1, rest)
    ["+", ..rest] -> #(1, rest)
    other -> #(1, other)
  }
  case after_sign {
    ["P", ..body] ->
      parse_duration_body(body, 0, False)
      |> result.map(fn(n) { sign * n })
    _ -> Error(Nil)
  }
}

fn parse_duration_body(
  chars: List(String),
  acc: Int,
  in_time: Bool,
) -> Result(Int, Nil) {
  case chars {
    [] -> Ok(acc)
    ["T", ..rest] -> parse_duration_body(rest, acc, True)
    _ -> {
      use #(n, after) <- result.try(take_int_graphemes(chars))
      case after, in_time {
        ["W", ..rest], False ->
          parse_duration_body(rest, acc + n * 604_800, False)
        ["D", ..rest], False ->
          parse_duration_body(rest, acc + n * 86_400, False)
        ["H", ..rest], True ->
          parse_duration_body(rest, acc + n * 3600, True)
        ["M", ..rest], True ->
          parse_duration_body(rest, acc + n * 60, True)
        ["S", ..rest], True -> parse_duration_body(rest, acc + n, True)
        _, _ -> Error(Nil)
      }
    }
  }
}

fn take_int_graphemes(
  chars: List(String),
) -> Result(#(Int, List(String)), Nil) {
  let #(digit_chars, rest) = list.split_while(chars, is_digit_grapheme)
  case digit_chars {
    [] -> Error(Nil)
    _ -> {
      let s = string.concat(digit_chars)
      use n <- result.try(int.parse(s))
      Ok(#(n, rest))
    }
  }
}

fn is_digit_grapheme(c: String) -> Bool {
  case c {
    "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" -> True
    _ -> False
  }
}

/// Add `secs` seconds to an EventTime to derive a DTEND. For AtTime, this is
/// straight timestamp addition. For AllDay, the duration must be a whole
/// number of days (else Error).
fn add_seconds_to_event_time(
  start: EventTime,
  secs: Int,
) -> Result(EventTime, Nil) {
  case start {
    AtTime(ts) -> Ok(AtTime(timestamp.add(ts, duration.seconds(secs))))
    AllDay(date) ->
      case secs % 86_400 {
        0 -> Ok(AllDay(advance_date_by_n(date, secs / 86_400)))
        _ -> Error(Nil)
      }
  }
}

/// Determine the effective DTEND for a VEVENT given its parsed DTSTART and
/// the property table. Falls back per RFC 5545 §3.6.1:
///   * DTEND present → use it (existing behaviour)
///   * DURATION present → DTEND = DTSTART + DURATION
///   * Neither → AllDay: +1 day; AtTime: zero duration (end == start)
fn derive_event_end(
  start: EventTime,
  props: List(#(String, String)),
  lines: List(String),
  dtend_tzid: Result(String, Nil),
  system_tz: Result(String, Nil),
) -> Result(EventTime, Nil) {
  case get_prop_prefix(props, "DTEND") {
    Ok(dtend_raw) -> {
      let _ = lines
      parse_event_time(dtend_raw, dtend_tzid, system_tz)
    }
    Error(Nil) ->
      case get_prop(props, "DURATION") {
        Ok(dur_raw) ->
          parse_duration(dur_raw)
          |> result.try(fn(secs) { add_seconds_to_event_time(start, secs) })
        Error(Nil) ->
          case start {
            AllDay(d) -> Ok(AllDay(advance_date_by_n(d, 1)))
            AtTime(_) -> Ok(start)
          }
      }
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

/// Return True iff the property list contains STATUS:CANCELLED (RFC 5545
/// §3.8.1.11). Comparison is case-insensitive on the value; the property
/// name is already uppercased by parse_property. Trailing whitespace is
/// trimmed for resilience against minor formatting quirks.
fn props_status_cancelled(props: List(#(String, String))) -> Bool {
  case get_prop(props, "STATUS") {
    Ok(v) -> string.uppercase(string.trim(v)) == "CANCELLED"
    Error(Nil) -> False
  }
}

/// Detect `RANGE=THISANDFUTURE` on a RECURRENCE-ID line. Per RFC 5545
/// §3.2.13 the RANGE parameter, when present, can only take the value
/// `THISANDFUTURE`; any other value is invalid and treated as absent
/// (i.e. the override is a single-instance override).
///
/// The comparison is case-insensitive on the parameter value because
/// some producers emit lowercase parameter values despite the spec
/// recommending uppercase keywords.
fn has_thisandfuture_range(lines: List(String)) -> Bool {
  list.any(lines, fn(line) {
    let upper = string.uppercase(line)
    case string.starts_with(upper, "RECURRENCE-ID;") {
      False -> False
      True ->
        // Match the parameter only up to the next ':' so a literal
        // "RANGE=THISANDFUTURE" inside the VALUE (after the colon) is
        // not misread as the parameter.
        case string.split_once(upper, ":") {
          Ok(#(param_part, _)) ->
            string.contains(param_part, "RANGE=THISANDFUTURE")
          Error(Nil) -> False
        }
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

/// Extract the TZID value from a property line for `prop_name`, if present.
/// E.g. "DTSTART;TZID=America/Chicago:20260307T064800" → Ok("America/Chicago")
///
/// Per RFC 5545 §3.2.19, parameter values may be wrapped in DQUOTEs. The
/// DQUOTEs are NOT part of the value, so we strip them before returning.
fn get_tzid_param(
  lines: List(String),
  prop_name: String,
) -> Result(String, Nil) {
  let upper_name = string.uppercase(prop_name)
  list.find_map(lines, fn(line) {
    let upper = string.uppercase(line)
    let prefix = upper_name <> ";TZID="
    case string.starts_with(upper, prefix) {
      False -> Error(Nil)
      True -> {
        // Everything between ";TZID=" and the next ":" (outside of quotes)
        // is the timezone name. Use the original case-preserved line so
        // "America/Chicago" is not uppercased.
        let after_tzid = string.drop_start(line, string.length(prefix))
        case extract_param_value(after_tzid) {
          Ok(tz_name) -> Ok(tz_name)
          Error(Nil) -> Error(Nil)
        }
      }
    }
  })
}

/// Read a parameter value up to the next unquoted `:` or `;`, stripping
/// surrounding DQUOTEs if the value is quoted. Returns the bare value.
///
/// Examples:
///   "America/Chicago:20260307T064800"    -> Ok("America/Chicago")
///   "\"America/New_York\":20260307..."    -> Ok("America/New_York")
///   "\"GMT+05:30\":20260307..."           -> Ok("GMT+05:30")
fn extract_param_value(s: String) -> Result(String, Nil) {
  case string.starts_with(s, "\"") {
    True -> {
      // Quoted: scan up to the closing DQUOTE.
      let inner = string.drop_start(s, 1)
      case string.split_once(inner, "\"") {
        Ok(#(value, _)) -> Ok(value)
        Error(Nil) -> Error(Nil)
      }
    }
    False -> {
      // Unquoted: take up to the next ";" (next param) or ":" (value separator),
      // whichever comes first.
      Ok(scan_unquoted_param_value(s, ""))
    }
  }
}

/// Consume characters from `s` until a `;` or `:` is hit, accumulating
/// into `acc`. Returns the accumulated value (possibly empty).
fn scan_unquoted_param_value(s: String, acc: String) -> String {
  case string.pop_grapheme(s) {
    Error(Nil) -> acc
    Ok(#(c, rest)) ->
      case c {
        ";" -> acc
        ":" -> acc
        _ -> scan_unquoted_param_value(rest, acc <> c)
      }
  }
}



/// True if a datetime value string is a floating local time (no Z suffix, 15 chars).
/// YYYYMMDDTHHMMSS (15 chars) = floating; YYYYMMDDTHHMMSSZ (16 chars) = UTC.
fn is_floating_datetime(value: String) -> Bool {
  let trimmed = string.trim(value)
  string.length(trimmed) == 15
}

// DATETIME PARSING ------------------------------------------------------------

/// Parse an iCalendar date or datetime value into an EventTime.
///
/// `tzid` should be:
///   Ok("America/Chicago") — TZID-annotated: converted via qdate_localtime FFI
///   Error(Nil)            — UTC (Z suffix) or floating (server-local fallback)
///
/// `system_tz` is the system's IANA timezone, used for floating datetimes (no Z, no TZID).
fn parse_event_time(
  value: String,
  tzid: Result(String, Nil),
  system_tz: Result(String, Nil),
) -> Result(EventTime, Nil) {
  let trimmed = string.trim(value)

  case string.length(trimmed) {
    // DATE format: YYYYMMDD
    8 -> parse_date(trimmed) |> result.map(AllDay)
    // DATE-TIME: YYYYMMDDTHHMMSSZ (UTC, 16 chars) or YYYYMMDDTHHMMSS (floating/TZID, 15 chars)
    15 | 16 -> {
      case tzid {
        Ok(tz) -> {
          // TZID-annotated: convert wall-clock time in `tz` to UTC via FFI.
          use ts <- result.try(parse_datetime_with_tz(trimmed, tz))
          Ok(AtTime(ts))
        }
        Error(Nil) -> {
          case is_floating_datetime(trimmed), system_tz {
            // Floating datetime with known system timezone: treat as wall clock in system TZ.
            // Use the same DST-aware conversion as TZID-annotated events.
            True, Ok(tz) -> {
              use ts <- result.try(parse_datetime_with_tz(trimmed, tz))
              Ok(AtTime(ts))
            }
            // UTC (Z suffix) or floating with unknown system TZ: parse as UTC.
            _, _ -> {
              use ts <- result.try(parse_datetime(trimmed))
              Ok(AtTime(ts))
            }
          }
        }
      }
    }
    _ -> Error(Nil)
  }
}

/// Add a recurrence interval to a timestamp while preserving wall-clock time across DST transitions.
/// This ensures recurring events maintain their local time even when crossing DST boundaries.
fn add_recurrence_dst_aware(
  ts: timestamp.Timestamp,
  freq: RecurrenceFreq,
  interval: Int,
  event_tz: Result(String, Nil),
  _local_offset: duration.Duration,
) -> timestamp.Timestamp {
  case event_tz {
    Ok(tz) -> {
      // Convert the UTC timestamp to Gregorian seconds
      let unix_secs = duration.to_seconds(timestamp.difference(timestamp.unix_epoch, ts))
      let utc_gregorian = float.truncate(unix_secs) + gregorian_epoch_offset
      
      // Convert to calendar date/time in UTC
      let utc_datetime = gregorian_seconds_to_datetime(utc_gregorian)
      let #(#(year, month_int, day), #(hour, minute, second)) = utc_datetime
      
      // Convert UTC to the event's local timezone
      let local_gregorian = tz_utc_to_local(year, month_int, day, hour, minute, second, tz)
      let local_datetime = gregorian_seconds_to_datetime(local_gregorian)
      let #(#(local_year, local_month_int, local_day), #(local_hour, local_minute, local_second)) = local_datetime
      
      // Convert to Gleam Date type
      let local_month = case int_to_month(local_month_int) {
        Ok(m) -> m
        Error(Nil) -> calendar.January  // Fallback, should never happen
      }
      let local_date = Date(year: local_year, month: local_month, day: local_day)
      
      // Advance the date based on frequency and interval
      let new_date = case freq {
        Daily -> advance_date_by_n(local_date, interval)
        Weekly -> advance_date_by_n(local_date, interval * 7)
        Monthly -> advance_date_by_months(local_date, interval)
        Yearly -> advance_date_by_years(local_date, interval)
      }
      
      let Date(new_year, new_month, new_day) = new_date
      let new_month_int = calendar.month_to_int(new_month)
      
      // Convert back to UTC using the timezone (this handles DST properly)
      let new_utc_gregorian =
        tz_local_to_utc(new_year, new_month_int, new_day, local_hour, local_minute, local_second, tz)
      let new_unix_secs = new_utc_gregorian - gregorian_epoch_offset
      timestamp.from_unix_seconds(new_unix_secs)
    }
    Error(Nil) -> {
      // No timezone info: fall back to simple time addition
      let seconds = case freq {
        Daily -> interval * 86_400
        Weekly -> interval * 7 * 86_400
        Monthly -> interval * 30 * 86_400  // Approximate
        Yearly -> interval * 365 * 86_400  // Approximate
      }
      timestamp.add(ts, duration.seconds(seconds))
    }
  }
}

/// Gregorian seconds for the Unix epoch (1970-01-01T00:00:00Z).
/// Equals calendar:datetime_to_gregorian_seconds({{1970,1,1},{0,0,0}}) in Erlang.
const gregorian_epoch_offset: Int = 62_167_219_200

/// Parse a datetime string (YYYYMMDDTHHMMSS[Z]) and convert from the given
/// IANA timezone to a UTC Timestamp using the qdate_localtime FFI.
fn parse_datetime_with_tz(
  s: String,
  tz: String,
) -> Result(timestamp.Timestamp, Nil) {
  use year <- result.try(parse_int_slice(s, 0, 4))
  use month_int <- result.try(parse_int_slice(s, 4, 2))
  use day <- result.try(parse_int_slice(s, 6, 2))
  use hour <- result.try(parse_int_slice(s, 9, 2))
  use minute <- result.try(parse_int_slice(s, 11, 2))
  use second <- result.try(parse_int_slice(s, 13, 2))
  use _ <- result.try(int_to_month(month_int))
  let utc_gregorian =
    tz_local_to_utc(year, month_int, day, hour, minute, second, tz)
  let unix_secs = utc_gregorian - gregorian_epoch_offset
  Ok(timestamp.from_unix_seconds(unix_secs))
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
