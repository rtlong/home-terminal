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
import palette
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
  latitude: Float,
  longitude: Float,
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

  // Compute sunrise/sunset times for each day (when lat/lon are configured).
  let utc_offset_hours = duration.to_seconds(local_offset) /. 3600.0
  let day_sun_times =
    list.map(days, fn(day) {
      case latitude == 0.0 && longitude == 0.0 {
        True -> Error(Nil)
        False -> compute_sun_times(day, latitude, longitude, utc_offset_hours)
      }
    })

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

  let grid_cols_str =
    "repeat(" <> int.to_string(total_min) <> ", minmax(0, 1fr))"

  // Gridlines and tick labels are built per-day inside view_gantt_day so they
  // have access to sun_times and can adapt colors in night zones.

  // A type alias for gantt bar tuples: (bar, left_min, width_min, color, thick, label, label2)
  // We use a record-less 7-tuple throughout.

  // Height in px of the hour-tick header strip at the top of each day's time grid.
  // Event bars live below this strip, so ticks never overlap bars.
  let tick_header_px = 14

  // Render one day row.
  let view_gantt_day = fn(
    day: Date,
    is_today: Bool,
    day_timed: List(Event),
    day_blocks: List(TravelBlock),
    all_day_events: List(Event),
    sun_times: Result(SunTimes, Nil),
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
                      case is_quarter_hour(st.minutes) {
                        True -> ""
                        False -> format_time(s, local_offset) <> " →"
                      },
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
                      case is_quarter_hour(et.minutes) {
                        True -> ""
                        False -> "ends " <> format_time(en, local_offset)
                      },
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
                let time_str = case
                  is_quarter_hour(st.minutes) && is_quarter_hour(et.minutes)
                {
                  True -> ""
                  False ->
                    format_time(s, local_offset)
                    <> "–"
                    <> format_time(en, local_offset)
                }
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
    let bar_px = 26

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
          // Label box: solid background + border, attached to the axis line.
          // Shows name and time (if non-quarter-hour) inline on the line.
          let label_text = case label2, show_time {
            t, True if t != "" -> label <> " " <> t
            _, _ -> label
          }
          let label_box = case label {
            "" -> element.none()
            _ ->
              html.span(
                [
                  attribute.class(
                    "shrink-0 pointer-events-none select-none leading-none",
                  ),
                  attribute.style("font-size", "11px"),
                  attribute.style("color", "white"),
                  attribute.style("background-color", color),
                  attribute.style("border", "1px solid " <> color),
                  // attribute.style("opacity", "0.85"),
                  attribute.style("border-radius", "2px"),
                  attribute.style("padding", "1px 3px"),
                  attribute.style("white-space", "nowrap"),
                ],
                [html.text(label_text)],
              )
          }
          // Axis row: left_cap — short line — label_box — line fills remainder — right_cap.
          // All items are vertically centered on the axis.
          let line_segment =
            html.div(
              [
                attribute.style("flex", "1 0 0"),
                attribute.style("height", "0"),
                attribute.style("border-top", "1.5px solid " <> color),
                // attribute.style("opacity", "0.7"),
                attribute.style("min-width", "4px"),
              ],
              [],
            )
          html.div(
            [
              attribute.class(
                "relative overflow-hidden pointer-events-none select-none",
              ),
              attribute.style("flex", int.to_string(flex_val) <> " 0 0"),
              attribute.style("min-width", "0"),
              attribute.style("display", "flex"),
              attribute.style("align-items", "center"),
            ],
            [left_cap, line_segment, label_box, line_segment, right_cap],
          )
        }
        // Normal (busy) events: solid filled bar with label.
        False -> {
          let is_start_day_xm = left_min > 0 && right_min > total_min
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
                  attribute.class("font-medium leading-tight"),
                  attribute.style("font-size", "13px"),
                  attribute.style("padding-left", "3px"),
                ],
                [html.text(label)],
              ),
              case label2, show_time {
                _, False -> element.none()
                "", _ -> element.none()
                t, True ->
                  html.span(
                    [
                      attribute.class("leading-none opacity-70"),
                      attribute.style("font-size", "11px"),
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
                  "overflow-hidden flex flex-wrap items-start content-center gap-x-0.5 pointer-events-none select-none rounded-sm",
                ),
                attribute.style("flex", int.to_string(flex_val) <> " 0 0"),
                attribute.style("min-width", "0"),
                attribute.style("background-color", color),
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
        // Group has travel: render a tinted envelope with transparent spacers
        // for travel portions and the solid event bar inside.
        [_, ..], [ev, ..] -> {
          let ev_left = ev.1
          let ev_right = ev.1 + int.min(ev.2, total_min - ev.1)
          let color = ev.3
          let drive_to_w = ev_left - g_left
          let ev_w = ev_right - ev_left
          let drive_from_w = g_right - ev_right
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
              attribute.style("background-color", palette.travel_color(color)),
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
          attribute.style(
            "grid-auto-rows",
            "minmax(" <> int.to_string(bar_px) <> "px, auto)",
          ),
          attribute.style("row-gap", "2px"),
          attribute.style("border-bottom", "1px solid oklch(0 0 0 / 5%)"),
          attribute.style("position", "relative"),
          attribute.style("z-index", "1"),
        ],
        list.map(groups, render_group),
      )
    }

    // Now indicator: vertical line spanning all sub-rows, positioned inside time_grid.
    let now_offset = now_min - window.start_min
    let now_in_night = case sun_times {
      Error(_) -> False
      Ok(st) -> now_min < st.civil_dawn || now_min >= st.civil_dusk
    }
    // In night zones use a bright accent so it remains visible on dark bg.
    let now_color = case now_in_night {
      True -> "oklch(0.85 0.15 145)"
      False -> "var(--color-accent-border)"
    }
    let now_el = case is_today && now_offset >= 0 && now_offset <= total_min {
      False -> element.none()
      True ->
        html.div(
          [
            attribute.class("absolute top-0 bottom-0 z-20 pointer-events-none"),
            attribute.style("left", xpct(now_offset)),
            attribute.style("transform", "translateX(-50%)"),
            attribute.style("display", "flex"),
            attribute.style("flex-direction", "column"),
            attribute.style("align-items", "center"),
          ],
          [
            // Circle cap at top
            html.div(
              [
                attribute.style("width", "8px"),
                attribute.style("height", "8px"),
                attribute.style("border-radius", "50%"),
                attribute.style("background-color", now_color),
                attribute.style("flex-shrink", "0"),
              ],
              [],
            ),
            // Vertical line
            html.div(
              [
                attribute.style("width", "2px"),
                attribute.style("flex", "1"),
                attribute.style("background-color", now_color),
                attribute.style("opacity", "0.9"),
              ],
              [],
            ),
          ],
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
            attribute.style("font-size", "13px"),
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
          attribute.style("font-size", "14px"),
        ],
        [html.text(weekday_name(day) <> " " <> format_date(day))],
      )

    // Sunrise/sunset line for left gutter: "↑6:28a ↓5:28p"
    let sun_label_el = case sun_times {
      Error(_) -> element.none()
      Ok(st) -> {
        let rise_str = "↑" <> format_time_min(st.sunrise)
        let set_str = "↓" <> format_time_min(st.sunset)
        html.span(
          [
            attribute.class("leading-none select-none"),
            attribute.style("font-size", "12px"),
            attribute.style("color", "oklch(0.60 0.08 55)"),
          ],
          [html.text(rise_str <> " " <> set_str)],
        )
      }
    }

    // Left gutter: date label + all-day chips. Width is wider to allow chips
    // to display more text before truncating.
    let left_gutter =
      html.div(
        [
          attribute.class(
            "shrink-0 flex flex-col gap-0.5 pt-0.5 pr-1 select-none overflow-hidden",
          ),
          attribute.style("width", "11rem"),
        ],
        list.flatten([[date_label], [sun_label_el], all_day_chips]),
      )

    // Day/night gradient background based on sunrise/sunset times.
    // Phases: night → civil dawn → sunrise → daylight → sunset → civil dusk → night
    // Only rendered when sun_times is available (lat/lon configured and sun rises/sets).
    let sun_gradient_el = case sun_times {
      Error(_) -> element.none()
      Ok(st) -> {
        // Convert absolute minutes-since-midnight to window-relative percentage strings.
        let sun_pct = fn(abs_min: Int) -> String {
          let rel = abs_min - window.start_min
          float_pct(int_to_float(rel) /. total_f *. 100.0)
        }
        // Clamp to [0%, 100%] so stops outside the window don't distort the gradient.
        let clamp_pct = fn(abs_min: Int) -> Int {
          int.max(window.start_min, int.min(window.end_min, abs_min))
        }
        let dawn_pct = sun_pct(clamp_pct(st.civil_dawn))
        let rise_pct = sun_pct(clamp_pct(st.sunrise))
        // A brief "post-dawn glow" stop partway between sunrise and 30min later.
        let glow_end = clamp_pct(st.sunrise + 30)
        let glow_end_pct = sun_pct(glow_end)
        let glow_start = clamp_pct(st.sunset - 30)
        let glow_start_pct = sun_pct(glow_start)
        let set_pct = sun_pct(clamp_pct(st.sunset))
        let dusk_pct = sun_pct(clamp_pct(st.civil_dusk))
        // Colours
        let night_color = "oklch(0.20 0.14 265 / 80%)"
        let dawn_color = "oklch(0.45 0.08 40 / 40%)"
        let glow_color = "oklch(0.70 0.12 55 / 25%)"
        let day_color = "oklch(1 0 0 / 0%)"
        // Build gradient stops as a comma-separated string
        let stops =
          string.join(
            [
              night_color <> " " <> dawn_pct,
              dawn_color <> " " <> rise_pct,
              glow_color <> " " <> glow_end_pct,
              day_color <> " " <> glow_end_pct,
              day_color <> " " <> glow_start_pct,
              glow_color <> " " <> glow_start_pct,
              dawn_color <> " " <> set_pct,
              night_color <> " " <> dusk_pct,
            ],
            ", ",
          )
        html.div(
          [
            attribute.class("absolute inset-0 -z-1 pointer-events-none"),
            attribute.style(
              "background",
              "linear-gradient(to right, "
                <> night_color
                <> ", "
                <> stops
                <> ", "
                <> night_color
                <> ")",
            ),
          ],
          [],
        )
      }
    }

    // Sunrise/sunset markers: a vertical dashed line spanning full height,
    // with a small "↑6:28a" / "↓5:28p" label sitting in the tick-header row.
    // Reuses the same grid as the hour gridlines so column positions match exactly.
    let sun_markers_el = case sun_times {
      Error(_) -> element.none()
      Ok(st) -> {
        let make_marker = fn(abs_min: Int, label: String, is_rise: Bool) -> List(
          Element(msg),
        ) {
          let rel = abs_min - window.start_min
          case rel > 0 && rel < total_min {
            False -> []
            True -> {
              let col = int.to_string(rel + 1)
              let color = case is_rise {
                True -> "oklch(0.62 0.14 58)"
                False -> "oklch(0.52 0.12 32)"
              }
              // Vertical dashed line spanning both grid rows
              let line =
                html.div(
                  [
                    attribute.class("pointer-events-none"),
                    attribute.style("grid-column", col),
                    attribute.style("grid-row", "1 / 3"),
                    attribute.style("align-self", "stretch"),
                    attribute.style(
                      "border-left",
                      "1px dashed " <> color <> "99",
                    ),
                  ],
                  [],
                )
              // Tick-row label: arrow + time, sitting at bottom of header strip
              let tick =
                html.span(
                  [
                    attribute.class(
                      "leading-none pointer-events-none select-none",
                    ),
                    attribute.style("grid-column", col),
                    attribute.style("grid-row", "1"),
                    attribute.style("align-self", "end"),
                    attribute.style("font-size", "11px"),
                    attribute.style("color", color),
                    attribute.style("padding-left", "2px"),
                    attribute.style("padding-bottom", "1px"),
                    attribute.style("white-space", "nowrap"),
                    attribute.style("z-index", "2"),
                  ],
                  [html.text(label)],
                )
              [line, tick]
            }
          }
        }
        let rise_label = "↑" <> format_time_min(st.sunrise)
        let set_label = "↓" <> format_time_min(st.sunset)
        let all_markers =
          list.flatten([
            make_marker(st.sunrise, rise_label, True),
            make_marker(st.sunset, set_label, False),
          ])
        case all_markers {
          [] -> element.none()
          markers ->
            html.div(
              [
                attribute.class("absolute inset-0 pointer-events-none"),
                attribute.style("display", "grid"),
                attribute.style("grid-template-columns", grid_cols_str),
                attribute.style(
                  "grid-template-rows",
                  int.to_string(tick_header_px) <> "px 1fr",
                ),
              ],
              markers,
            )
        }
      }
    }

    // Per-day gridline and tick-label generation, so we can vary colors in
    // night zones (when sun_times is available).
    //
    // A minute is "in night" if it falls outside [civil_dawn, civil_dusk].
    // We use absolute minutes-since-midnight for the comparison.
    let is_night_min = fn(abs_min: Int) -> Bool {
      case sun_times {
        Error(_) -> False
        Ok(st) -> abs_min < st.civil_dawn || abs_min >= st.civil_dusk
      }
    }
    // Gridline colors: dark on light (day), light on dark (night).
    let qline_day = "oklch(0 0 0 / 8%)"
    let qline_night = "oklch(1 1 0 / 10%)"
    let hline_day = "oklch(0 0 0 / 35%)"
    let hline_night = "oklch(1 1 0 / 35%)"
    let label_day = "var(--color-text-muted)"
    let label_night = "oklch(0.65 0.02 0)"

    // Two separate overlay grids — one for lines (behind bars), one for tick
    // labels (above bars). Both use identical grid columns so alignment matches.
    let tick_row = "1"
    let first_hour = case window.start_min % 60 {
      0 -> window.start_min / 60
      _ -> window.start_min / 60 + 1
    }
    let last_hour = window.end_min / 60

    let grid_line_divs =
      list.flatten([
        // Quarter-hour lines
        list.flat_map(int_range(first_hour, last_hour - 1), fn(h) {
          list.filter_map([15, 30, 45], fn(q) {
            let abs_min = h * 60 + q
            let min = abs_min - window.start_min
            case min > 0 && min < total_min {
              False -> Error(Nil)
              True -> {
                let color = case is_night_min(abs_min) {
                  True -> qline_night
                  False -> qline_day
                }
                Ok(
                  html.div(
                    [
                      attribute.class("pointer-events-none"),
                      attribute.style("grid-column", int.to_string(min + 1)),
                      attribute.style("grid-row", "1 / 3"),
                      attribute.style("align-self", "stretch"),
                      attribute.style("border-left", "1px solid " <> color),
                    ],
                    [],
                  ),
                )
              }
            }
          })
        }),
        // Hour lines
        list.filter_map(int_range(first_hour, last_hour), fn(h) {
          let abs_min = h * 60
          let min = abs_min - window.start_min
          case min > 0 && min < total_min {
            False -> Error(Nil)
            True -> {
              let color = case is_night_min(abs_min) {
                True -> hline_night
                False -> hline_day
              }
              Ok(
                html.div(
                  [
                    attribute.class("pointer-events-none"),
                    attribute.style("grid-column", int.to_string(min + 1)),
                    attribute.style("grid-row", "1 / 3"),
                    attribute.style("align-self", "stretch"),
                    attribute.style("border-left", "1px solid " <> color),
                  ],
                  [],
                ),
              )
            }
          }
        }),
      ])

    let grid_tick_labels =
      list.flatten([
        // Hour tick labels
        list.filter_map(int_range(first_hour, last_hour), fn(h) {
          let abs_min = h * 60
          let min = abs_min - window.start_min
          case min > 0 && min < total_min {
            False -> Error(Nil)
            True -> {
              let color = case is_night_min(abs_min) {
                True -> label_night
                False -> label_day
              }
              Ok(
                html.span(
                  [
                    attribute.class(
                      "leading-none pointer-events-none select-none",
                    ),
                    attribute.style("grid-column", int.to_string(min + 1)),
                    attribute.style("grid-row", tick_row),
                    attribute.style("align-self", "end"),
                    attribute.style("font-size", "11px"),
                    attribute.style("color", color),
                    attribute.style("padding-left", "2px"),
                    attribute.style("padding-bottom", "1px"),
                    attribute.style("white-space", "nowrap"),
                  ],
                  [html.text(format_hour(h))],
                ),
              )
            }
          }
        }),
        // First-hour label (column 1, no line)
        case window.start_min % 60 {
          0 -> {
            let h = window.start_min / 60
            let color = case is_night_min(h * 60) {
              True -> label_night
              False -> label_day
            }
            [
              html.span(
                [
                  attribute.class(
                    "leading-none pointer-events-none select-none",
                  ),
                  attribute.style("grid-column", "1"),
                  attribute.style("grid-row", tick_row),
                  attribute.style("align-self", "end"),
                  attribute.style("font-size", "11px"),
                  attribute.style("color", color),
                  attribute.style("padding-left", "2px"),
                  attribute.style("padding-bottom", "1px"),
                  attribute.style("white-space", "nowrap"),
                ],
                [html.text(format_hour(h))],
              ),
            ]
          }
          _ -> []
        },
      ])

    // Lines overlay: z-index 0 (behind event bars at z-index 1).
    let grid_line_overlay =
      html.div(
        [
          attribute.class("absolute inset-0 pointer-events-none"),
          attribute.style("display", "grid"),
          attribute.style("grid-template-columns", grid_cols_str),
          attribute.style(
            "grid-template-rows",
            int.to_string(tick_header_px) <> "px 1fr",
          ),
          attribute.style("z-index", "0"),
        ],
        grid_line_divs,
      )

    // Labels overlay: z-index 2 (above event bars at z-index 1).
    let grid_tick_overlay =
      html.div(
        [
          attribute.class("absolute inset-0 pointer-events-none"),
          attribute.style("display", "grid"),
          attribute.style("grid-template-columns", grid_cols_str),
          attribute.style(
            "grid-template-rows",
            int.to_string(tick_header_px) <> "px 1fr",
          ),
          attribute.style("z-index", "2"),
        ],
        grid_tick_labels,
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
          // Now indicator — absolute, spans full height.
          [now_el],
          // Content wrapper: overlay (gridlines+labels) is absolute inside here.
          // A flow spacer reserves the tick label row height at the top so
          // sub-rows start below the label strip without a separate tick element.
          [
            html.div(
              [attribute.class("relative flex-1 flex flex-col min-w-0")],
              list.flatten([
                // Day/night gradient (behind everything).
                [sun_gradient_el],
                // Gridlines behind event bars (z-index 0).
                [grid_line_overlay],
                // Sunrise/sunset markers overlay.
                [sun_markers_el],
                // Spacer that holds the tick label row height in flow.
                [
                  html.div(
                    [
                      attribute.class("shrink-0 pointer-events-none"),
                      attribute.style(
                        "height",
                        int.to_string(tick_header_px) <> "px",
                      ),
                    ],
                    [],
                  ),
                ],
                // Event sub-rows (z-index 1, above gridlines).
                [
                  view_sub_row(BarLeft),
                  view_sub_row(BarCenter),
                  view_sub_row(BarRight),
                ],
                // Tick labels above event bars (z-index 2).
                [grid_tick_overlay],
              ]),
            ),
          ],
        ]),
      )

    html.div(
      [
        attribute.class("flex flex-row flex-1"),
        attribute.style("border-bottom", case is_today {
          True -> "4px solid oklch(0 0 0 / 65%)"
          False -> "3px solid oklch(0 0 0 / 50%)"
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
        list.map(
          list.zip(days, list.zip(day_timed_and_blocks, day_sun_times)),
          fn(pair) {
            let #(day, #(#(day_timed, day_blocks), sun_times)) = pair
            let all_day =
              list.filter(events, fn(e) { all_day_spans_date(e, day) })
            view_gantt_day(
              day,
              day == today_date,
              day_timed,
              day_blocks,
              all_day,
              sun_times,
            )
          },
        ),
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

/// True when a minute value falls on a quarter-hour boundary (0, 15, 30, 45).
fn is_quarter_hour(m: Int) -> Bool {
  m % 15 == 0
}

/// Format absolute minutes-since-midnight as a short time string, e.g. "6:28a" or "5:28p".
fn format_time_min(abs_min: Int) -> String {
  let h = abs_min / 60
  let m = abs_min % 60
  let period = case h >= 12 {
    True -> "p"
    False -> "a"
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

// SUNRISE / SUNSET CALCULATION ------------------------------------------------

/// Sun times for a given day: minutes-since-midnight (local time) for each
/// phase. Returns Error(Nil) if the sun never rises/sets (polar extremes).
pub type SunTimes {
  SunTimes(civil_dawn: Int, sunrise: Int, sunset: Int, civil_dusk: Int)
}

/// Compute sunrise, sunset, civil dawn and civil dusk for a given date and
/// location. Returns Error(Nil) if the sun doesn't rise or set that day.
///
/// Algorithm: Sunrise Equation (Wikipedia / Jean Meeus simplified form).
/// `utc_offset_hours` is the UTC offset in hours (e.g. -5.0 for EST, -4.0 for EDT).
pub fn compute_sun_times(
  date: Date,
  lat: Float,
  lon: Float,
  utc_offset_hours: Float,
) -> Result(SunTimes, Nil) {
  // Julian date (noon = integer).
  let year = date.year
  let month = calendar.month_to_int(date.month)
  let day = date.day
  // Simple Julian date formula valid for modern dates.
  let jd =
    int_to_float(
      367
      * year
      - { 7 * { year + { month + 9 } / 12 } }
      / 4
      + 275
      * month
      / 9
      + day
      + 1_721_013,
    )
    +. 0.5

  // Current Julian cycle number (days since J2000.0 noon, offset for longitude).
  let j2000 = 2_451_545.0
  let n = float_round(jd -. j2000 +. 0.0008 -. lon /. 360.0)
  let n_f = int_to_float(n)

  // Mean solar noon.
  let j_star = n_f -. lon /. 360.0

  // Solar mean anomaly (degrees).
  let m_deg = mod_f(357.5291 +. 0.98560028 *. j_star, 360.0)
  let m = to_rad(m_deg)

  // Equation of the center.
  let c =
    1.9148
    *. math_sin(m)
    +. 0.02
    *. math_sin(2.0 *. m)
    +. 0.0003
    *. math_sin(3.0 *. m)

  // Ecliptic longitude of the sun (degrees).
  let lam = mod_f(m_deg +. c +. 180.0 +. 102.9372, 360.0)

  // Solar transit (Julian date of solar noon).
  let j_transit =
    j2000
    +. j_star
    +. 0.0053
    *. math_sin(m)
    -. 0.0069
    *. math_sin(2.0 *. to_rad(lam))

  // Declination of the sun.
  let sin_d = math_sin(to_rad(lam)) *. math_sin(to_rad(23.4397))
  let cos_d = math_cos(math_asin(sin_d))

  // Hour angle for a given altitude (negative = below horizon).
  // altitude = -0.833° for geometric sunrise/sunset (accounts for refraction + disc radius).
  // altitude = -6.0°  for civil twilight.
  let hour_angle = fn(altitude_deg: Float) -> Result(Float, Nil) {
    let cos_ha =
      { math_sin(to_rad(altitude_deg)) -. math_sin(to_rad(lat)) *. sin_d }
      /. { math_cos(to_rad(lat)) *. cos_d }
    case cos_ha >. 1.0 || cos_ha <. -1.0 {
      True -> Error(Nil)
      False -> Ok(to_deg(math_acos(cos_ha)))
    }
  }

  // Convert a Julian date offset from transit to local minutes-since-midnight.
  let jd_offset_to_local_min = fn(offset_days: Float) -> Int {
    let frac = mod_f(j_transit +. offset_days -. j2000 +. 0.5, 1.0)
    let utc_min = float_round(frac *. 1440.0)
    let local_min = utc_min + float_round(utc_offset_hours *. 60.0)
    { local_min % 1440 + 1440 } % 1440
  }

  use ha_sun <- result.try(hour_angle(-0.833))
  use ha_civ <- result.try(hour_angle(-6.0))

  let sunrise_min = jd_offset_to_local_min(0.0 -. ha_sun /. 360.0)
  let sunset_min = jd_offset_to_local_min(ha_sun /. 360.0)
  let dawn_min = jd_offset_to_local_min(0.0 -. ha_civ /. 360.0)
  let dusk_min = jd_offset_to_local_min(ha_civ /. 360.0)

  Ok(SunTimes(
    civil_dawn: dawn_min,
    sunrise: sunrise_min,
    sunset: sunset_min,
    civil_dusk: dusk_min,
  ))
}

/// Modulo for floats (always returns a non-negative result).
fn mod_f(a: Float, b: Float) -> Float {
  let n = math_floor(a /. b)
  a -. b *. n
}

fn to_rad(deg: Float) -> Float {
  deg *. 0.017453292519943295
}

fn to_deg(rad: Float) -> Float {
  rad *. 57.29577951308232
}

// Math FFI (Erlang :math module)
@external(erlang, "math", "sin")
fn math_sin(x: Float) -> Float

@external(erlang, "math", "cos")
fn math_cos(x: Float) -> Float

@external(erlang, "math", "asin")
fn math_asin(x: Float) -> Float

@external(erlang, "math", "acos")
fn math_acos(x: Float) -> Float

@external(erlang, "math", "floor")
fn math_floor(x: Float) -> Float

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
