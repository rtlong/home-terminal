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
/// Each located event generates one block per assigned person:
///   - DriveTo: home → event, arrival-aligned (strip ends at event_start)
///   - DriveFrom: event → home, departure-aligned (strip starts at event_end)
///
/// `bar` identifies which vertical bar this block belongs to.
pub type TravelBlock {
  /// Home → event. Strip is arrival-aligned: ends at `event_start`.
  DriveTo(
    event_start: Timestamp,
    travel_secs: Int,
    travel_text: String,
    color: String,
    bar: BarPos,
  )
  /// Event → home. Strip is departure-aligned: starts at `event_end`.
  DriveFrom(
    event_end: Timestamp,
    travel_secs: Int,
    travel_text: String,
    color: String,
    bar: BarPos,
  )
}

// TRAVEL BLOCK COMPUTATION ----------------------------------------------------

/// Compute travel blocks for a day's timed events.
///
/// For each located timed event, emits one DriveTo and one DriveFrom per
/// person assigned to that event's calendar.
/// `colors_for_event` returns one color per assigned person.
/// `bar_for_event` maps each event to its bar position.
pub fn compute_travel_blocks(
  events: List(Event),
  leg_cache: LegCache,
  home_key: String,
  leg_key: fn(String, String) -> String,
  colors_for_event: fn(Event) -> List(String),
  bar_for_event: fn(Event) -> BarPos,
) -> List(TravelBlock) {
  list.flat_map(events, fn(e) {
    case e.location, e.start, e.end {
      loc, AtTime(start), AtTime(end) if loc != "" -> {
        let colors = colors_for_event(e)
        let bar = bar_for_event(e)
        let to_secs = dict.get(leg_cache, leg_key(home_key, loc))
        let from_secs = dict.get(leg_cache, leg_key(loc, home_key))
        list.flat_map(colors, fn(color) {
          let to_block = case to_secs {
            Ok(secs) -> [
              DriveTo(
                event_start: start,
                travel_secs: secs,
                travel_text: secs_to_min_text(secs),
                color:,
                bar:,
              ),
            ]
            Error(_) -> []
          }
          let from_block = case from_secs {
            Ok(secs) -> [
              DriveFrom(
                event_end: end,
                travel_secs: secs,
                travel_text: secs_to_min_text(secs),
                color:,
                bar:,
              ),
            ]
            Error(_) -> []
          }
          list.append(to_block, from_block)
        })
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
/// `colors_for_event` returns all person colors for an event (one per assigned person).
/// `people` is the ordered list of people: [0]=left bar, [1]=right bar.
/// `bar_for_event` maps each event to its bar position.
pub fn view_seven_days(
  events: List(Event),
  color_for: fn(String) -> String,
  travel_cache: Dict(String, TravelInfo),
  leg_cache: LegCache,
  home_address: String,
  colors_for_event: fn(Event) -> List(String),
  people: List(String),
  bar_for_event: fn(Event) -> BarPos,
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
            colors_for_event,
            bar_for_event,
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
        people,
        bar_for_event,
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
  people: List(String),
  bar_for_event: fn(Event) -> BarPos,
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
        people,
        bar_for_event,
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

/// Which vertical bar an event or travel block belongs to.
/// Left = first person, Right = second person, Center = unassigned.
pub type BarPos {
  BarLeft
  BarRight
  BarCenter
}

/// A segment on a bar: a vertical span with a color and optional label.
type BarSegment {
  BarSegment(
    /// Minutes from window start.
    top_min: Int,
    /// Duration in minutes.
    dur_min: Int,
    color: String,
    /// Thickness: thick for events, thin for travel.
    thick: Bool,
    /// Label text shown next to this segment (summary + time, or travel text).
    label: String,
    /// Secondary label line (time range for events, blank for travel).
    label2: String,
  )
}

/// The time-positioned portion of a day column.
/// Renders three vertical timeline bars (left/center/right) as thin lines
/// that thicken for event and travel segments. Labels float into the center.
fn view_timeline(
  events: List(Event),
  local_offset: duration.Duration,
  window: Window,
  is_today: Bool,
  color_for: fn(String) -> String,
  travel_cache: Dict(String, TravelInfo),
  travel_blocks: List(TravelBlock),
  people: List(String),
  bar_for_event: fn(Event) -> BarPos,
) -> Element(msg) {
  let total_min = window.end_min - window.start_min
  let total_f = int_to_float(total_min)

  let pct = fn(min: Int) -> String {
    float_pct(int_to_float(min) /. total_f *. 100.0)
  }
  let fpct = fn(f: Float) -> String { float_pct(f /. total_f *. 100.0) }

  // ── Hour grid ──────────────────────────────────────────────────────────────
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
      let show_half = h * 60 + 30 < window.end_min
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

  // ── Now line ───────────────────────────────────────────────────────────────
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

  // ── Determine which bars are active ────────────────────────────────────────
  // Left bar = person[0], Right bar = person[1], Center = unassigned.
  // Only render bars that are actually needed (have events or blocks).
  let has_left = list.length(people) >= 1
  let has_right = list.length(people) >= 2

  // ── Collect segments per bar ───────────────────────────────────────────────
  // Events → segments
  let event_segs =
    list.filter_map(events, fn(e) {
      case e.start, e.end {
        AtTime(s), AtTime(en) -> {
          let #(_, st) = timestamp.to_calendar(s, local_offset)
          let #(_, et) = timestamp.to_calendar(en, local_offset)
          let start_min = st.hours * 60 + st.minutes
          let end_min = et.hours * 60 + et.minutes
          let top_min = int.max(start_min, window.start_min) - window.start_min
          let bot_min = int.min(end_min, window.end_min) - window.start_min
          let dur_min = int.max(bot_min - top_min, 1)
          let color = color_for(e.calendar_name)
          let time_str =
            format_time(s, local_offset) <> "–" <> format_time(en, local_offset)
          let loc_suffix = case e.location {
            "" -> ""
            loc ->
              case dict.get(travel_cache, loc) {
                Ok(info) -> " · " <> info.city
                Error(_) -> ""
              }
          }
          let bar = bar_for_event(e)
          Ok(#(
            bar,
            BarSegment(
              top_min:,
              dur_min:,
              color:,
              thick: True,
              label: e.summary <> loc_suffix,
              label2: time_str,
            ),
          ))
        }
        _, _ -> Error(Nil)
      }
    })

  // Travel blocks → segments (thin)
  let travel_segs =
    list.filter_map(travel_blocks, fn(b) {
      case b {
        DriveTo(event_start:, travel_secs:, travel_text:, color:, bar:) -> {
          let #(_, t) = timestamp.to_calendar(event_start, local_offset)
          let anchor_min = t.hours * 60 + t.minutes
          let travel_min = { travel_secs + 30 } / 60
          let raw_start = anchor_min - travel_min
          let top_min = int.max(raw_start, window.start_min) - window.start_min
          let bot_min = int.min(anchor_min, window.end_min) - window.start_min
          let dur_min = int.max(bot_min - top_min, 0)
          case dur_min > 0 {
            False -> Error(Nil)
            True ->
              Ok(#(
                bar,
                BarSegment(
                  top_min:,
                  dur_min:,
                  color:,
                  thick: False,
                  label: travel_text,
                  label2: "",
                ),
              ))
          }
        }
        DriveFrom(event_end:, travel_secs:, travel_text:, color:, bar:) -> {
          let #(_, t) = timestamp.to_calendar(event_end, local_offset)
          let anchor_min = t.hours * 60 + t.minutes
          let travel_min = { travel_secs + 30 } / 60
          let raw_end = anchor_min + travel_min
          let top_min = int.max(anchor_min, window.start_min) - window.start_min
          let bot_min = int.min(raw_end, window.end_min) - window.start_min
          let dur_min = int.max(bot_min - top_min, 0)
          case dur_min > 0 {
            False -> Error(Nil)
            True ->
              Ok(#(
                bar,
                BarSegment(
                  top_min:,
                  dur_min:,
                  color:,
                  thick: False,
                  label: travel_text <> " home",
                  label2: "",
                ),
              ))
          }
        }
      }
    })

  let all_segs = list.append(event_segs, travel_segs)

  let segs_for = fn(bar: BarPos) -> List(BarSegment) {
    list.filter_map(all_segs, fn(pair) {
      let #(b, seg) = pair
      case b == bar {
        True -> Ok(seg)
        False -> Error(Nil)
      }
    })
  }

  let left_segs = segs_for(BarLeft)
  let right_segs = segs_for(BarRight)
  let center_segs = segs_for(BarCenter)

  // ── Bar width constants ────────────────────────────────────────────────────
  // Bar is 6px thin, 10px thick for events, 7px for travel. Labels float in.
  let bar_w_thin = "6px"
  let bar_w_thick = "10px"
  let bar_w_travel = "7px"

  // ── Render a bar + its labels ──────────────────────────────────────────────
  // `side` is "left" or "right" or "center" for the bar position.
  // `label_side` is "left" or "right" for the text-align / anchor of labels.
  let render_bar = fn(
    segs: List(BarSegment),
    bar_left: String,
    bar_right: String,
    label_left: String,
    label_right: String,
    label_align: String,
  ) -> List(Element(msg)) {
    // Thin baseline bar spanning full height
    let base_bar =
      html.div(
        [
          attribute.class("absolute top-0 bottom-0 pointer-events-none"),
          attribute.styles([
            #("left", bar_left),
            #("right", bar_right),
            #("width", bar_w_thin),
            #("background-color", "rgba(128,128,128,0.15)"),
          ]),
        ],
        [],
      )

    // Segment elements (thick/thin strips on the bar)
    let seg_els =
      list.map(segs, fn(seg) {
        let w = case seg.thick {
          True -> bar_w_thick
          False -> bar_w_travel
        }
        let opacity = case seg.thick {
          True -> "0.85"
          False -> "0.5"
        }
        html.div(
          [
            attribute.class("absolute pointer-events-none"),
            attribute.styles([
              #("left", bar_left),
              #("right", bar_right),
              #("top", pct(seg.top_min)),
              #("height", fpct(int_to_float(seg.dur_min))),
              #("width", w),
              #("background-color", seg.color),
              #("opacity", opacity),
            ]),
          ],
          [],
        )
      })

    // Label deconfliction: sort by top_min, nudge downward to avoid overlaps.
    // Minimum gap = 10 minutes in window-space (≈ one label height at typical zoom).
    let min_gap_min = 10
    let sorted_segs =
      list.sort(segs, fn(a, b) { int.compare(a.top_min, b.top_min) })

    let nudged_labels =
      list.fold(sorted_segs, #([], -999), fn(acc, seg) {
        let #(placed, last_top) = acc
        let ideal = seg.top_min + seg.dur_min / 2
        let actual = int.max(ideal, last_top + min_gap_min)
        #(list.append(placed, [#(actual, seg)]), actual)
      })
      |> fn(p) { p.0 }

    let label_els =
      list.flat_map(nudged_labels, fn(pair) {
        let #(label_top, seg) = pair
        case seg.label {
          "" -> []
          _ -> [
            html.div(
              [
                attribute.class("absolute select-none pointer-events-none"),
                attribute.styles([
                  #("top", pct(label_top)),
                  #("left", label_left),
                  #("right", label_right),
                  #("text-align", label_align),
                ]),
              ],
              [
                html.span(
                  [
                    attribute.class("leading-none font-medium"),
                    attribute.style("font-size", "9px"),
                    attribute.style(
                      "color",
                      "hsl(from " <> seg.color <> " h s 35%)",
                    ),
                  ],
                  [html.text(seg.label)],
                ),
                case seg.label2 {
                  "" -> element.none()
                  t ->
                    html.span(
                      [
                        attribute.class("leading-none block"),
                        attribute.style("font-size", "9px"),
                        attribute.style("color", "rgba(128,128,128,0.7)"),
                      ],
                      [html.text(t)],
                    )
                },
              ],
            ),
          ]
        }
      })

    [base_bar, ..list.append(seg_els, label_els)]
  }

  // ── Render the three bars ──────────────────────────────────────────────────
  // Left bar: flush left, labels go right into left half of center
  // Right bar: flush right, labels go left into right half of center
  // Center bar: centered, labels centered below segment midpoint
  let left_els = case has_left {
    False -> []
    True -> render_bar(left_segs, "0", "auto", bar_w_thick, "50%", "left")
  }
  let right_els = case has_right {
    False -> []
    True -> render_bar(right_segs, "auto", "0", "50%", bar_w_thick, "right")
  }
  let center_els = case left_els == [] && right_els == [] {
    // Only show center bar when there are no person bars, or when center has segs
    True ->
      render_bar(center_segs, "calc(50% - 3px)", "auto", "0", "0", "center")
    False ->
      case center_segs {
        [] -> []
        _ ->
          render_bar(center_segs, "calc(50% - 3px)", "auto", "0", "0", "center")
      }
  }

  html.div(
    [attribute.class("relative flex-1 min-h-0 overflow-hidden")],
    list.flatten([hour_lines, now_line, left_els, right_els, center_els]),
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
