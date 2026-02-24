// IMPORTS ---------------------------------------------------------------------

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/order
import gleam/result
import gleam/string
import gleam/time/calendar.{type Date, Date}
import gleam/time/duration
import gleam/time/timestamp.{type Timestamp}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import travel

// TYPES -----------------------------------------------------------------------

/// When an event starts or ends.
/// All-day events only carry a Date; timed events carry a UTC Timestamp.
pub type EventTime {
  AllDay(date: Date)
  AtTime(timestamp: Timestamp)
}

/// A single calendar event, as fetched and parsed from CalDAV.
pub type Event {
  Event(
    uid: String,
    summary: String,
    start: EventTime,
    end: EventTime,
    calendar_name: String,
    location: String,
  )
}

/// Travel info resolved for an event's location (home → location).
/// city: short display name (e.g. "Boston")
/// distance_text: human-readable distance from home (e.g. "2.3 mi")
/// duration_text: travel time from home with traffic (e.g. "12 min")
/// duration_secs: travel time in seconds (for routing math)
pub type TravelInfo {
  TravelInfo(
    city: String,
    distance_text: String,
    duration_text: String,
    duration_secs: Int,
  )
}

/// Cache of point-to-point travel durations, keyed by "origin|||destination".
/// Includes home→loc, loc→home, and loc_a→loc_b legs.
pub type LegCache =
  Dict(String, Int)

/// A travel block to render between (or around) events on the timeline.
pub type TravelBlock {
  TravelBlock(
    /// Start of the gap (end of prior event, or midnight for first block).
    gap_start: Timestamp,
    /// End of the gap (start of next event, or end-of-day for last block).
    gap_end: Timestamp,
    /// True = the person can make a home stop; False = direct A→B route.
    via_home: Bool,
    /// Chosen travel time in seconds.
    travel_secs: Int,
    /// Human-readable travel label, e.g. "8 min" or "22 min".
    travel_text: String,
    /// Free dwell time after travel, in seconds (gap - travel).
    dwell_secs: Int,
    /// True = anchor block at gap_end (arrival-aligned: depart home / between events).
    /// False = anchor at gap_start (departure-aligned: return home after last event).
    arrival_aligned: Bool,
  )
}

// TRAVEL BLOCK COMPUTATION ----------------------------------------------------

/// Slack added on top of via-home travel time before choosing home route (secs).
const home_detour_slack_secs = 900

/// Compute travel blocks for a sequence of timed events on a single day.
///
/// `events`        — timed events for this person on this day, sorted by start.
/// `travel_cache`  — home→loc cache (keyed by location string).
/// `leg_cache`     — point-to-point durations keyed by leg_cache_key/2.
/// `home_key`      — the canonical home address string used as a cache key.
/// `leg_key`       — fn(origin, dest) -> String cache key (from travel module).
///
/// Returns a list of TravelBlocks. Blocks are only generated where there is a
/// known travel time on at least one side of the gap.
pub fn compute_travel_blocks(
  events: List(Event),
  leg_cache: LegCache,
  home_key: String,
  leg_key: fn(String, String) -> String,
) -> List(TravelBlock) {
  // Keep only timed events with a known start/end.
  let timed =
    list.filter(events, fn(e) {
      case e.start, e.end {
        AtTime(_), AtTime(_) -> True
        _, _ -> False
      }
    })

  case timed {
    [] -> []
    _ -> {
      // Helper: look up leg duration in seconds.
      let get_leg = fn(origin: String, dest: String) -> Result(Int, Nil) {
        dict.get(leg_cache, leg_key(origin, dest))
      }

      // Build a list of gaps to analyse. Each gap is:
      //   #(gap_start_ts, gap_end_ts, origin_loc, dest_loc)
      // where origin_loc / dest_loc are "" for "home" or locationless events.
      //
      // We generate:
      //   home → first located event
      //   located_event_end → next located event_start  (skipping locationless)
      //   last located event → home
      //
      // "locationless" events are in-place: we do NOT travel to them, but we
      // DO let time pass through them. For routing purposes they are transparent:
      // travel home happens after the last located event before the locationless
      // run, only if there's enough time before the next located event.

      // Separate into located vs locationless for the sequencing.
      // We work through the sorted event list and emit a gap wherever we have
      // origin and destination locations.
      let gaps = build_gaps(timed, home_key)

      list.filter_map(gaps, fn(gap) {
        let #(gap_start, gap_end, origin, dest) = gap
        let gap_secs =
          timestamp.difference(gap_end, gap_start)
          |> duration.to_seconds
          |> float_to_int_floor

        // Try via-home route: origin→home + home→dest.
        let via_home_secs = case origin == home_key, dest == home_key {
          // Already at home: no outbound leg needed.
          True, _ -> result.map(get_leg(home_key, dest), fn(d) { d })
          // Returning home: no inbound leg needed.
          _, True -> result.map(get_leg(origin, home_key), fn(o) { o })
          // Neither endpoint is home.
          False, False -> {
            use o <- result.try(get_leg(origin, home_key))
            use d <- result.try(get_leg(home_key, dest))
            Ok(o + d)
          }
        }

        // Try direct route: origin→dest.
        let direct_secs = get_leg(origin, dest)

        // Arrival-aligned = block renders ending at gap_end (right before next event).
        // Departure-aligned = block renders starting at gap_start (right after last event).
        // "Return home" gaps (dest == home_key) are departure-aligned; all others are arrival.
        let arrival_aligned = dest != home_key

        case via_home_secs, direct_secs {
          // No travel info at all — skip this gap.
          Error(_), Error(_) -> Error(Nil)

          // Only direct route available.
          Error(_), Ok(d) -> {
            let dwell = int.max(gap_secs - d, 0)
            Ok(TravelBlock(
              gap_start:,
              gap_end:,
              via_home: False,
              travel_secs: d,
              travel_text: secs_to_min_text(d),
              dwell_secs: dwell,
              arrival_aligned:,
            ))
          }

          // Only via-home available.
          Ok(vh), Error(_) -> {
            let dwell = int.max(gap_secs - vh, 0)
            Ok(TravelBlock(
              gap_start:,
              gap_end:,
              via_home: True,
              travel_secs: vh,
              travel_text: secs_to_min_text(vh),
              dwell_secs: dwell,
              arrival_aligned:,
            ))
          }

          // Both available: choose home route if it fits with slack.
          Ok(vh), Ok(d) -> {
            let use_home = vh + home_detour_slack_secs <= gap_secs
            let travel = case use_home {
              True -> vh
              False -> d
            }
            let dwell = int.max(gap_secs - travel, 0)
            Ok(TravelBlock(
              gap_start:,
              gap_end:,
              via_home: use_home,
              travel_secs: travel,
              travel_text: secs_to_min_text(travel),
              dwell_secs: dwell,
              arrival_aligned:,
            ))
          }
        }
      })
    }
  }
}

