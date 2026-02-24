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
  let xfpct = fn(f: Float) -> String { float_pct(f /. total_f *. 100.0) }

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
  // Quarter-hour lines (15, 30, 45 min offsets within each hour) — very faint.
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
                  attribute.class(
                    "absolute top-0 bottom-0 border-l border-border/20 pointer-events-none",
                  ),
                  attribute.style("left", xpct(min)),
                ],
                [],
              ),
            )
        }
      })
    })
  // Hour lines — slightly stronger than quarter lines.
  let hour_lines =
    list.filter_map(int_range(first_hour, last_hour), fn(h) {
      let min = h * 60 - window.start_min
      case min > 0 && min < total_min {
        False -> Error(Nil)
        True ->
          Ok(
            html.div(
              [
                attribute.class(
                  "absolute top-0 bottom-0 border-l border-border/50 pointer-events-none",
                ),
                attribute.style("left", xpct(min)),
              ],
              [],
            ),
          )
      }
    })
  let all_grid_lines = list.append(quarter_lines, hour_lines)

  // A type alias for gantt bar tuples: (bar, left_min, width_min, color, thick, label, label2)
  // We use a record-less 7-tuple throughout.

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
    // (thick=False) are pinned to the same lane as their adjacent event bar
    // (DriveTo ends where the event starts; DriveFrom starts where event ends).
    // This keeps e.g. "4 min home" in the same lane as Trivia, not bumped up.
    let assign_lanes = fn(
      bars: List(#(BarPos, Int, Int, String, Bool, Bool, String, String)),
    ) -> List(#(Int, #(BarPos, Int, Int, String, Bool, Bool, String, String))) {
      let type_of = fn(
        bar: #(BarPos, Int, Int, String, Bool, Bool, String, String),
      ) {
        bar.4
      }
      let event_bars_only = list.filter(bars, type_of)
      let travel_bars_only = list.filter(bars, fn(b) { !type_of(b) })

      // Phase 1: greedy lane assignment for event bars only.
      let sorted_events =
        list.sort(
          event_bars_only,
          fn(
            a: #(BarPos, Int, Int, String, Bool, Bool, String, String),
            b: #(BarPos, Int, Int, String, Bool, Bool, String, String),
          ) {
            int.compare(a.1, b.1)
          },
        )
      let init: #(
        List(#(Int, #(BarPos, Int, Int, String, Bool, Bool, String, String))),
        List(Int),
      ) = #([], [])
      let #(event_assigned, _lane_ends) =
        list.fold(
          sorted_events,
          init,
          fn(acc, bar: #(BarPos, Int, Int, String, Bool, Bool, String, String)) {
            let #(assignments, lane_ends) = acc
            let bar_left = bar.1
            let bar_right = bar.1 + bar.2
            let found =
              list.index_map(lane_ends, fn(end_min, idx) { #(idx, end_min) })
              |> list.find(fn(p: #(Int, Int)) { p.1 <= bar_left })
            case found {
              Ok(#(lane_idx, _)) -> {
                let new_ends =
                  list.index_map(lane_ends, fn(e, i) {
                    case i == lane_idx {
                      True -> bar_right
                      False -> e
                    }
                  })
                #(list.append(assignments, [#(lane_idx, bar)]), new_ends)
              }
              Error(Nil) -> {
                let lane_idx = list.length(lane_ends)
                let new_ends = list.append(lane_ends, [bar_right])
                #(list.append(assignments, [#(lane_idx, bar)]), new_ends)
              }
            }
          },
        )

      // Phase 2: pin each travel bar to its adjacent event bar's lane.
      // DriveTo ends where event starts: travel.left + travel.width == event.left
      // DriveFrom starts where event ends: travel.left == event.left + event.width
      let travel_assigned =
        list.map(
          travel_bars_only,
          fn(bar: #(BarPos, Int, Int, String, Bool, Bool, String, String)) {
            let travel_left = bar.1
            let travel_right = bar.1 + bar.2
            let lane = case
              list.find(
                event_assigned,
                fn(
                  p: #(
                    Int,
                    #(BarPos, Int, Int, String, Bool, Bool, String, String),
                  ),
                ) {
                  let ev = p.1
                  let ev_left = ev.1
                  let ev_right = ev_left + ev.2
                  // DriveTo: travel_right touches event start
                  travel_right == ev_left
                  // DriveFrom: travel_left touches event end
                  || travel_left == ev_right
                },
              )
            {
              Ok(#(lane_idx, _)) -> lane_idx
              // No adjacent event found — open a new lane (shouldn't happen normally).
              Error(Nil) -> list.length(event_assigned)
            }
            #(lane, bar)
          },
        )

      list.append(event_assigned, travel_assigned)
    }

    // Fixed pixel height for every bar (thick or thin).
    let bar_px = 20

    // Render one sub-row (by BarPos) as stacked lanes.
    // Returns element.none() when there are no bars so empty rows are invisible.
    let view_sub_row = fn(pos: BarPos, row_label: String) -> Element(msg) {
      let bars = list.filter(all_bars, fn(t) { t.0 == pos })
      case bars {
        [] -> element.none()
        _ -> {
          let assigned = assign_lanes(bars)
          let lane_count =
            list.fold(assigned, 0, fn(mx, p) { int.max(mx, p.0 + 1) })
          let row_height_px = lane_count * bar_px

          // Build one absolutely-positioned bar element per assigned bar.
          let bar_els =
            list.map(assigned, fn(pair) {
              let #(
                lane,
                #(_, left_min, width_min, color, thick, is_free, label, label2),
              ) = pair
              let top_px = lane * bar_px
              // Vertical padding inside the lane height.
              let pad_px = case thick {
                True -> 2
                False -> 5
              }
              let bar_top_px = top_px + pad_px
              let bar_height_px = bar_px - pad_px * 2
              let opacity = case thick {
                True -> "0.85"
                False -> "0.55"
              }
              let clamped_width = int.min(width_min, total_min - left_min)
              // Detect cross-midnight: original bar extends past the window.
              let cross_midnight = width_min > total_min - left_min
              // Suppress labels on very narrow bars.
              // Travel bars (thin): suppress if < 20 min.
              // Event bars (thick): always show summary; time/loc shown conditionally.
              let too_narrow = !thick && clamped_width < 20
              // Thresholds for showing secondary info on event bars.
              // Show time annotation only if bar is wide enough (~35 min).
              let show_time = thick && clamped_width >= 35
              // Label: primary (event name) always shown; secondary (time) shown when wide enough.
              let label_content = case label, too_narrow {
                _, True -> []
                "", False -> []
                _, False -> [
                  html.span(
                    [
                      // Summary always visible, never shrinks away — takes minimum width needed,
                      // then truncates if even that doesn't fit.
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
                          // Secondary info: shown only if bar is wide enough, and itself truncates.
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
              // Free (transparent) events: outlined bar with colored border, no fill.
              // Cross-midnight busy events: fade-out on right edge.
              let extra_style = case is_free, cross_midnight {
                True, _ -> [
                  attribute.style("background-color", "transparent"),
                  attribute.style("border", "1.5px solid " <> color),
                  attribute.style("opacity", "0.7"),
                  attribute.style("color", color),
                ]
                False, True -> [
                  attribute.style(
                    "mask-image",
                    "linear-gradient(to right, black 70%, transparent 100%)",
                  ),
                ]
                False, False -> []
              }
              html.div(
                list.flatten([
                  [
                    attribute.class(
                      "absolute overflow-hidden flex items-center gap-0.5 px-1 pointer-events-none select-none rounded-sm",
                    ),
                    attribute.style("left", xpct(left_min)),
                    attribute.style("width", xfpct(int_to_float(clamped_width))),
                    attribute.style("top", int.to_string(bar_top_px) <> "px"),
                    attribute.style(
                      "height",
                      int.to_string(bar_height_px) <> "px",
                    ),
                    attribute.style("background-color", color),
                    attribute.style("opacity", opacity),
                    attribute.style("color", "white"),
                  ],
                  extra_style,
                ]),
                label_content,
              )
            })

          // Row label (person name) overlaid at top-left.
          let label_el = case row_label {
            "" -> element.none()
            name ->
              html.span(
                [
                  attribute.class(
                    "absolute top-0.5 left-0.5 text-text-faint leading-none pointer-events-none select-none z-10",
                  ),
                  attribute.style("font-size", "7px"),
                ],
                [html.text(name)],
              )
          }

          html.div(
            [
              attribute.class(
                "relative border-b border-border/15 overflow-hidden",
              ),
              attribute.style("height", int.to_string(row_height_px) <> "px"),
            ],
            list.flatten([all_grid_lines, bar_els, [label_el]]),
          )
        }
      }
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

    // Top strip: date + all-day chips on one line.
    let day_header =
      html.div(
        [
          attribute.class(
            "shrink-0 flex flex-row flex-wrap items-baseline gap-x-1 gap-y-0.5 px-0.5 py-0.5 select-none",
          ),
        ],
        [
          html.span(
            [
              attribute.class(case is_today {
                True -> "font-bold text-accent-border leading-tight shrink-0"
                False -> "font-medium text-text-muted leading-tight shrink-0"
              }),
              attribute.style("font-size", "10px"),
            ],
            [html.text(weekday_name(day) <> " " <> format_date(day))],
          ),
          ..all_day_chips
        ],
      )

    // Time grid: sub-rows stacked, sized to their lane content.
    // The now-line spans the full height via absolute positioning.
    let time_grid =
      html.div(
        [
          attribute.class(
            "relative flex-1 flex flex-col min-w-0 border-l border-border/30 overflow-hidden",
          ),
        ],
        [
          now_el,
          view_sub_row(BarLeft, person0),
          view_sub_row(BarCenter, ""),
          view_sub_row(BarRight, person1),
        ],
      )

    html.div(
      [
        attribute.class("flex flex-col flex-1 border-b border-border"),
        attribute.class(case is_today {
          True -> "bg-surface-2/20"
          False -> ""
        }),
      ],
      [day_header, time_grid],
    )
  }

  // Hour label header row — shows time ticks above the day rows.
  let hour_header =
    html.div([attribute.class("flex flex-row shrink-0 gap-1")], [
      // Spacer matching the date column width.
      html.div(
        [attribute.class("shrink-0"), attribute.style("width", "4rem")],
        [],
      ),
      html.div(
        [
          attribute.class(
            "relative flex-1 border-l border-border/30 overflow-hidden",
          ),
          attribute.style("height", "1rem"),
        ],
        list.filter_map(int_range(first_hour, last_hour), fn(h) {
          let min = h * 60 - window.start_min
          case min >= 0 && min <= total_min {
            False -> Error(Nil)
            True ->
              Ok(html.span(
                [
                  attribute.class(
                    "absolute text-text-faint select-none leading-none",
                  ),
                  attribute.style("left", xpct(min)),
                  attribute.style("font-size", "8px"),
                  // Center the label on the gridline; pin left/right at extremes to avoid clipping.
                  attribute.style("transform", case min {
                    0 -> "translateX(0%)"
                    _ if min >= total_min -> "translateX(-100%)"
                    _ -> "translateX(-50%)"
                  }),
                ],
                [html.text(format_hour(h))],
              ))
          }
        }),
      ),
    ])

  // Outer container: flex column, fills available space.
  html.div(
    [
      attribute.class(
        "flex-1 min-h-0 flex flex-col overflow-hidden px-2 pt-1 pb-2",
      ),
    ],
    [
      hour_header,
      html.div(
        [attribute.class("flex-1 min-h-0 flex flex-col gap-px")],
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
