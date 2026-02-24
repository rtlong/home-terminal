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
  let _xfpct = fn(f: Float) -> String { float_pct(f /. total_f *. 100.0) }

  // Person names for sub-row labels (unused now that labels are hidden).
  let _person0 = case people {
    [p, ..] -> p
    [] -> ""
  }
  let _person1 = case people {
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

  // Gridlines — placed in a full-height overlay grid that shares the same
  // column template as event sub-rows, so lines align exactly with bar edges.
  // Quarter lines: faint, 1px. Hour lines: stronger, 2px.
  let grid_line_items =
    list.flatten([
      list.flat_map(int_range(first_hour, last_hour - 1), fn(h) {
        list.filter_map([15, 30, 45], fn(q) {
          let min = h * 60 + q - window.start_min
          case min > 0 && min < total_min {
            False -> Error(Nil)
            True ->
              Ok(
                html.div(
                  [
                    attribute.class("pointer-events-none"),
                    attribute.style("grid-column", int.to_string(min + 1)),
                    attribute.style("grid-row", "1"),
                    attribute.style("border-left", "1px solid " <> qline_color),
                  ],
                  [],
                ),
              )
          }
        })
      }),
      list.filter_map(int_range(first_hour, last_hour), fn(h) {
        let min = h * 60 - window.start_min
        case min > 0 && min < total_min {
          False -> Error(Nil)
          True ->
            Ok(
              html.div(
                [
                  attribute.class("pointer-events-none"),
                  attribute.style("grid-column", int.to_string(min + 1)),
                  attribute.style("grid-row", "1"),
                  attribute.style("border-left", "2px solid " <> hline_color),
                ],
                [],
              ),
            )
        }
      }),
    ])
  // The gridline overlay: a full-height absolute grid that sits behind events.
  let grid_cols_str =
    "repeat(" <> int.to_string(total_min) <> ", minmax(0, 1fr))"
  let grid_line_overlay =
    html.div(
      [
        attribute.class("absolute inset-0 pointer-events-none"),
        attribute.style("display", "grid"),
        attribute.style("grid-template-columns", grid_cols_str),
        attribute.style("grid-template-rows", "100%"),
        attribute.style("align-items", "stretch"),
      ],
      grid_line_items,
    )

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

    // Fixed pixel height for every bar lane.
    let bar_px = 20

    // Hour tick labels — placed in the same grid as event bars so they align
    // exactly with gridlines. Labels sit to the right of the hour boundary
    // (translateX(2px)) rather than centred on it, avoiding overlap with the
    // gridline itself and making them readable.
    let hour_tick_strip =
      html.div(
        [
          attribute.class("relative shrink-0 select-none pointer-events-none"),
          attribute.style("display", "grid"),
          attribute.style("grid-template-columns", grid_cols_str),
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
                    attribute.class("text-text-muted leading-none self-end"),
                    attribute.style("grid-column", int.to_string(min + 1)),
                    attribute.style("font-size", "8px"),
                    attribute.style("padding-left", "2px"),
                    attribute.style("padding-bottom", "1px"),
                    attribute.style("white-space", "nowrap"),
                  ],
                  [html.text(format_hour(h))],
                ),
              )
          }
        }),
      )

    // CSS grid column template — reuse the one built in the outer scope.
    let grid_cols = grid_cols_str

    // Group bars by their event: each event bar plus any DriveTo/DriveFrom
    // travel bars that touch it forms a single grid item spanning the full
    // extent (travel_start .. travel_end).  Inside the group, sub-bars are
    // laid out as a flex row with each piece sized proportionally by minutes,
    // keeping travel flush with its event without needing explicit grid-row.
    // Free events (no adjacent travel) and lone travel-free events are their
    // own single-bar groups.
    let make_groups = fn(
      bars: List(#(BarPos, Int, Int, String, Bool, Bool, String, String)),
    ) -> List(
      #(Int, Int, List(#(BarPos, Int, Int, String, Bool, Bool, String, String))),
    ) {
      let is_thick = fn(
        b: #(BarPos, Int, Int, String, Bool, Bool, String, String),
      ) {
        b.4
      }
      let event_bars = list.filter(bars, is_thick)
      let travel_bars = list.filter(bars, fn(b) { !is_thick(b) })
      // For each event bar, claim its touching travel bars.
      let #(groups, claimed) =
        list.fold(event_bars, #([], []), fn(acc, ev) {
          let #(gs, claimed) = acc
          let ev_left = ev.1
          let ev_right = ev.1 + ev.2
          let drive_to =
            list.filter(travel_bars, fn(tb) { tb.1 + tb.2 == ev_left })
          let drive_from = list.filter(travel_bars, fn(tb) { tb.1 == ev_right })
          let members = list.flatten([drive_to, [ev], drive_from])
          let g_left = list.fold(members, ev_left, fn(m, b) { int.min(m, b.1) })
          let g_right =
            list.fold(members, ev_right, fn(m, b) { int.max(m, b.1 + b.2) })
          let new_claimed =
            list.flatten([
              claimed,
              list.map(drive_to, fn(b) { b.1 }),
              list.map(drive_from, fn(b) { b.1 }),
            ])
          #(list.append(gs, [#(g_left, g_right, members)]), new_claimed)
        })
      // Any travel bar not claimed by an event gets its own group.
      let lone_travel =
        list.filter(travel_bars, fn(tb) { !list.contains(claimed, tb.1) })
      let lone_groups =
        list.map(lone_travel, fn(tb) { #(tb.1, tb.1 + tb.2, [tb]) })
      list.append(groups, lone_groups)
    }

    // Render one event bar (no travel) inside a group.
    let render_event_bar = fn(
      bar: #(BarPos, Int, Int, String, Bool, Bool, String, String),
      flex_val: Int,
    ) -> Element(msg) {
      let #(_, left_min, width_min, color, _thick, is_free, label, label2) = bar
      let clamped_width = int.min(width_min, total_min - left_min)
      let right_min = left_min + clamped_width
      let show_time = clamped_width >= 35
      case is_free {
        // Free events: number-line style — a thin horizontal axis with caps
        // at each end and the label floating above the line.
        // Terminating end (event starts/ends within window): vertical bar cap.
        // Continuing end (event runs past window boundary): arrow cap.
        True -> {
          // Continuing-left: arrow pointing left (event runs before window start)
          let continuing_left =
            html.div(
              [
                attribute.style("width", "0"),
                attribute.style("height", "0"),
                attribute.style("border-top", "4px solid transparent"),
                attribute.style("border-bottom", "4px solid transparent"),
                attribute.style("border-right", "5px solid " <> color),
                attribute.style("flex-shrink", "0"),
                attribute.style("opacity", "0.7"),
              ],
              [],
            )
          // Terminating-left: vertical bar (event starts here)
          let terminating_left =
            html.div(
              [
                attribute.style("width", "2px"),
                attribute.style("height", "8px"),
                attribute.style("background-color", color),
                attribute.style("flex-shrink", "0"),
                attribute.style("opacity", "0.7"),
              ],
              [],
            )
          // Continuing-right: arrow pointing right (event runs past window end)
          let continuing_right =
            html.div(
              [
                attribute.style("width", "0"),
                attribute.style("height", "0"),
                attribute.style("border-top", "4px solid transparent"),
                attribute.style("border-bottom", "4px solid transparent"),
                attribute.style("border-left", "5px solid " <> color),
                attribute.style("flex-shrink", "0"),
                attribute.style("opacity", "0.7"),
              ],
              [],
            )
          // Terminating-right: vertical bar (event ends here)
          let terminating_right =
            html.div(
              [
                attribute.style("width", "2px"),
                attribute.style("height", "8px"),
                attribute.style("background-color", color),
                attribute.style("flex-shrink", "0"),
                attribute.style("opacity", "0.7"),
              ],
              [],
            )
          let left_cap = case left_min <= 0 {
            True -> continuing_left
            False -> terminating_left
          }
          let right_cap = case right_min >= total_min {
            True -> continuing_right
            False -> terminating_right
          }
          // Label text (name + optional time), sitting above the axis line
          let label_el = case label {
            "" -> element.none()
            _ ->
              html.span(
                [
                  attribute.class(
                    "relative truncate pointer-events-none select-none",
                  ),
                  attribute.style("font-size", "8px"),
                  attribute.style("color", color),
                  attribute.style("opacity", "0.8"),
                  attribute.style("line-height", "1"),
                  attribute.style("white-space", "nowrap"),
                  attribute.style("overflow", "hidden"),
                  attribute.style("text-overflow", case show_time {
                    True -> "ellipsis"
                    False -> "clip"
                  }),
                ],
                [
                  html.text(case label2, show_time {
                    t, True if t != "" -> label <> " " <> t
                    _, _ -> label
                  }),
                ],
              )
          }
          // The axis line runs full-width; arrowheads and label are vertically centered.
          html.div(
            [
              attribute.class(
                "relative overflow-hidden pointer-events-none select-none",
              ),
              attribute.style("flex", int.to_string(flex_val) <> " 0 0"),
              attribute.style("min-width", "0"),
              attribute.style("display", "flex"),
              attribute.style("flex-direction", "column"),
              attribute.style("justify-content", "center"),
              attribute.style("align-items", "stretch"),
            ],
            [
              // Label row above the line
              html.div(
                [
                  attribute.style("display", "flex"),
                  attribute.style("justify-content", "center"),
                  attribute.style("padding-bottom", "1px"),
                ],
                [label_el],
              ),
              // Axis row: left cap + line + right cap
              html.div(
                [
                  attribute.style("display", "flex"),
                  attribute.style("align-items", "center"),
                  attribute.style("min-width", "0"),
                ],
                [
                  left_cap,
                  html.div(
                    [
                      attribute.style("flex", "1 0 0"),
                      attribute.style("height", "0"),
                      attribute.style("border-top", "1.5px solid " <> color),
                      attribute.style("opacity", "0.7"),
                    ],
                    [],
                  ),
                  right_cap,
                ],
              ),
            ],
          )
        }
        // Normal (busy) events: solid filled bar with label.
        False -> {
          let is_start_day_xm = left_min > 0 && right_min >= total_min
          let is_end_day_xm =
            left_min == 0 && right_min < total_min && width_min == clamped_width
          let extra_style = case is_start_day_xm, is_end_day_xm {
            True, _ -> [
              attribute.style(
                "mask-image",
                "linear-gradient(to right, black 60%, transparent 100%)",
              ),
            ]
            False, True -> [
              attribute.style(
                "mask-image",
                "linear-gradient(to left, black 60%, transparent 100%)",
              ),
            ]
            False, False -> []
          }
          let label_content = case label {
            "" -> []
            _ -> [
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
          html.div(
            list.flatten([
              [
                attribute.class(
                  "overflow-hidden flex items-center gap-0.5 px-1 pointer-events-none select-none rounded-sm",
                ),
                attribute.style("flex", int.to_string(flex_val) <> " 0 0"),
                attribute.style("min-width", "0"),
                attribute.style("background-color", color),
                attribute.style("opacity", "0.85"),
                attribute.style("color", "white"),
              ],
              extra_style,
            ]),
            label_content,
          )
        }
      }
    }

    // Render one group: event bar optionally wrapped in a travel-time border.
    // When travel exists, the outer div shows a full-height border in the
    // calendar color spanning the whole travel extent. The event bar sits
    // inside at its actual proportional position with transparent spacers
    // filling the travel time on each side.
    let render_group = fn(
      g: #(
        Int,
        Int,
        List(#(BarPos, Int, Int, String, Bool, Bool, String, String)),
      ),
    ) -> Element(msg) {
      let #(g_left, g_right, members) = g
      let col_start = int.to_string(g_left + 1)
      let col_end = int.to_string(g_right + 1)
      let is_thick = fn(
        b: #(BarPos, Int, Int, String, Bool, Bool, String, String),
      ) {
        b.4
      }
      let ev_bars = list.filter(members, is_thick)
      let travel_bars = list.filter(members, fn(b) { !is_thick(b) })
      case travel_bars, ev_bars {
        // Group has travel: render a border envelope with the event inside.
        [_, ..], [ev, ..] -> {
          let ev_left = ev.1
          let ev_right = ev.1 + int.min(ev.2, total_min - ev.1)
          let color = ev.3
          let drive_to_w = ev_left - g_left
          let ev_w = ev_right - ev_left
          let drive_from_w = g_right - ev_right
          // Transparent spacers for travel portions; solid bar for event.
          let inner_els =
            list.flatten([
              case drive_to_w > 0 {
                False -> []
                True -> [
                  html.div(
                    [
                      attribute.style(
                        "flex",
                        int.to_string(drive_to_w) <> " 0 0",
                      ),
                    ],
                    [],
                  ),
                ]
              },
              [render_event_bar(ev, ev_w)],
              case drive_from_w > 0 {
                False -> []
                True -> [
                  html.div(
                    [
                      attribute.style(
                        "flex",
                        int.to_string(drive_from_w) <> " 0 0",
                      ),
                    ],
                    [],
                  ),
                ]
              },
            ])
          html.div(
            [
              attribute.class(
                "flex flex-row pointer-events-none select-none rounded-sm",
              ),
              attribute.style("grid-column", col_start <> " / " <> col_end),
              attribute.style("border", "1.5px solid " <> color),
              attribute.style("min-width", "0"),
              attribute.style("overflow", "hidden"),
            ],
            inner_els,
          )
        }
        // No travel: just the event bar directly, with vertical breathing room.
        _, [ev, ..] -> {
          let ev_w = int.min(ev.2, total_min - ev.1)
          html.div(
            [
              attribute.class("flex flex-row"),
              attribute.style("grid-column", col_start <> " / " <> col_end),
              attribute.style("min-width", "0"),
              attribute.style("margin-top", "2px"),
              attribute.style("margin-bottom", "2px"),
            ],
            [render_event_bar(ev, ev_w)],
          )
        }
        // Lone travel bar without an event (shouldn't happen but handle gracefully).
        _, _ -> element.none()
      }
    }

    // Render one sub-row using CSS grid with auto-placement.
    let view_sub_row = fn(pos: BarPos) -> Element(msg) {
      let bars =
        list.filter(
          all_bars,
          fn(t: #(BarPos, Int, Int, String, Bool, Bool, String, String)) {
            t.0 == pos
          },
        )
      let groups = make_groups(bars)
      html.div(
        [
          attribute.class("flex-1"),
          attribute.style("display", "grid"),
          attribute.style("grid-template-columns", grid_cols),
          attribute.style("grid-auto-flow", "dense"),
          attribute.style("grid-auto-rows", int.to_string(bar_px) <> "px"),
          attribute.style("border-bottom", "1px solid oklch(0 0 0 / 8%)"),
        ],
        list.map(groups, render_group),
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

    // Left gutter: date label + all-day chips. Width is wider to allow chips
    // to display more text before truncating.
    let left_gutter =
      html.div(
        [
          attribute.class(
            "shrink-0 flex flex-col gap-0.5 pt-0.5 pr-1 select-none overflow-hidden",
          ),
          attribute.style("width", "7rem"),
        ],
        list.flatten([[date_label], all_day_chips]),
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
          // Gridline overlay — absolute, same column grid as event bars.
          [grid_line_overlay],
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