/// Build the list of #(gap_start, gap_end, origin_loc, dest_loc) tuples from
/// a sorted list of timed events. Origin/dest are location strings; home_key
/// is used for the first and last synthetic gap.
fn build_gaps(
  events: List(Event),
  home_key: String,
) -> List(#(Timestamp, Timestamp, String, String)) {
  case events {
    [] -> []
    _ -> {
      // Find the first and last event that have a location (for home bookends).
      let located = list.filter(events, fn(e) { e.location != "" })
      case located {
        [] -> []
        [first_loc, ..] -> {
          let last_loc = list.fold(located, first_loc, fn(_, e) { e })

          // home → first located event:
          // gap spans from midnight (day start) to first event start.
          let first_gap = case first_loc.start {
            AtTime(ts) -> {
              let day_start = day_midnight(ts)
              [#(day_start, ts, home_key, first_loc.location)]
            }
            AllDay(_) -> []
          }

          // last located event → home:
          // gap spans from last event end to end of day.
          let last_gap = case last_loc.end {
            AtTime(ts) -> {
              let day_end =
                timestamp.add(day_midnight(ts), gleam_time_duration_hours(24))
              [#(ts, day_end, last_loc.location, home_key)]
            }
            AllDay(_) -> []
          }

          // Between consecutive events: walk through and emit gaps where
          // the prior event had a location and the next event has a location,
          // using event end→start as the gap timestamps.
          // Locationless events are transparent (in-place), so we track the
          // "current origin" as the last seen located event's location.
          let between_gaps = build_between_gaps(events, located, home_key)

          list.flatten([first_gap, between_gaps, last_gap])
        }
      }
    }
  }
}

/// Emit inter-event gaps. We iterate the full event list, tracking the
/// "current origin location" = location of the last event that had one.
/// When we encounter an event with a location, we emit a gap from
/// (end of prior located event OR home) to (start of this event).
fn build_between_gaps(
  all_events: List(Event),
  _located: List(Event),
  home_key: String,
) -> List(#(Timestamp, Timestamp, String, String)) {
  // Walk events in order. prev_loc = location of last event with a location.
  // prev_end = end timestamp of that event.
  let #(gaps, _, _) =
    list.fold(all_events, #([], home_key, option_none_ts()), fn(acc, e) {
      let #(gaps, prev_loc, prev_end) = acc
      case e.location, e.start, e.end {
        loc, AtTime(s), AtTime(en) if loc != "" -> {
          // This event has a location. Emit a gap from prev_end to s,
          // but only if there was a prior located event (prev_end != epoch).
          let new_gaps = case is_epoch(prev_end) {
            True -> gaps
            False -> [#(prev_end, s, prev_loc, loc), ..gaps]
          }
          #(new_gaps, loc, en)
        }
        _, AtTime(_), AtTime(en) -> {
          // Locationless event: transparent, but advance prev_end so
          // the next located event measures gap from after this one.
          // prev_loc stays the same (still "at" wherever we were before).
          let new_end = case is_epoch(prev_end) {
            True -> prev_end
            False -> en
          }
          #(gaps, prev_loc, new_end)
        }
        _, _, _ -> acc
      }
    })
  list.reverse(gaps)
}

fn option_none_ts() -> Timestamp {
  timestamp.from_unix_seconds(0)
}

fn is_epoch(ts: Timestamp) -> Bool {
  timestamp.to_unix_seconds_and_nanoseconds(ts).0 == 0
}

/// Return the midnight (00:00 UTC) timestamp for the same calendar day as `ts`
/// in the local timezone. Used to define day-start bookend gaps.
fn day_midnight(ts: Timestamp) -> Timestamp {
  let local_offset = calendar.local_offset()
  let offset_secs = duration.to_seconds(local_offset) |> float_to_int_floor
  // Get the local unix seconds and truncate to day boundary.
  let unix_secs = timestamp.to_unix_seconds_and_nanoseconds(ts).0
  let local_secs = unix_secs + offset_secs
  let day_start_local = local_secs - local_secs % 86_400
  timestamp.from_unix_seconds(day_start_local - offset_secs)
}

fn gleam_time_duration_hours(n: Int) -> duration.Duration {
  duration.seconds(n * 3600)
}

fn float_to_int_floor(f: Float) -> Int {
  case f >=. 0.0 {
    True -> float_truncate(f)
    False -> float_truncate(f) - 1
  }
}

@external(erlang, "erlang", "trunc")
fn float_truncate(f: Float) -> Int

/// Format seconds as "N min", rounding to nearest minute.
pub fn secs_to_min_text(secs: Int) -> String {
  let mins = { secs + 30 } / 60
  int.to_string(mins) <> " min"
}

// LAYOUT CONSTANTS ------------------------------------------------------------

/// Default visible window: 7:00 am.
const default_window_start_min = 420

/// Default visible window: 9:00 pm.
const default_window_end_min = 1260

/// Minimum event block height as a fraction of the total window (0.0–1.0).
/// Corresponds to ~15 minutes regardless of window size.
const min_event_frac = 0.0173

// VIEW ------------------------------------------------------------------------

/// Rendered while calendar_server has not yet delivered its first fetch.
pub fn view_loading() -> Element(msg) {
  html.p([attribute.class("p-4 text-text-muted italic text-sm")], [
    html.text("Loading calendar…"),
  ])
}

/// Rendered when the CalDAV fetch failed.
pub fn view_error(reason: String) -> Element(msg) {
  html.p([attribute.class("p-4 text-red-500 text-sm")], [
    html.text("Calendar error: " <> reason),
  ])
}

/// The main 7-day view. Shows events for today and the next 6 days.
/// All columns share the same time window so timelines are aligned.
/// `color_for` is a fn(calendar_name) -> css_color_string for per-cal coloring.
pub fn view_seven_days(
  events: List(Event),
  color_for: fn(String) -> String,
  travel_cache: Dict(String, TravelInfo),
  leg_cache: LegCache,
  home_address: String,
) -> Element(msg) {
  let now = timestamp.system_time()
  let local_offset = calendar.local_offset()
  let today_date = timestamp.to_calendar(now, local_offset).0
  let days = next_n_dates(today_date, 7)

  // Collect per-day timed event lists (for window computation).
  let day_timed_lists =
    list.map(days, fn(day) {
      list.filter(events, fn(e) {
        case e.start {
          AtTime(_) ->
            calendar.naive_date_compare(
              timestamp.to_calendar(
                case e.start {
                  AtTime(ts) -> ts
                  AllDay(_) -> timestamp.system_time()
                },
                local_offset,
              ).0,
              day,
            )
            == order.Eq
          AllDay(_) -> False
        }
      })
    })

  // Shared time window across all days.
  let window = compute_window(day_timed_lists, local_offset)

  // Compute a stable row assignment for all-day events visible in this window.
  // This ensures a multi-day event appears on the same row across all columns.
  let #(all_day_row_map, all_day_row_count) = compute_all_day_rows(events, days)

  html.div(
    [
      attribute.class(
        "flex-1 min-h-0 grid grid-cols-7 gap-px p-2 overflow-hidden bg-surface",
      ),
    ],
    list.map(days, fn(day) {
      let day_all_day =
        list.filter(events, fn(e) { all_day_spans_date(e, day) })
      let day_timed =
        list.filter(events, fn(e) {
          case e.start {
            AtTime(ts) ->
              calendar.naive_date_compare(
                timestamp.to_calendar(ts, local_offset).0,
                day,
              )
              == order.Eq
            AllDay(_) -> False
          }
        })
      // Compute travel blocks for this day's events.
      let day_blocks = case home_address {
        "" -> []
        addr ->
          compute_travel_blocks(
            day_timed,
            leg_cache,
            addr,
            travel.leg_cache_key,
          )
      }
      view_day(
        day,
        day == today_date,
        day_all_day,
        day_timed,
        local_offset,
        window,
        all_day_row_map,
        all_day_row_count,
        color_for,
        travel_cache,
        day_blocks,
      )
    }),
  )
}

// TIME WINDOW -----------------------------------------------------------------

/// Minutes-since-midnight window shared across all day columns.
type Window {
  Window(start_min: Int, end_min: Int)
}

fn compute_window(
  day_timed_lists: List(List(Event)),
  local_offset: duration.Duration,
) -> Window {
  let timed_events = list.flatten(day_timed_lists)

  case timed_events {
    [] -> Window(default_window_start_min, default_window_end_min)
    _ -> {
      let start_mins =
        list.filter_map(timed_events, fn(e) {
          case e.start {
            AtTime(ts) -> {
              let #(_, t) = timestamp.to_calendar(ts, local_offset)
              Ok(t.hours * 60 + t.minutes)
            }
            AllDay(_) -> Error(Nil)
          }
        })
      let end_mins =
        list.filter_map(timed_events, fn(e) {
          case e.end {
            AtTime(ts) -> {
              let #(_, t) = timestamp.to_calendar(ts, local_offset)
              Ok(t.hours * 60 + t.minutes)
            }
            AllDay(_) -> Error(Nil)
          }
        })

      let earliest = list.fold(start_mins, default_window_start_min, int.min)
      let latest = list.fold(end_mins, default_window_end_min, int.max)

      let snapped_start = earliest / 60 * 60
      let snapped_end = case latest % 60 {
        0 -> latest
        _ -> { latest / 60 + 1 } * 60
      }

      Window(
        start_min: int.min(snapped_start, default_window_start_min),
        end_min: int.max(snapped_end, default_window_end_min),
      )
    }
  }
}

// ALL-DAY ROW ASSIGNMENT ------------------------------------------------------

/// Returns a stable uid→row mapping and total row count for all-day events
/// visible in the 7-day window. Events are sorted by start date then uid for
/// determinism, then packed greedily into rows (like a calendar "chip" layout).
fn compute_all_day_rows(
  events: List(Event),
  days: List(Date),
) -> #(Dict(String, Int), Int) {
  let window_start = case days {
    [d, ..] -> d
    [] -> Date(2000, calendar.January, 1)
  }
  let window_end = case list.last(days) {
    Ok(d) -> advance_date(d)
    Error(_) -> window_start
  }

  // Collect all-day events that overlap the 7-day window.
  let visible =
    list.filter(events, fn(e) {
      case e.start, e.end {
        AllDay(s), AllDay(en) ->
          // Event overlaps window if it starts before window_end and ends after window_start.
          date_lt(s, window_end) && date_gte(en, window_start)
        _, _ -> False
      }
    })
    |> list.sort(fn(a, b) {
      case a.start, b.start {
        AllDay(sa), AllDay(sb) ->
          case calendar.naive_date_compare(sa, sb) {
            order.Eq -> string.compare(a.uid, b.uid)
            other -> other
          }
        _, _ -> order.Eq
      }
    })

  // Greedy row packing: assign each event to the first row where
  // the last event's end date is <= this event's start date.
  // row_ends: list of (row_index, last_end_date) for occupied rows.
  let #(row_map, row_ends, _) =
    list.fold(visible, #(dict.new(), [], 0), fn(acc, e) {
      let #(map, row_ends, _next_row) = acc
      case e.start {
        AllDay(start) -> {
          let end_date = case e.end {
            AllDay(d) -> d
            AtTime(_) -> start
          }
          // Find the first row whose last event ends on or before this start.
          let maybe_row =
            list.fold(row_ends, Error(Nil), fn(found, pair) {
              case found {
                Ok(_) -> found
                Error(_) -> {
                  let #(row_idx, last_end) = pair
                  case date_lte(last_end, start) {
                    True -> Ok(row_idx)
                    False -> Error(Nil)
                  }
                }
              }
            })
          case maybe_row {
            Ok(row_idx) -> {
              let new_ends =
                list.map(row_ends, fn(pair) {
                  let #(ri, _) = pair
                  case ri == row_idx {
                    True -> #(ri, end_date)
                    False -> pair
                  }
                })
              #(
                dict.insert(map, e.uid, row_idx),
                new_ends,
                list.length(new_ends),
              )
            }
            Error(_) -> {
              let new_row = list.length(row_ends)
              #(
                dict.insert(map, e.uid, new_row),
                list.append(row_ends, [#(new_row, end_date)]),
                new_row + 1,
              )
            }
          }
        }
        AtTime(_) -> acc
      }
    })

  let total_rows = list.length(row_ends)
  #(row_map, total_rows)
}

