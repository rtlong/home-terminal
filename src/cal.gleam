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
    /// True when TRANSP:TRANSPARENT — the event does not mark the person busy.
    free: Bool,
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

/// Which horizontal sub-row a bar or travel block belongs to.
pub type BarPos {
  BarLeft
  BarRight
  BarCenter
}

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
/// assigned (bar, color) pair — so both-person events get travel on both bars.
/// `bars_for_event` returns one #(BarPos, color) per assigned person.
pub fn compute_travel_blocks(
  events: List(Event),
  leg_cache: LegCache,
  home_key: String,
  leg_key: fn(String, String) -> String,
  bars_for_event: fn(Event) -> List(#(BarPos, String)),
) -> List(TravelBlock) {
  list.flat_map(events, fn(e) {
    case e.location, e.start, e.end {
      loc, AtTime(start), AtTime(end) if loc != "" -> {
        let pairs = bars_for_event(e)
        let to_secs = dict.get(leg_cache, leg_key(home_key, loc))
        let from_secs = dict.get(leg_cache, leg_key(loc, home_key))
        list.flat_map(pairs, fn(pair) {
          let #(bar, color) = pair
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

/// Format seconds as just the minute count (e.g. "24"), rounding to nearest minute.
pub fn secs_to_min_text(secs: Int) -> String {
  let mins = { secs + 30 } / 60
  int.to_string(mins)
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

// GANTT VIEW ------------------------------------------------------------------

/// Horizontal gantt-style 7-day view.
/// Each day is a row; time runs left→right across the full width.
/// Events are horizontal bars in one of three sub-rows per day:
///   top    = person 0 (BarLeft)
///   middle = both / unassigned (BarCenter)
///   bottom = person 1 (BarRight)
/// Labels flow to the right of each bar — no vertical deconfliction needed
/// since events rarely overlap for the same person.
pub fn view_gantt(
  events: List(Event),
  color_for: fn(String) -> String,
  _travel_cache: Dict(String, TravelInfo),
  leg_cache: LegCache,
  home_address: String,
  bars_for_event: fn(Event) -> List(#(BarPos, String)),
  people: List(String),
) -> Element(msg) {
  let now = timestamp.system_time()
  let local_offset = calendar.local_offset()
  let today_date = timestamp.to_calendar(now, local_offset).0
  let days = next_n_dates(today_date, 7)

  // Per-day timed event lists for window computation.
  let day_timed_lists =
    list.map(days, fn(day) {
      list.filter(events, fn(e) {
        case e.start, e.end {
          AtTime(s), AtTime(en) -> {
            let start_date = timestamp.to_calendar(s, local_offset).0
            let end_date = timestamp.to_calendar(en, local_offset).0
            date_lte(start_date, day) && date_gte(end_date, day)
          }
          _, _ -> False
        }
      })
    })

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
            bars_for_event,
          )
      }
      #(day_timed, day_blocks)
    })

  let all_day_blocks = list.flat_map(day_timed_and_blocks, fn(p) { p.1 })
  let window = compute_window(day_timed_lists, all_day_blocks, local_offset)
  let total_min = window.end_min - window.start_min
  let total_f = int_to_float(total_min)

  // Percentage helpers relative to the time window.
  let xpct = fn(min: Int) -> String {
    float_pct(int_to_float(min) /. total_f *. 100.0)
  }
  let _xfpct = fn(f: Float) -> String { float_pct(f /. total_f *. 100.0) }

  // Person names for sub-row labels.
  let person0 = case people {
    [p, ..] -> p
    [] -> ""
  }
  let person1 = case people {
    [_, p, ..] -> p
    _ -> ""
  }

  // Now-indicator: minutes from window start (for horizontal line).
  let now_min = {
    let #(_, t) = timestamp.to_calendar(now, local_offset)
    t.hours * 60 + t.minutes
  }

  // Hour gridlines + quarter-hour sub-lines — shared across all rows.
  let first_hour = case window.start_min % 60 {
    0 -> window.start_min / 60
    _ -> window.start_min / 60 + 1
  }
  let last_hour = window.end_min / 60
  // Gridline colors use explicit black-with-opacity so they're visible on both
  // light and dark backgrounds regardless of the --color-border theme value.
  let qline_color = "oklch(0 0 0 / 8%)"
  let hline_color = "oklch(0 0 0 / 35%)"

  // Quarter-hour lines (15, 30, 45 min offsets within each hour) — faint.
  let quarter_lines =
    list.flat_map(int_range(first_hour, last_hour - 1), fn(h) {
      list.filter_map([15, 30, 45], fn(q) {
        let min = h * 60 + q - window.start_min
        case min > 0 && min < total_min {
          False -> Error(Nil)
          True ->
            Ok(
              html.div(
                [
                  attribute.class("absolute top-0 bottom-0 pointer-events-none"),
                  attribute.style("left", xpct(min)),
                  attribute.style("border-left", "1px solid " <> qline_color),
                ],
                [],
              ),
            )
        }
      })
    })
  // Hour lines — clearly stronger than quarter lines.
  let hour_lines =
    list.filter_map(int_range(first_hour, last_hour), fn(h) {
      let min = h * 60 - window.start_min
      case min > 0 && min < total_min {
        False -> Error(Nil)
        True ->
          Ok(
            html.div(
              [
                attribute.class("absolute top-0 bottom-0 pointer-events-none"),
                attribute.style("left", xpct(min)),
                attribute.style("border-left", "2px solid " <> hline_color),
              ],
              [],
            ),
          )
      }
    })
  let all_grid_lines = list.append(quarter_lines, hour_lines)

  // A type alias for gantt bar tuples: (bar, left_min, width_min, color, thick, label, label2)
  // We use a record-less 7-tuple throughout.

  // Height in px of the hour-tick header strip at the top of each day's time grid.
  // Event bars live below this strip, so ticks never overlap bars.
  let tick_header_px = 10

  // Render one day row.
  let view_gantt_day = fn(
    day: Date,
    is_today: Bool,
    day_timed: List(Event),
    day_blocks: List(TravelBlock),
    all_day_events: List(Event),
  ) -> Element(msg) {
    // Build horizontal segments for timed events.
    // Cross-midnight events are treated differently per day:
    //   start day  → bar from start → window end, label shows start time
    //   middle days → promoted to all-day chip (added to extra_allday)
    //   end day    → bar from window start → end time, label shows "ends X:XXpm"
    let extra_allday_ref = []
    let #(event_bars, extra_allday) =
      list.fold(day_timed, #([], extra_allday_ref), fn(acc, e) {
        let #(bars_acc, allday_acc) = acc
        case e.start, e.end {
          AtTime(s), AtTime(en) -> {
            let #(start_date, st) = timestamp.to_calendar(s, local_offset)
            let #(end_date, et) = timestamp.to_calendar(en, local_offset)
            let is_start_day =
              calendar.naive_date_compare(start_date, day) == order.Eq
            let is_end_day =
              calendar.naive_date_compare(end_date, day) == order.Eq
            let is_cross_midnight = !is_end_day || !is_start_day

            case is_start_day, is_end_day {
              // Middle day: event spans entirely through this day — show as all-day chip.
              False, False -> #(bars_acc, [e, ..allday_acc])

              // Start day: event starts today and crosses midnight.
              True, False -> {
                let left_min =
                  int.max(st.hours * 60 + st.minutes, window.start_min)
                  - window.start_min
                let width_min = total_min - left_min
                let new_bars =
                  list.map(bars_for_event(e), fn(pair) {
                    let #(bar, color) = pair
                    #(
                      bar,
                      left_min,
                      width_min,
                      color,
                      True,
                      e.free,
                      e.summary,
                      format_time(s, local_offset) <> " →",
                    )
                  })
                #(list.append(bars_acc, new_bars), allday_acc)
              }

              // End day: event started on a previous day and ends today.
              False, True -> {
                let left_min = 0
                let right_min =
                  int.min(et.hours * 60 + et.minutes, window.end_min)
                  - window.start_min
                let width_min = int.max(right_min, 1)
                let new_bars =
                  list.map(bars_for_event(e), fn(pair) {
                    let #(bar, color) = pair
                    #(
                      bar,
                      left_min,
                      width_min,
                      color,
                      True,
                      e.free,
                      e.summary,
                      "ends " <> format_time(en, local_offset),
                    )
                  })
                #(list.append(bars_acc, new_bars), allday_acc)
              }

              // Normal same-day event.
              True, True -> {
                let _ = is_cross_midnight
                let left_min =
                  int.max(st.hours * 60 + st.minutes, window.start_min)
                  - window.start_min
                let right_min =
                  int.min(et.hours * 60 + et.minutes, window.end_min)
                  - window.start_min
                let width_min = int.max(right_min - left_min, 1)
                let time_str =
                  format_time(s, local_offset)
                  <> "–"
                  <> format_time(en, local_offset)
                let new_bars =
                  list.map(bars_for_event(e), fn(pair) {
                    let #(bar, color) = pair
                    #(
                      bar,
                      left_min,
                      width_min,
                      color,
                      True,
                      e.free,
                      e.summary,
                      time_str,
                    )
                  })
                #(list.append(bars_acc, new_bars), allday_acc)
              }
            }
          }
          _, _ -> acc
        }
      })
    // Merge cross-midnight span events into the all-day chips list.
    let all_day_events = list.append(all_day_events, extra_allday)

    // Travel block segments.
    let travel_bars =
      list.filter_map(day_blocks, fn(b) {
        case b {
          DriveTo(event_start:, travel_secs:, travel_text:, color:, bar:) -> {
            let #(_, t) = timestamp.to_calendar(event_start, local_offset)
            let anchor = t.hours * 60 + t.minutes
            let travel_min = { travel_secs + 30 } / 60
            let raw_start = anchor - travel_min
            let left_min =
              int.max(raw_start, window.start_min) - window.start_min
            let right_min = int.min(anchor, window.end_min) - window.start_min
            let width_min = int.max(right_min - left_min, 0)
            case width_min > 0 {
              False -> Error(Nil)
              True ->
                Ok(#(
                  bar,
                  left_min,
                  width_min,
                  color,
                  False,
                  False,
                  travel_text,
                  "",
                ))
            }
          }
          DriveFrom(event_end:, travel_secs:, travel_text:, color:, bar:) -> {
            let #(_, t) = timestamp.to_calendar(event_end, local_offset)
            let anchor = t.hours * 60 + t.minutes
            let travel_min = { travel_secs + 30 } / 60
            let raw_end = anchor + travel_min
            let left_min = int.max(anchor, window.start_min) - window.start_min
            let right_min = int.min(raw_end, window.end_min) - window.start_min
            let width_min = int.max(right_min - left_min, 0)
            case width_min > 0 {
              False -> Error(Nil)
              True ->
                Ok(#(
                  bar,
                  left_min,
                  width_min,
                  color,
                  False,
                  False,
                  travel_text,
                  "",
                ))
            }
          }
        }
      })

    let all_bars = list.append(event_bars, travel_bars)

    // --- Lane assignment ---
    // Bar tuple: #(BarPos, Int, Int, String, Bool, Bool, String, String)
    //             pos  left width color thick free  label label2
    //
    // Two-phase: event bars (thick=True) get lanes greedily; travel bars
    // (thick=False) are pinned to the same lane as their adjacent event bar.
    //
    // Key invariant: when checking whether a lane is free for a candidate event
    // bar, we use the effective span = the event's own range PLUS any adjacent
    // travel bars (DriveTo to its left, DriveFrom to its right).  This prevents
    // a free/long event from being placed in the same lane as a
    // busy-event+travel group whose travel strips time-overlap the free event
    // even when the busy event itself ends before the free event does.
    let assign_lanes = fn(
      bars: List(#(BarPos, Int, Int, String, Bool, Bool, String, String)),
    ) -> List(#(Int, #(BarPos, Int, Int, String, Bool, Bool, String, String))) {
      let is_thick = fn(
        b: #(BarPos, Int, Int, String, Bool, Bool, String, String),
      ) {
        b.4
      }
      let event_bars_only = list.filter(bars, is_thick)
      let travel_bars_only = list.filter(bars, fn(b) { !is_thick(b) })

      // Full span of an event bar including its flanking travel strips.
      let effective_left = fn(
        ev: #(BarPos, Int, Int, String, Bool, Bool, String, String),
      ) -> Int {
        let ev_left = ev.1
        list.fold(travel_bars_only, ev_left, fn(acc, tb) {
          case tb.1 + tb.2 == ev_left {
            True -> int.min(acc, tb.1)
            False -> acc
          }
        })
      }
      let effective_right = fn(
        ev: #(BarPos, Int, Int, String, Bool, Bool, String, String),
      ) -> Int {
        let ev_right = ev.1 + ev.2
        list.fold(travel_bars_only, ev_right, fn(acc, tb) {
          case tb.1 == ev_right {
            True -> int.max(acc, tb.1 + tb.2)
            False -> acc
          }
        })
      }

      // Phase 1: greedy lane assignment for event bars, sorted by effective start.
      let sorted_events =
        list.sort(event_bars_only, fn(a, b) {
          int.compare(effective_left(a), effective_left(b))
        })
      let init: #(
        List(#(Int, #(BarPos, Int, Int, String, Bool, Bool, String, String))),
        List(Int),
      ) = #([], [])
      let #(event_assigned, _lane_ends) =
        list.fold(sorted_events, init, fn(acc, bar) {
          let #(assignments, lane_ends) = acc
          let span_left = effective_left(bar)
          let span_right = effective_right(bar)
          let found =
            list.index_map(lane_ends, fn(end_min, idx) { #(idx, end_min) })
            |> list.find(fn(p: #(Int, Int)) { p.1 <= span_left })
          case found {
            Ok(#(lane_idx, _)) -> {
              let new_ends =
                list.index_map(lane_ends, fn(e, i) {
                  case i == lane_idx {
                    True -> span_right
                    False -> e
                  }
                })
              #(list.append(assignments, [#(lane_idx, bar)]), new_ends)
            }
            Error(Nil) -> {
              let lane_idx = list.length(lane_ends)
              #(
                list.append(assignments, [#(lane_idx, bar)]),
                list.append(lane_ends, [span_right]),
              )
            }
          }
        })

      // Phase 2: pin each travel bar to its adjacent event bar's lane.
      let travel_assigned =
        list.map(travel_bars_only, fn(bar) {
          let travel_left = bar.1
          let travel_right = bar.1 + bar.2
          let lane =
            list.find(event_assigned, fn(p) {
              let ev_left = p.1.1
              let ev_right = ev_left + p.1.2
              travel_right == ev_left || travel_left == ev_right
            })
            |> result.map(
              fn(
                p: #(
                  Int,
                  #(BarPos, Int, Int, String, Bool, Bool, String, String),
                ),
              ) {
                p.0
              },
            )
            |> result.unwrap(list.length(event_assigned))
          #(lane, bar)
        })

      list.append(event_assigned, travel_assigned)
    }

    // Fixed pixel height for every bar lane.
    let bar_px = 20

    // Hour tick labels in a dedicated thin header strip at the top of time_grid.
    let hour_tick_strip =
      html.div(
        [
          attribute.class("relative shrink-0 select-none pointer-events-none"),
          attribute.style("height", int.to_string(tick_header_px) <> "px"),
        ],
        list.filter_map(int_range(first_hour, last_hour), fn(h) {
          let min = h * 60 - window.start_min
          case min >= 0 && min <= total_min {
            False -> Error(Nil)
            True ->
              Ok(
                html.span(
                  [
                    attribute.class(
                      "absolute top-0 text-text-muted leading-none z-30",
                    ),
                    attribute.style("left", xpct(min)),
                    attribute.style("font-size", "8px"),
                    attribute.style("line-height", "1"),
                    attribute.style("padding", "1px 1px 0"),
                    attribute.style("transform", case min {
                      0 -> "translateX(1px)"
                      _ if min >= total_min -> "translateX(calc(-100% - 1px))"
                      _ -> "translateX(-50%)"
                    }),
                  ],
                  [html.text(format_hour(h))],
                ),
              )
          }
        }),
      )

    // CSS grid column template: one column per minute in the window.
    let grid_cols = "repeat(" <> int.to_string(total_min) <> ", minmax(0, 1fr))"

    // Render one sub-row using CSS grid.
    // Each bar is placed via grid-column (1-indexed, end exclusive) and
    // grid-row (1-indexed lane).  No absolute positioning, no % math.
    let view_sub_row = fn(pos: BarPos) -> Element(msg) {
      let bars =
        list.filter(
          all_bars,
          fn(t: #(BarPos, Int, Int, String, Bool, Bool, String, String)) {
            t.0 == pos
          },
        )
      let assigned = assign_lanes(bars)
      let lane_count =
        list.fold(assigned, 0, fn(mx, p) { int.max(mx, p.0 + 1) })
      let grid_height_px = int.max(lane_count, 1) * bar_px

      let bar_els =
        list.map(assigned, fn(pair) {
          let #(
            lane,
            #(_, left_min, width_min, color, thick, is_free, label, label2),
          ) = pair
          let clamped_width = int.min(width_min, total_min - left_min)
          let right_min = left_min + clamped_width
          // CSS grid columns are 1-indexed; end line is exclusive.
          let col_start = int.to_string(left_min + 1)
          let col_end = int.to_string(right_min + 1)
          let row = int.to_string(lane + 1)
          // Vertical padding inside the lane.
          let pad_px = case thick {
            True -> 2
            False -> 5
          }
          let opacity = case thick {
            True -> "0.85"
            False -> "0.55"
          }
          // Suppress labels on very narrow travel bars.
          let too_narrow = !thick && clamped_width < 20
          let show_time = thick && clamped_width >= 35
          let label_content = case label, too_narrow {
            _, True -> []
            "", False -> []
            _, False -> [
              html.span(
                [
                  attribute.class(
                    "shrink-0 max-w-full truncate font-medium leading-none",
                  ),
                  attribute.style("font-size", "9px"),
                ],
                [html.text(label)],
              ),
              case label2, show_time {
                _, False -> element.none()
                "", _ -> element.none()
                t, True ->
                  html.span(
                    [
                      attribute.class(
                        "shrink truncate min-w-0 leading-none opacity-70",
                      ),
                      attribute.style("font-size", "8px"),
                    ],
                    [html.text(" " <> t)],
                  )
              },
            ]
          }
          // Visual style: free → outlined; cross-midnight → gradient fade.
          let is_start_day_xm =
            !is_free && left_min > 0 && right_min >= total_min
          let is_end_day_xm =
            !is_free
            && left_min == 0
            && right_min < total_min
            && width_min == clamped_width
          let extra_style = case is_free, is_start_day_xm, is_end_day_xm {
            True, _, _ -> [
              attribute.style("background-color", "transparent"),
              attribute.style("border", "1.5px solid " <> color),
              attribute.style("opacity", "0.7"),
              attribute.style("color", color),
            ]
            False, True, _ -> [
              attribute.style(
                "mask-image",
                "linear-gradient(to right, black 60%, transparent 100%)",
              ),
            ]
            False, False, True -> [
              attribute.style(
                "mask-image",
                "linear-gradient(to left, black 60%, transparent 100%)",
              ),
            ]
            False, False, False -> []
          }
          html.div(
            list.flatten([
              [
                attribute.class(
                  "overflow-hidden flex items-center gap-0.5 px-1 pointer-events-none select-none rounded-sm",
                ),
                attribute.style("grid-column", col_start <> " / " <> col_end),
                attribute.style("grid-row", row),
                attribute.style("margin-top", int.to_string(pad_px) <> "px"),
                attribute.style("margin-bottom", int.to_string(pad_px) <> "px"),
                attribute.style("background-color", color),
                attribute.style("opacity", opacity),
                attribute.style("color", "white"),
                attribute.style("min-width", "0"),
              ],
              extra_style,
            ]),
            label_content,
          )
        })

      html.div(
        [
          attribute.class("flex-1"),
          attribute.style("display", "grid"),
          attribute.style("grid-template-columns", grid_cols),
          attribute.style(
            "grid-template-rows",
            "repeat("
              <> int.to_string(int.max(lane_count, 1))
              <> ", "
              <> int.to_string(bar_px)
              <> "px)",
          ),
          attribute.style("height", int.to_string(grid_height_px) <> "px"),
          attribute.style("border-bottom", "1px solid oklch(0 0 0 / 8%)"),
        ],
        bar_els,
      )
    }

    // Now indicator: vertical line spanning all sub-rows, positioned inside time_grid.
    let now_offset = now_min - window.start_min
    let now_el = case is_today && now_offset >= 0 && now_offset <= total_min {
      False -> element.none()
      True ->
        html.div(
          [
            attribute.class(
              "absolute top-0 bottom-0 w-px bg-accent-border/70 z-20 pointer-events-none",
            ),
            attribute.style("left", xpct(now_offset)),
          ],
          [],
        )
    }

    // All-day chips.
    let all_day_chips =
      list.map(all_day_events, fn(e) {
        let color = color_for(e.calendar_name)
        html.span(
          [
            attribute.class(
              "inline-block px-1 rounded text-white leading-tight truncate",
            ),
            attribute.style("font-size", "9px"),
            attribute.style("background-color", color),
          ],
          [html.text(e.summary)],
        )
      })

    // Date label + all-day chips (left gutter, 4rem wide).
    let date_label =
      html.span(
        [
          attribute.class(case is_today {
            True -> "font-bold text-accent-border leading-tight"
            False -> "font-medium text-text-muted leading-tight"
          }),
          attribute.style("font-size", "10px"),
        ],
        [html.text(weekday_name(day) <> " " <> format_date(day))],
      )

    // Compute the grid height for each sub-row position so the left gutter can
    // mirror the same heights for person-label alignment.
    let sub_row_height = fn(pos: BarPos) -> Int {
      let bars =
        list.filter(
          all_bars,
          fn(t: #(BarPos, Int, Int, String, Bool, Bool, String, String)) {
            t.0 == pos
          },
        )
      let assigned = assign_lanes(bars)
      let lane_count =
        list.fold(assigned, 0, fn(mx, p) { int.max(mx, p.0 + 1) })
      int.max(lane_count, 1) * bar_px
    }
    let sh_left = sub_row_height(BarLeft)
    let sh_center = sub_row_height(BarCenter)
    let sh_right = sub_row_height(BarRight)

    // Left gutter: date + all-day chips (in a top section), then three sub-row
    // sections whose heights mirror the time grid sub-rows so person labels
    // sit vertically centered within the correct lane band.
    //
    // A thin spacer at the top matches the hour-tick header strip height.
    let person_label = fn(name: String) -> Element(msg) {
      case name {
        "" -> element.none()
        n ->
          html.span(
            [
              attribute.class("text-text-faint leading-none"),
              attribute.style("font-size", "7px"),
            ],
            [html.text(n)],
          )
      }
    }
    let sub_row_gutter = fn(h: Int, child: Element(msg)) -> Element(msg) {
      html.div(
        [
          attribute.class("flex items-center"),
          attribute.style("height", int.to_string(h) <> "px"),
          attribute.style("border-bottom", "1px solid oklch(0 0 0 / 8%)"),
        ],
        [child],
      )
    }
    let left_gutter =
      html.div(
        [
          attribute.class(
            "shrink-0 flex flex-col gap-0.5 pt-0.5 pr-1 select-none overflow-hidden",
          ),
          attribute.style("width", "5.5rem"),
        ],
        list.flatten([
          [date_label],
          all_day_chips,
          // Tick header spacer — matches the hour-tick strip height above sub-rows.
          [
            html.div(
              [attribute.style("height", int.to_string(tick_header_px) <> "px")],
              [],
            ),
          ],
          // Three sub-row gutters mirror the time grid grid heights.
          [
            sub_row_gutter(sh_left, person_label(person0)),
            sub_row_gutter(sh_center, element.none()),
            sub_row_gutter(sh_right, person_label(person1)),
          ],
        ]),
      )

    // Time grid: sub-rows fill vertical space equally via flex-1.
    // Hour ticks and now-indicator are absolute overlays inside time_grid.
    let time_grid =
      html.div(
        [
          attribute.class(
            "relative flex-1 flex flex-col min-w-0 overflow-hidden",
          ),
          attribute.style("border-left", "1px solid oklch(0 0 0 / 20%)"),
        ],
        list.flatten([
          // Gridlines first — absolute, span full time_grid height (top-0 bottom-0).
          all_grid_lines,
          // Now indicator — absolute, spans full height.
          [now_el],
          // Hour tick header strip — flow element, sits at top of time grid.
          [hour_tick_strip],
          // Sub-rows — normal flow, fill available vertical space equally.
          [
            view_sub_row(BarLeft),
            view_sub_row(BarCenter),
            view_sub_row(BarRight),
          ],
        ]),
      )

    html.div(
      [
        attribute.class("flex flex-row flex-1"),
        attribute.style("border-bottom", case is_today {
          True -> "2px solid oklch(0 0 0 / 40%)"
          False -> "1px solid oklch(0 0 0 / 30%)"
        }),
        attribute.class(case is_today {
          True -> "bg-surface-2/20"
          False -> ""
        }),
      ],
      [left_gutter, time_grid],
    )
  }

  // Outer container: flex column, fills available space.
  html.div(
    [
      attribute.class(
        "flex-1 min-h-0 flex flex-col overflow-hidden px-2 pt-1 pb-2",
      ),
    ],
    [
      html.div(
        [attribute.class("flex-1 min-h-0 flex flex-col")],
        list.map(list.zip(days, day_timed_and_blocks), fn(pair) {
          let #(day, #(day_timed, day_blocks)) = pair
          let all_day =
            list.filter(events, fn(e) { all_day_spans_date(e, day) })
          view_gantt_day(day, day == today_date, day_timed, day_blocks, all_day)
        }),
      ),
    ],
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

/// Returns a list of integers from start (inclusive) to stop (inclusive).
fn int_range(start: Int, stop: Int) -> List(Int) {
  int.range(from: start, to: stop + 1, with: [], run: fn(acc, i) { [i, ..acc] })
  |> list.reverse
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

@external(erlang, "erlang", "round")
fn float_round(f: Float) -> Int
