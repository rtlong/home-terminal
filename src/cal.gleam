// IMPORTS ---------------------------------------------------------------------

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/order
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

/// A travel block to render on the timeline.
///
/// Each located event independently generates:
///   - A DriveTo block: home → event, arrival-aligned (strip ends at event start)
///   - A DriveFrom block: event → home, departure-aligned (strip starts at event end)
///
/// Strips may overlap when two events are close together — that is visually
/// correct (you'd be driving to the next event before you've even left the last).
/// Each block carries the person color derived from the event's calendar assignment.
pub type TravelBlock {
  /// Home → event. Strip is arrival-aligned: ends at `event_start`.
  DriveTo(
    event_start: Timestamp,
    travel_secs: Int,
    travel_text: String,
    color: String,
  )
  /// Event → home. Strip is departure-aligned: starts at `event_end`.
  DriveFrom(
    event_end: Timestamp,
    travel_secs: Int,
    travel_text: String,
    color: String,
  )
}

// TRAVEL BLOCK COMPUTATION ----------------------------------------------------

/// Compute travel blocks for a day's timed events.
///
/// For each located timed event, emits a DriveTo (home→loc) and a DriveFrom
/// (loc→home) block if the respective leg is in the cache.
/// `color_for_event` maps an event to its person's CSS color string.
pub fn compute_travel_blocks(
  events: List(Event),
  leg_cache: LegCache,
  home_key: String,
  leg_key: fn(String, String) -> String,
  color_for_event: fn(Event) -> String,
) -> List(TravelBlock) {
  list.flat_map(events, fn(e) {
    case e.location, e.start, e.end {
      loc, AtTime(start), AtTime(end) if loc != "" -> {
        let color = color_for_event(e)
        let to_block = case dict.get(leg_cache, leg_key(home_key, loc)) {
          Ok(secs) -> [
            DriveTo(
              event_start: start,
              travel_secs: secs,
              travel_text: secs_to_min_text(secs),
              color:,
            ),
          ]
          Error(_) -> []
        }
        let from_block = case dict.get(leg_cache, leg_key(loc, home_key)) {
          Ok(secs) -> [
            DriveFrom(
              event_end: end,
              travel_secs: secs,
              travel_text: secs_to_min_text(secs),
              color:,
            ),
          ]
          Error(_) -> []
        }
        list.append(to_block, from_block)
      }
      _, _, _ -> []
    }
  })
}

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
/// `color_for` maps calendar_name → CSS color for event blocks.
/// `color_for_event` maps an Event → person CSS color for travel strips.
pub fn view_seven_days(
  events: List(Event),
  color_for: fn(String) -> String,
  travel_cache: Dict(String, TravelInfo),
  leg_cache: LegCache,
  home_address: String,
  color_for_event: fn(Event) -> String,
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

  // Compute travel blocks for every day up-front so we can include their
  // extents in the shared window calculation.
  let day_timed_and_blocks =
    list.map(day_timed_lists, fn(day_timed) {
      let day_blocks = case home_address {
        "" -> []
        addr ->
          compute_travel_blocks(
            day_timed,
            leg_cache,
            addr,
            travel.leg_cache_key,
            color_for_event,
          )
      }
      #(day_timed, day_blocks)
    })

  let all_day_blocks = list.flat_map(day_timed_and_blocks, fn(pair) { pair.1 })

  // Shared time window across all days, extended to cover travel block extents.
  let window = compute_window(day_timed_lists, all_day_blocks, local_offset)

  // Compute a stable row assignment for all-day events visible in this window.
  // This ensures a multi-day event appears on the same row across all columns.
  let #(all_day_row_map, all_day_row_count) = compute_all_day_rows(events, days)

  html.div(
    [
      attribute.class(
        "flex-1 min-h-0 grid grid-cols-7 gap-px p-2 overflow-hidden bg-surface",
      ),
    ],
    list.map(list.zip(days, day_timed_and_blocks), fn(pair) {
      let #(day, #(day_timed, day_blocks)) = pair
      let day_all_day =
        list.filter(events, fn(e) { all_day_spans_date(e, day) })
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
  all_blocks: List(TravelBlock),
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

      // Extend window to cover travel block extents.
      // DriveTo: strip ends at event_start (already in start_mins), but
      //   begins travel_secs earlier — can push window start earlier.
      // DriveFrom: strip begins at event_end (already in end_mins), but
      //   extends travel_secs later — can push window end later.
      let block_start_mins =
        list.filter_map(all_blocks, fn(b) {
          case b {
            DriveTo(event_start:, travel_secs:, ..) -> {
              let #(_, t) = timestamp.to_calendar(event_start, local_offset)
              let anchor = t.hours * 60 + t.minutes
              Ok(anchor - { travel_secs + 30 } / 60)
            }
            DriveFrom(..) -> Error(Nil)
          }
        })
      let block_end_mins =
        list.filter_map(all_blocks, fn(b) {
          case b {
            DriveFrom(event_end:, travel_secs:, ..) -> {
              let #(_, t) = timestamp.to_calendar(event_end, local_offset)
              let anchor = t.hours * 60 + t.minutes
              Ok(anchor + { travel_secs + 30 } / 60)
            }
            DriveTo(..) -> Error(Nil)
          }
        })

      let earliest =
        list.fold(
          list.append(start_mins, block_start_mins),
          default_window_start_min,
          int.min,
        )
      let latest =
        list.fold(
          list.append(end_mins, block_end_mins),
          default_window_end_min,
          int.max,
        )

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

  // Render travel blocks.
  // DriveTo: arrival-aligned strip ending at event_start (home → event).
  // DriveFrom: departure-aligned strip starting at event_end (event → home).
  let block_els =
    list.filter_map(travel_blocks, fn(b) {
      case b {
        DriveTo(event_start:, travel_secs:, travel_text:, color:) -> {
          let #(_, t) = timestamp.to_calendar(event_start, local_offset)
          let anchor_min = t.hours * 60 + t.minutes
          let travel_min = { travel_secs + 30 } / 60
          let block_start = anchor_min - travel_min
          let clamped_start = int.max(block_start, window.start_min)
          let clamped_end = int.min(anchor_min, window.end_min)
          case clamped_end > clamped_start {
            False -> Error(Nil)
            True ->
              Ok(travel_strip(
                pct(clamped_start - window.start_min),
                pct(clamped_end - clamped_start),
                travel_text,
                color,
              ))
          }
        }

        DriveFrom(event_end:, travel_secs:, travel_text:, color:) -> {
          let #(_, t) = timestamp.to_calendar(event_end, local_offset)
          let anchor_min = t.hours * 60 + t.minutes
          let travel_min = { travel_secs + 30 } / 60
          let block_end = anchor_min + travel_min
          let clamped_start = int.max(anchor_min, window.start_min)
          let clamped_end = int.min(block_end, window.end_min)
          case clamped_end > clamped_start {
            False -> Error(Nil)
            True ->
              Ok(travel_strip(
                pct(clamped_start - window.start_min),
                pct(clamped_end - clamped_start),
                travel_text <> " home",
                color,
              ))
          }
        }
      }
    })

  html.div(
    [attribute.class("relative flex-1 min-h-0 overflow-hidden")],
    list.flatten([hour_lines, now_line, block_els, event_els]),
  )
}

/// Render a single travel-time strip on the timeline.
/// `top` and `height` are CSS percentage strings (already computed).
/// `label` is the text to show. `color` is the person's CSS color.
/// The strip uses a semi-transparent tint of the person's color.
fn travel_strip(
  top: String,
  height: String,
  label: String,
  color: String,
) -> Element(msg) {
  html.div(
    [
      attribute.class(
        "absolute left-0 right-0 overflow-hidden select-none pointer-events-none flex items-end pb-px",
      ),
      attribute.styles([
        #("top", top),
        #("height", height),
        #("background-color", "hsl(from " <> color <> " h s var(--event-bg-l))"),
        #("border-top", "1px solid hsl(from " <> color <> " h s 60% / 0.4)"),
      ]),
    ],
    [
      html.span(
        [
          attribute.class("leading-none pl-1 truncate"),
          attribute.style("font-size", "9px"),
          attribute.style("color", "hsl(from " <> color <> " h s 35%)"),
        ],
        [html.text(label)],
      ),
    ],
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