// DAY VIEW --------------------------------------------------------------------

fn view_day(
  date: Date,
  is_today: Bool,
  all_day_events: List(Event),
  timed_events: List(Event),
  local_offset: duration.Duration,
  window: Window,
  all_day_row_map: Dict(String, Int),
  all_day_row_count: Int,
  color_for: fn(String) -> String,
  travel_cache: Dict(String, TravelInfo),
  day_blocks: List(TravelBlock),
) -> Element(msg) {
  html.div(
    [
      attribute.class("flex flex-col rounded-lg overflow-hidden border"),
      attribute.class(case is_today {
        True -> "border-border-dim bg-surface"
        False -> "border-border"
      }),
    ],
    [
      view_day_header(date, is_today),
      view_all_day_strip(
        all_day_events,
        all_day_row_map,
        all_day_row_count,
        color_for,
        travel_cache,
      ),
      view_timeline(
        timed_events,
        local_offset,
        window,
        is_today,
        color_for,
        travel_cache,
        day_blocks,
      ),
    ],
  )
}

fn view_day_header(date: Date, is_today: Bool) -> Element(msg) {
  html.div(
    [
      attribute.class("flex items-baseline gap-2 px-2 py-1.5 shrink-0 border-b"),
      attribute.class(case is_today {
        True -> "bg-surface-2 border-accent-border-dim"
        False -> "bg-surface border-border"
      }),
    ],
    [
      html.span(
        [
          attribute.class("text-xs font-semibold uppercase tracking-wide"),
          attribute.class(case is_today {
            True -> "text-accent"
            False -> "text-text-muted"
          }),
        ],
        [html.text(weekday_name(date))],
      ),
      html.span(
        [
          attribute.class("text-xs"),
          attribute.class(case is_today {
            True -> "text-accent-dim"
            False -> "text-text-faint"
          }),
        ],
        [html.text(format_date(date))],
      ),
    ],
  )
}

// ALL-DAY STRIP ---------------------------------------------------------------

/// Renders all-day events at their stable row positions.
/// All columns reserve the same total height (all_day_row_count * 1.4em)
/// so timelines start at the same vertical offset across the grid.
fn view_all_day_strip(
  events: List(Event),
  row_map: Dict(String, Int),
  row_count: Int,
  color_for: fn(String) -> String,
  travel_cache: Dict(String, TravelInfo),
) -> Element(msg) {
  let row_em = 1.4
  let strip_h = float_em(int_to_float(row_count) *. row_em)

  let event_els =
    list.filter_map(events, fn(e) {
      case dict.get(row_map, e.uid) {
        Error(_) -> Error(Nil)
        Ok(row) -> {
          let color = color_for(e.calendar_name)
          let top_em = float_em(int_to_float(row) *. row_em)
          let h_em = float_em(row_em -. 0.1)
          // Show city suffix for all-day events with a resolved location.
          let city_suffix = case e.location {
            "" -> ""
            loc ->
              case dict.get(travel_cache, loc) {
                Ok(info) -> " · " <> info.city
                Error(_) -> ""
              }
          }
          Ok(
            html.div(
              [
                attribute.class(
                  "absolute left-0 right-0 flex items-center px-1 overflow-hidden",
                ),
                attribute.styles([#("top", top_em), #("height", h_em)]),
              ],
              [
                html.div(
                  [
                    attribute.class(
                      "flex-1 text-xs leading-none truncate border-l-2 p-2 rounded-lg",
                    ),
                    attribute.style("border-left-color", color),
                    attribute.style("background-color", bgcolor(color)),
                  ],
                  [html.text(e.summary <> city_suffix)],
                ),
              ],
            ),
          )
        }
      }
    })

  html.div(
    [
      attribute.class("relative shrink-0 border-b border-border"),
      attribute.style("height", strip_h),
    ],
    event_els,
  )
}

// TIMELINE --------------------------------------------------------------------

/// A timed event annotated with its overlap column index and total column count.
type PositionedEvent {
  PositionedEvent(event: Event, col: Int, col_count: Int)
}

/// Assign column indices to timed events so overlapping events sit side by side.
///
/// Pass 1: greedy interval-graph colouring — sort by start, assign each event
/// to the first column whose last occupant ends before this event starts.
///
/// Pass 2: for each event, col_count = 1 + max column index among all events
/// that directly overlap with it. This means non-overlapping events stay
/// full-width, and each overlap cluster only narrows its own members.
fn assign_columns(
  events: List(Event),
  local_offset: duration.Duration,
) -> List(PositionedEvent) {
  let sorted = list.sort(events, fn(a, b) { compare_event_start(a, b) })

  // Pass 1: assign column indices.
  let positioned =
    list.fold(sorted, #([], []), fn(acc, e) {
      let #(placed, cols) = acc
      let s = event_start_min(e, local_offset)
      let en = event_end_min(e, local_offset)

      let maybe_col =
        list.index_map(cols, fn(col_end, idx) { #(idx, col_end) })
        |> list.find(fn(pair) {
          let #(_, col_end) = pair
          col_end <= s
        })

      let col_idx = case maybe_col {
        Ok(#(idx, _)) -> idx
        Error(_) -> list.length(cols)
      }

      let new_cols = case col_idx >= list.length(cols) {
        True -> list.append(cols, [en])
        False ->
          list.index_map(cols, fn(v, i) {
            case i == col_idx {
              True -> en
              False -> v
            }
          })
      }

      #(
        list.append(placed, [
          PositionedEvent(event: e, col: col_idx, col_count: 0),
        ]),
        new_cols,
      )
    }).0

  // Pass 2: for each event, find all events it overlaps with and take
  // 1 + max(col_index) across that set as its col_count.
  list.map(positioned, fn(pe) {
    let s = event_start_min(pe.event, local_offset)
    let en = event_end_min(pe.event, local_offset)
    let max_col =
      list.fold(positioned, pe.col, fn(acc, other) {
        let os = event_start_min(other.event, local_offset)
        let oe = event_end_min(other.event, local_offset)
        case os < en && oe > s {
          True -> int.max(acc, other.col)
          False -> acc
        }
      })
    PositionedEvent(..pe, col_count: max_col + 1)
  })
}

fn event_start_min(e: Event, local_offset: duration.Duration) -> Int {
  case e.start {
    AtTime(ts) -> {
      let #(_, t) = timestamp.to_calendar(ts, local_offset)
      t.hours * 60 + t.minutes
    }
    AllDay(_) -> 0
  }
}

fn event_end_min(e: Event, local_offset: duration.Duration) -> Int {
  case e.end {
    AtTime(ts) -> {
      let #(_, t) = timestamp.to_calendar(ts, local_offset)
      t.hours * 60 + t.minutes
    }
    AllDay(_) -> 1440
  }
}

/// The time-positioned portion of a day column.
/// All vertical positions are percentages of the container height so the
/// timeline fills whatever space the viewport offers without fixed pixel math.
fn view_timeline(
  events: List(Event),
  local_offset: duration.Duration,
  window: Window,
  is_today: Bool,
  color_for: fn(String) -> String,
  travel_cache: Dict(String, TravelInfo),
  travel_blocks: List(TravelBlock),
) -> Element(msg) {
  let total_min = window.end_min - window.start_min
  let total_f = int_to_float(total_min)

  let pct = fn(min: Int) -> String {
    float_pct(int_to_float(min) /. total_f *. 100.0)
  }

  let first_hour =
    window.start_min
    / 60
    + case window.start_min % 60 {
      0 -> 0
      _ -> 1
    }
  let last_hour = window.end_min / 60
  let hours =
    int.range(first_hour, last_hour, [], fn(acc, h) { [h, ..acc] })
    |> list.reverse

  let hour_lines =
    list.flat_map(hours, fn(h) {
      let top_min = h * 60 - window.start_min
      let show_half = h * 60 + 30 < window.end_min

      let hour_line =
        html.div(
          [
            attribute.class(
              "absolute left-0 right-0 border-t border-border overflow-visible",
            ),
            attribute.style("top", pct(top_min)),
          ],
          [
            html.span(
              [
                attribute.class(
                  "absolute text-text-faint leading-none select-none",
                ),
                attribute.styles([
                  #("top", "1px"),
                  #("left", "2px"),
                  #("font-size", "9px"),
                ]),
              ],
              [html.text(format_hour(h))],
            ),
          ],
        )

      let half_line = case show_half {
        False -> []
        True -> [
          html.div(
            [
              attribute.class(
                "absolute left-0 right-0 border-t border-dashed border-border/50",
              ),
              attribute.style("top", pct(top_min + 30)),
            ],
            [],
          ),
        ]
      }

      [hour_line, ..half_line]
    })

  let now_line = case is_today {
    False -> []
    True -> {
      let now = timestamp.system_time()
      let #(_, t) = timestamp.to_calendar(now, local_offset)
      let now_min = t.hours * 60 + t.minutes
      case now_min >= window.start_min && now_min <= window.end_min {
        False -> []
        True -> [
          html.div(
            [
              attribute.class(
                "absolute left-0 right-0 border-t border-accent-border/60 z-10",
              ),
              attribute.style("top", pct(now_min - window.start_min)),
            ],
            [],
          ),
        ]
      }
    }
  }

  // Assign overlap columns before rendering.
  let positioned = assign_columns(events, local_offset)

  let event_els =
    list.filter_map(positioned, fn(pe) {
      let e = pe.event
      case e.start, e.end {
        AtTime(s), AtTime(en) -> {
          let #(_, st) = timestamp.to_calendar(s, local_offset)
          let #(_, et) = timestamp.to_calendar(en, local_offset)
          let start_min = st.hours * 60 + st.minutes
          let end_min = et.hours * 60 + et.minutes
          let clamped_start = int.max(start_min, window.start_min)
          let clamped_end = int.min(end_min, window.end_min)
          let dur_min = int.max(clamped_end - clamped_start, 0)
          let top_pct = pct(clamped_start - window.start_min)
          let dur_frac = int_to_float(dur_min) /. total_f
          let h_frac = case dur_frac <. min_event_frac {
            True -> min_event_frac
            False -> dur_frac
          }
          let h_pct = float_pct(h_frac *. 100.0)
          let color = color_for(e.calendar_name)
          let time_str =
            format_time(s, local_offset) <> "–" <> format_time(en, local_offset)

          // Travel info line: "Boston • 12 min" if location resolves.
          let travel_el = case e.location {
            "" -> element.none()
            loc ->
              case dict.get(travel_cache, loc) {
                Error(_) -> element.none()
                Ok(info) ->
                  html.p(
                    [
                      attribute.class("leading-none text-text-faint truncate"),
                      attribute.style("font-size", "9px"),
                    ],
                    [html.text(info.city <> " • " <> info.duration_text)],
                  )
              }
          }

          // Horizontal layout: divide the post-gutter space into n equal slices,
          // no gap between adjacent events in the same overlap group.
          // left  = 2em + c/n * (100% - 2em)
          // right = (n-c-1)/n * (100% - 2em)
          let n = pe.col_count
          let c = pe.col
          let nf = int_to_float(n)
          let cf = int_to_float(c)
          let left_css = case n <= 1 {
            True -> "0"
            False -> "calc(" <> float_pct(cf /. nf *. 100.0) <> ")"
          }
          let right_css = case n <= 1 {
            True -> "0"
            False -> {
              let rf = int_to_float(n - c - 1)
              "calc(" <> float_pct(rf /. nf *. 100.0) <> ")"
            }
          }

          Ok(
            html.div(
              [
                attribute.class(
                  "absolute overflow-hidden rounded-lg border-l-4 px-1 hover:brightness-125 cursor-default",
                ),
                attribute.styles([
                  #("top", top_pct),
                  #("height", h_pct),
                  #("left", left_css),
                  #("right", right_css),
                  #("background-color", bgcolor(color)),
                  #("border-left-color", color),
                ]),
              ],
              [
                html.p(
                  [
                    attribute.class(
                      "text-xs leading-tight truncate text-text font-medium",
                    ),
                  ],
                  [html.text(e.summary)],
                ),
                html.p(
                  [
                    attribute.class("leading-none text-text-muted"),
                    attribute.style("font-size", "9px"),
                  ],
                  [html.text(time_str)],
                ),
                travel_el,
              ],
            ),
          )
        }
        _, _ -> Error(Nil)
      }
    })

  // Render travel blocks: semi-transparent strips showing drive time.
  let block_els =
    list.filter_map(travel_blocks, fn(b) {
      // Arrival-aligned: block ends at gap_end (right before next event starts).
      // Departure-aligned: block starts at gap_start (right after last event ends).
      let #(block_start_min, block_end_min) = case b.arrival_aligned {
        True -> {
          let #(_, end_t) = timestamp.to_calendar(b.gap_end, local_offset)
          let end_min = end_t.hours * 60 + end_t.minutes
          #(end_min - b.travel_secs / 60, end_min)
        }
        False -> {
          let #(_, start_t) = timestamp.to_calendar(b.gap_start, local_offset)
          let start_min = start_t.hours * 60 + start_t.minutes
          #(start_min, start_min + b.travel_secs / 60)
        }
      }
      let clamped_start = int.max(block_start_min, window.start_min)
      let clamped_end = int.min(block_end_min, window.end_min)
      case clamped_end > clamped_start {
        False -> Error(Nil)
        True -> {
          let top_pct = pct(clamped_start - window.start_min)
          let h_pct = pct(clamped_end - clamped_start)
          let label = case b.via_home {
            True -> "🏠 " <> b.travel_text
            False -> "🚗 " <> b.travel_text
          }
          let dwell_label = case b.dwell_secs > 60 {
            False -> ""
            True -> " • " <> secs_to_min_text(b.dwell_secs) <> " free"
          }
          Ok(
            html.div(
              [
                attribute.class(
                  "absolute left-0 right-0 overflow-hidden select-none pointer-events-none",
                ),
                attribute.styles([
                  #("top", top_pct),
                  #("height", h_pct),
                  #(
                    "background",
                    "repeating-linear-gradient(45deg, transparent, transparent 3px, rgba(128,128,128,0.08) 3px, rgba(128,128,128,0.08) 6px)",
                  ),
                  #("border-top", "1px solid rgba(128,128,128,0.25)"),
                ]),
              ],
              [
                html.span(
                  [
                    attribute.class("text-text-faint leading-none pl-1"),
                    attribute.style("font-size", "9px"),
                  ],
                  [html.text(label <> dwell_label)],
                ),
              ],
            ),
          )
        }
      }
    })

  html.div(
    [attribute.class("relative flex-1 min-h-0 overflow-hidden")],
    list.flatten([hour_lines, now_line, block_els, event_els]),
  )
}

// EVENT FILTERING -------------------------------------------------------------

/// True if this is an all-day event whose date range includes `date`.
/// iCal all-day end is exclusive, so [start, end) must contain date.
fn all_day_spans_date(e: Event, date: Date) -> Bool {
  case e.start, e.end {
    AllDay(s), AllDay(en) -> date_lte(s, date) && date_lt(date, en)
    _, _ -> False
  }
}

fn compare_event_start(a: Event, b: Event) -> order.Order {
  case a.start, b.start {
    AtTime(ta), AtTime(tb) -> timestamp.compare(ta, tb)
    AllDay(da), AllDay(db) -> calendar.naive_date_compare(da, db)
    AtTime(_), AllDay(_) -> order.Lt
    AllDay(_), AtTime(_) -> order.Gt
  }
}

// DATE HELPERS ----------------------------------------------------------------

fn date_lt(a: Date, b: Date) -> Bool {
  calendar.naive_date_compare(a, b) == order.Lt
}

fn date_lte(a: Date, b: Date) -> Bool {
  let c = calendar.naive_date_compare(a, b)
  c == order.Lt || c == order.Eq
}

fn date_gte(a: Date, b: Date) -> Bool {
  let c = calendar.naive_date_compare(a, b)
  c == order.Gt || c == order.Eq
}

fn next_n_dates(start: Date, n: Int) -> List(Date) {
  do_next_n_dates(start, n, [])
  |> list.reverse
}

fn do_next_n_dates(date: Date, n: Int, acc: List(Date)) -> List(Date) {
  case n <= 0 {
    True -> acc
    False -> do_next_n_dates(advance_date(date), n - 1, [date, ..acc])
  }
}

fn advance_date(date: Date) -> Date {
  let days_in = days_in_month(date.month, date.year)
  case date.day < days_in {
    True -> Date(..date, day: date.day + 1)
    False ->
      case date.month {
        calendar.December ->
          Date(year: date.year + 1, month: calendar.January, day: 1)
        _ -> Date(..date, month: next_month(date.month), day: 1)
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

fn next_month(m: calendar.Month) -> calendar.Month {
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

// FORMATTING ------------------------------------------------------------------

fn format_date(date: Date) -> String {
  let m =
    string.pad_start(string.inspect(calendar.month_to_int(date.month)), 2, "0")
  let d = string.pad_start(string.inspect(date.day), 2, "0")
  m <> "/" <> d
}

fn format_time(ts: Timestamp, local_offset: duration.Duration) -> String {
  let #(_, time) = timestamp.to_calendar(ts, local_offset)
  let h = time.hours
  let m = time.minutes
  let period = case h >= 12 {
    True -> "pm"
    False -> "am"
  }
  let h12 = case h % 12 {
    0 -> 12
    n -> n
  }
  string.inspect(h12)
  <> ":"
  <> string.pad_start(string.inspect(m), 2, "0")
  <> period
}

fn format_hour(h: Int) -> String {
  let period = case h >= 12 {
    True -> "p"
    False -> "a"
  }
  let h12 = case h % 12 {
    0 -> 12
    n -> n
  }
  string.inspect(h12) <> period
}

fn weekday_name(date: Date) -> String {
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
  let dow =
    { y + y / 4 - y / 100 + y / 400 + tm + date.day } |> int.remainder(7)
  case dow {
    Ok(0) -> "Sun"
    Ok(1) -> "Mon"
    Ok(2) -> "Tue"
    Ok(3) -> "Wed"
    Ok(4) -> "Thu"
    Ok(5) -> "Fri"
    Ok(6) -> "Sat"
    _ -> "???"
  }
}

// CSS HELPERS -----------------------------------------------------------------

fn int_to_float(n: Int) -> Float {
  int.to_float(n)
}

fn float_em(f: Float) -> String {
  float_css(f, "em")
}

fn float_pct(f: Float) -> String {
  float_css(f, "%")
}

fn float_css(f: Float, unit: String) -> String {
  let whole = float_round(f *. 10.0)
  let int_part = whole / 10
  let frac_part = int.absolute_value(whole % 10)
  string.inspect(int_part) <> "." <> string.inspect(frac_part) <> unit
}

fn bgcolor(color: String) -> String {
  "hsl(from " <> color <> " h s var(--event-bg-l))"
}

@external(erlang, "erlang", "round")
fn float_round(f: Float) -> Int
