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
import icons
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/svg
import lustre/event
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
    description: String,
    url: String,
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
  on_select: fn(Event) -> msg,
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

  // Build a per-event travel-minutes lookup: event uid → #(drive_to_min, drive_from_min).
  // Computed once here so view_gantt_day can use it without re-querying the cache.
  // Drive times > 6 hours are filtered out as they're likely part of travel and not useful.
  let travel_mins_for =
    case home_address {
      "" -> fn(_uid: String) { #(0, 0) }
      addr -> {
        let lookup =
          list.filter_map(list.flatten(day_timed_lists), fn(e) {
            case e.location, e.start, e.end {
              loc, AtTime(_), AtTime(_) if loc != "" -> {
                let to_min =
                  dict.get(leg_cache, travel.leg_cache_key(addr, loc))
                  |> result.map(fn(s) { { s + 30 } / 60 })
                  |> result.unwrap(0)
                let from_min =
                  dict.get(leg_cache, travel.leg_cache_key(loc, addr))
                  |> result.map(fn(s) { { s + 30 } / 60 })
                  |> result.unwrap(0)
                // Filter out drive times > 6 hours (360 minutes)
                case to_min > 360 || from_min > 360 {
                  True -> Ok(#(e.uid, #(0, 0)))
                  False -> Ok(#(e.uid, #(to_min, from_min)))
                }
              }
              _, _, _ -> Error(Nil)
            }
          })
          |> dict.from_list
        fn(uid: String) {
          dict.get(lookup, uid) |> result.unwrap(#(0, 0))
        }
      }
    }

  let window =
    compute_window(days, day_timed_lists, travel_mins_for, local_offset)
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

  // Compute moon phase info for each day (when lat/lon are configured).
  let day_moon_info =
    list.map(days, fn(day) {
      case latitude == 0.0 && longitude == 0.0 {
        True -> Error(Nil)
        False ->
          Ok(compute_moon_info(day, latitude, longitude, utc_offset_hours))
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

  // Bar tuple: (bar, left_min, width_min, color, thick, is_free, label, label2,
  //             drive_to_min, drive_from_min, event)
  // drive_to_min/drive_from_min are 0 when no travel applies.

  // Height in px of the inverse-color tick header band at the top of each day.
  // Tall enough for pill badges (NOW, sunset time).
  let tick_header_px = 20

  // Render one day row.
  let view_gantt_day = fn(
    day: Date,
    is_today: Bool,
    day_timed: List(Event),
    all_day_events: List(Event),
    sun_times: Result(SunTimes, Nil),
    moon_info: Result(MoonInfo, Nil),
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
              // Travel applies only on the start day (DriveTo); DriveFrom
              // doesn't apply because the event doesn't end today.
              True, False -> {
                let left_min =
                  int.max(st.hours * 60 + st.minutes, window.start_min)
                  - window.start_min
                let width_min = total_min - left_min
                let #(drive_to_min, _) = travel_mins_for(e.uid)
                let new_bars =
                  list.map(bars_for_event(e), fn(pair) {
                    let #(bar, color) = pair
                    #(
                      bar,
                      left_min,
                      width_min,
                      color,
                      False,
                      e.free,
                      e.summary,
                      case is_quarter_hour(st.minutes) {
                        True -> ""
                        False -> format_time(s, local_offset) <> " →"
                      },
                      drive_to_min,
                      0,
                      e,
                    )
                  })
                #(list.append(bars_acc, new_bars), allday_acc)
              }

              // End day: event started on a previous day and ends today.
              // Travel applies only on the end day (DriveFrom); DriveTo
              // doesn't apply because the event didn't start today.
              False, True -> {
                let left_min = 0
                let right_min =
                  int.min(et.hours * 60 + et.minutes, window.end_min)
                  - window.start_min
                // If the event ends before the window opens, omit the bar
                // entirely rather than rendering a phantom 1-minute sliver.
                case right_min <= 0 {
                  True -> acc
                  False -> {
                    let width_min = right_min
                    let #(_, drive_from_min) = travel_mins_for(e.uid)
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
                          0,
                          drive_from_min,
                          e,
                        )
                      })
                    #(list.append(bars_acc, new_bars), allday_acc)
                  }
                }
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
                let #(drive_to_min, drive_from_min) = travel_mins_for(e.uid)
                let new_bars =
                  list.map(bars_for_event(e), fn(pair) {
                    let #(bar, color) = pair
                    #(
                      bar,
                      left_min,
                      width_min,
                      color,
                      False,
                      e.free,
                      e.summary,
                      time_str,
                      drive_to_min,
                      drive_from_min,
                      e,
                    )
                  })
                #(list.append(bars_acc, new_bars), allday_acc)
              }
            }
          }
          _, _ -> acc
        }
      })
    // Merge cross-midnight span events into the all-day chips list,
    // then deduplicate by UID (same event can appear from multiple sources).
    let all_day_events =
      list.append(all_day_events, extra_allday)
      |> list.fold(#([], []), fn(acc, e) {
        let #(seen_uids, deduped) = acc
        case list.contains(seen_uids, e.uid) {
          True -> acc
          False -> #([e.uid, ..seen_uids], [e, ..deduped])
        }
      })
      |> fn(pair) { list.reverse(pair.1) }

    // Fixed pixel height for every bar lane.
    let bar_px = 26

    // CSS grid column template — reuse the one built in the outer scope.
    let grid_cols = grid_cols_str

    // Render one event bar (the solid/free-line portion).
    // flex_val controls proportional width inside the travel envelope.
    let render_event_bar = fn(
      bar: #(
        BarPos,
        Int,
        Int,
        String,
        Bool,
        Bool,
        String,
        String,
        Int,
        Int,
        Event,
      ),
      flex_val: Int,
    ) -> Element(msg) {
      let #(_, left_min, width_min, color, is_xm_end, is_free, label, label2, _, _, evt) =
        bar
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
                  attribute.style("border-radius", "2px"),
                  attribute.style("padding", "1px 3px"),
                  attribute.style("white-space", "nowrap"),
                ],
                [html.text(label_text)],
              )
          }
          // Axis row layout depends on cross-midnight segment type.
          // Normal:    left_cap — line — label — line — right_cap  (centered)
          // Start-day: left_cap — label — line — right_cap         (left-aligned)
          // End-day:   label▸ — line — right_cap                   (left-aligned, tapered)
          let line_segment =
            html.div(
              [
                attribute.style("flex", "1 0 0"),
                attribute.style("height", "1.5px"),
                attribute.style("background-color", color),
                attribute.style("min-width", "4px"),
              ],
              [],
            )
          // Detect cross-midnight segment type from position data.
          let is_xm_start = left_min > 0 && right_min >= total_min
          // End-day tapered label: the label pill sits flush at the left
          // edge (no arrow cap or line fragment before it), then an SVG
          // wedge tapers smoothly from the label's full height down to the
          // 1.5px axis line.  The SVG is ~20px wide for a gradual taper.
          let tapered_label_box = case label {
            "" -> element.none()
            _ -> {
              let label_text = case label2, show_time {
                t, True if t != "" -> label <> " " <> t
                _, _ -> label
              }
              html.div(
                [
                  attribute.class(
                    "shrink-0 pointer-events-none select-none flex items-center",
                  ),
                ],
                [
                  html.span(
                    [
                      attribute.class("shrink-0 leading-none"),
                      attribute.style("font-size", "11px"),
                      attribute.style("color", "white"),
                      attribute.style("background-color", color),
                      attribute.style("border-radius", "2px 0 0 2px"),
                      attribute.style("padding", "1px 0 1px 3px"),
                      attribute.style("white-space", "nowrap"),
                    ],
                    [html.text(label_text)],
                  ),
                  // SVG taper: 13px tall to match label height.  Two
                  // straight diagonal edges slope from the label corners
                  // to a flat 1.5px tip matching the axis line width.
                  svg.svg(
                    [
                      attribute.attribute("viewBox", "0 0 60 13"),
                      attribute.attribute("width", "60"),
                      attribute.attribute("height", "13"),
                      attribute.attribute("preserveAspectRatio", "none"),
                      attribute.style("flex-shrink", "0"),
                      attribute.style("display", "block"),
                    ],
                    [
                      svg.polygon([
                        attribute.attribute(
                          "points",
                          "0,0 60,5.75 60,7.25 0,13",
                        ),
                        attribute.attribute("fill", color),
                      ]),
                    ],
                  ),
                ],
              )
            }
          }

          let axis_children = case is_xm_end, is_xm_start {
            // End-day: label flush at left edge, SVG taper, then line
            True, _ -> [tapered_label_box, line_segment, right_cap]
            // Start-day: label at left, then line to right cap
            _, True -> [left_cap, label_box, line_segment, right_cap]
            // Normal: centered label
            _, _ -> [
              left_cap, line_segment, label_box, line_segment, right_cap,
            ]
          }

          html.div(
            [
              attribute.class(
                "relative overflow-hidden select-none cursor-pointer",
              ),
              attribute.style("flex", int.to_string(flex_val) <> " 0 0"),
              attribute.style("min-width", "0"),
              attribute.style("display", "flex"),
              attribute.style("align-items", "center"),
              event.on_click(on_select(evt)),
            ],
            axis_children,
          )
        }
        // Normal (busy) events: solid filled bar with label.
        False -> {
          let is_start_day_xm = left_min > 0 && right_min >= total_min
          // Square the corner(s) that touch midnight; round the free ends.
          // Default rounded-sm = ~2px on all corners.
          let border_radius = case is_start_day_xm, is_xm_end {
            True, _ ->
              // Starts mid-day, runs off right edge to midnight: square right corners.
              "5px 0 0 5px"
            False, True ->
              // Continues from previous night, ends mid-day: square left corners.
              "0 5px 5px 0"
            False, False -> "5px"
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
            [
              attribute.class(
                "overflow-hidden flex flex-wrap items-start content-center gap-x-0.5 select-none cursor-pointer",
              ),
              attribute.style("flex", int.to_string(flex_val) <> " 0 0"),
              attribute.style("min-width", "0"),
              attribute.style("background-color", color),
              attribute.style("color", "white"),
              attribute.style("border-radius", border_radius),
              event.on_click(on_select(evt)),
            ],
            label_content,
          )
        }
      }
    }

    // Render one event bar, optionally wrapped in a travel-time envelope.
    // Travel times are carried directly on the bar tuple — no separate
    // matching step needed.
    let render_bar = fn(
      bar: #(
        BarPos,
        Int,
        Int,
        String,
        Bool,
        Bool,
        String,
        String,
        Int,
        Int,
        Event,
      ),
    ) -> Element(msg) {
      let #(_, left_min, width_min, color, _is_xm_end, _free, _label, _label2, drive_to_min, drive_from_min, _evt) =
        bar
      let g_left = int.max(left_min - drive_to_min, 0)
      let ev_right = left_min + int.min(width_min, total_min - left_min)
      let g_right = int.min(ev_right + drive_from_min, total_min)
      let col_start = int.to_string(g_left + 1)
      let col_end = int.to_string(g_right + 1)
      let has_travel = drive_to_min > 0 || drive_from_min > 0
      case has_travel {
        // Event with travel: tinted envelope wrapping the event bar.
        True -> {
          let drive_to_w = left_min - g_left
          let ev_w = ev_right - left_min
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
              [render_event_bar(bar, ev_w)],
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
              attribute.class("flex flex-row select-none rounded-sm"),
              attribute.style("grid-column", col_start <> " / " <> col_end),
              attribute.style("background-color", palette.travel_color(color)),
              attribute.style("min-width", "0"),
              attribute.style("overflow", "hidden"),
            ],
            inner_els,
          )
        }
        // No travel: just the event bar.
        False -> {
          let ev_w = int.min(width_min, total_min - left_min)
          html.div(
            [
              attribute.class("flex flex-row"),
              attribute.style("grid-column", col_start <> " / " <> col_end),
              attribute.style("min-width", "0"),
            ],
            [render_event_bar(bar, ev_w)],
          )
        }
      }
    }

    // Render one sub-row using CSS grid with auto-placement.
    let view_sub_row = fn(pos: BarPos) -> Element(msg) {
      let bars =
        list.filter(event_bars, fn(b) { b.0 == pos })
      // Empty lanes collapse to nothing; populated lanes grow to fill space.
      // Using flex: 0 0 0px (via inline style) on empty lanes avoids the
      // min-height: auto / intrinsic-grid-height problem that causes unequal
      // distribution when one lane has many stacked bars.
      let #(flex_style, border_style) = case bars {
        [] -> #("0 0 10px", "1px solid var(--color-row-border)")
        _ -> #("1 1 0%", "1px solid var(--color-row-border)")
      }
      html.div(
        [
          attribute.style("flex", flex_style),
          attribute.style("display", "grid"),
          attribute.style("grid-template-columns", grid_cols),
          attribute.style("grid-auto-flow", "dense"),
          attribute.style(
            "grid-auto-rows",
            "minmax(" <> int.to_string(bar_px) <> "px, auto)",
          ),
          attribute.style("row-gap", "2px"),
          attribute.style("border-bottom", border_style),
          attribute.style("position", "relative"),
          attribute.style("z-index", "1"),
        ],
        list.map(bars, render_bar),
      )
    }

    // Now indicator: vertical line spanning all sub-rows, positioned inside time_grid.
    let now_offset = now_min - window.start_min
    let now_in_night = case sun_times {
      Error(_) -> False
      Ok(st) -> now_min < st.civil_dawn || now_min >= st.sunset
    }
    let now_line_color = case now_in_night {
      True -> "oklch(0.85 0.15 145)"
      False -> "var(--color-accent-border)"
    }
    // NOW pill badge — rendered inside the tick header band (z-index 3, above sunset).
    let now_badge_el = case
      is_today && now_offset >= 0 && now_offset <= total_min
    {
      False -> element.none()
      True ->
        html.div(
          [
            attribute.class("pointer-events-none select-none leading-none"),
            attribute.style("position", "absolute"),
            attribute.style("left", xpct(now_offset)),
            attribute.style("top", "50%"),
            attribute.style("transform", "translate(-50%, -50%)"),
            attribute.style("z-index", "3"),
            attribute.style("font-size", "10px"),
            attribute.style("font-weight", "700"),
            attribute.style("background-color", "var(--color-now-badge-bg)"),
            attribute.style("color", "var(--color-now-badge-text)"),
            attribute.style("border-radius", "3px"),
            attribute.style("padding", "1px 4px"),
            attribute.style("white-space", "nowrap"),
            attribute.style("letter-spacing", "0.04em"),
          ],
          [html.text("NOW")],
        )
    }
    // Vertical line only — starts at top of event area (below header band).
    let now_el = case is_today && now_offset >= 0 && now_offset <= total_min {
      False -> element.none()
      True ->
        html.div(
          [
            attribute.class("absolute pointer-events-none"),
            attribute.style("left", xpct(now_offset)),
            attribute.style("top", int.to_string(tick_header_px) <> "px"),
            attribute.style("bottom", "0"),
            attribute.style("width", "2px"),
            attribute.style("transform", "translateX(-50%)"),
            attribute.style("background-color", now_line_color),
            attribute.style("opacity", "0.9"),
            attribute.style("z-index", "20"),
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
              "inline-block px-1 rounded text-white leading-tight truncate cursor-pointer",
            ),
            attribute.style("font-size", "13px"),
            attribute.style("background-color", color),
            event.on_click(on_select(e)),
          ],
          [html.text(e.summary)],
        )
      })

    // Date label + all-day chips (left gutter, 4rem wide).
    let date_label =
      html.span(
        [
          attribute.class(case is_today {
            True -> "font-bold leading-tight"
            False -> "font-medium leading-tight"
          }),
          attribute.style("font-size", "14px"),
        ],
        [html.text(weekday_name(day) <> " " <> format_date(day))],
      )

    // Sunrise/sunset rows for left gutter — icon + time on each line.
    let icon_attrs = [
      attribute.style("color", "var(--color-sun-label)"),
      attribute.style("flex-shrink", "0"),
      attribute.style("width", "12px"),
      attribute.style("height", "12px"),
      attribute.attribute("stroke-width", "2.5"),
    ]
    let sun_label_el = case sun_times {
      Error(_) -> element.none()
      Ok(st) ->
        html.div(
          [
            attribute.class("flex flex-row gap-2 select-none leading-none items-center"),
            attribute.style("font-size", "11px"),
            attribute.style("color", "var(--color-sun-label)"),
          ],
          [
            html.div([attribute.class("flex items-center gap-0.5")], [
              icons.sunrise(icon_attrs),
              html.text(format_time_min(st.sunrise)),
            ]),
            html.div([attribute.class("flex items-center gap-0.5")], [
              icons.sunset(icon_attrs),
              html.text(format_time_min(st.sunset)),
            ]),
          ],
        )
    }

    // Moon phase info for left gutter — emoji + illumination% + rise/set times.
    // Full moon gets a prominent "FULL MOON" label; other phases show concise info.
    let moon_label_el = case moon_info {
      Error(_) -> element.none()
      Ok(mi) -> {
        let illum_str =
          int.to_string(float_round(mi.illumination)) <> "%"
        let rise_set_parts = case mi.moonrise_min, mi.moonset_min {
          -1, -1 -> []
          rise, -1 -> [
            html.text("↑" <> format_time_min(rise)),
          ]
          -1, set -> [
            html.text("↓" <> format_time_min(set)),
          ]
          rise, set -> [
            html.text("↑" <> format_time_min(rise)),
            html.text(" ↓" <> format_time_min(set)),
          ]
        }
        let is_full = mi.phase_name == "Full"
        html.div(
          [
            attribute.class(
              "flex flex-row gap-1 select-none leading-none items-center",
            ),
            attribute.style("font-size", "11px"),
            attribute.style("color", "var(--color-moon-label)"),
            attribute.style("font-weight", case is_full {
              True -> "700"
              False -> "400"
            }),
          ],
          list.flatten([
            [html.text(mi.phase_emoji)],
            case is_full {
              True -> [html.text(" FULL MOON")]
              False -> [
                html.text(" " <> illum_str),
                ..rise_set_parts
              ]
            },
          ]),
        )
      }
    }

    // Left gutter: header band (matching tick band height) + date label + all-day chips.
    // Width is wider to allow chips to display more text before truncating.
    let gutter_header =
      html.div(
        [
          attribute.class("shrink-0 flex items-center px-1 select-none"),
          attribute.style("height", int.to_string(tick_header_px) <> "px"),
          attribute.style("background-color", "var(--color-tick-band-bg)"),
          attribute.style("color", "var(--color-tick-band-text)"),
        ],
        [date_label],
      )
    let left_gutter =
      html.div(
        [
          attribute.class(
            "shrink-0 flex flex-col select-none overflow-hidden",
          ),
          attribute.style("width", "11rem"),
        ],
        list.flatten([
          [gutter_header],
          [
            html.div(
              [attribute.class("flex flex-col gap-0.5 pt-0.5 pr-1")],
              list.flatten([[sun_label_el], [moon_label_el], all_day_chips]),
            ),
          ],
        ]),
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

    // Sunrise/sunset markers: dashed vertical lines in the event area only.
    // Labels are now in the header band (sunset badge) or gutter (sunrise).
    let sun_markers_el = case sun_times {
      Error(_) -> element.none()
      Ok(st) -> {
        let make_line = fn(abs_min: Int, is_rise: Bool) -> List(Element(msg)) {
          let rel = abs_min - window.start_min
          case rel > 0 && rel < total_min {
            False -> []
            True -> {
              let col = int.to_string(rel + 1)
              let color = case is_rise {
                True -> "var(--color-sun-rise-line)"
                False -> "var(--color-sun-set-line)"
              }
              [
                html.div(
                  [
                    attribute.class("pointer-events-none"),
                    attribute.style("grid-column", col),
                    attribute.style("grid-row", "2"),
                    attribute.style("align-self", "stretch"),
                    attribute.style(
                      "border-left",
                      "1px dashed " <> color,
                    ),
                  ],
                  [],
                ),
              ]
            }
          }
        }
        let lines =
          list.flatten([
            make_line(st.sunrise, True),
            make_line(st.sunset, False),
          ])
        case lines {
          [] -> element.none()
          _ ->
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
              lines,
            )
        }
      }
    }

    // Per-day gridline generation. Lines only span row 2 (event area) so they
    // don't cut through the tick header band (which has its own background).
    // Lines in the event area are still night-aware for readability.
    let is_night_min = fn(abs_min: Int) -> Bool {
      case sun_times {
        Error(_) -> False
        Ok(st) -> abs_min < st.civil_dawn || abs_min >= st.sunset
      }
    }
    // Gridlines: theme-aware via CSS vars. Night zone gets stronger lines.
    let qline_day = "var(--color-gridline-q)"
    let qline_night = "var(--color-gridline-q-n)"
    let hline_day = "var(--color-gridline-h)"
    let hline_night = "var(--color-gridline-h-n)"

    let first_hour = case window.start_min % 60 {
      0 -> window.start_min / 60
      _ -> window.start_min / 60 + 1
    }
    let last_hour = window.end_min / 60

    // Gridlines span only the event area (grid-row 2), not the header band.
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
                      attribute.style("grid-row", "2"),
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
                    attribute.style("grid-row", "2"),
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

    // Lines overlay: z-index 0, behind event bars (z-index 1).
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

    // Tick header band background and hour labels.
    // The band is a dark inverse-color strip; labels are light, centered over
    // their respective gridline column via translateX(-50%).
    let tick_band_bg = "var(--color-tick-band-bg)"
    let tick_label_color = "var(--color-tick-band-text)"

    let tick_header_labels =
      list.flatten([
        // Mid-window hour labels: centered over the gridline.
        list.filter_map(int_range(first_hour, last_hour), fn(h) {
          let min = h * 60 - window.start_min
          case min > 0 && min < total_min {
            False -> Error(Nil)
            True ->
              Ok(
                html.span(
                  [
                    attribute.class(
                      "pointer-events-none select-none leading-none",
                    ),
                    attribute.style("position", "absolute"),
                    attribute.style(
                      "left",
                      float_pct(int_to_float(min) /. total_f *. 100.0),
                    ),
                    attribute.style("top", "50%"),
                    attribute.style("transform", "translate(-50%, -50%)"),
                    attribute.style("font-size", "11px"),
                    attribute.style("color", tick_label_color),
                    attribute.style("white-space", "nowrap"),
                  ],
                  [html.text(format_hour(h))],
                ),
              )
          }
        }),
        // First-hour label: left-aligned at the start edge.
        case window.start_min % 60 {
          0 -> {
            let h = window.start_min / 60
            [
              html.span(
                [
                  attribute.class(
                    "pointer-events-none select-none leading-none",
                  ),
                  attribute.style("position", "absolute"),
                  attribute.style("left", "2px"),
                  attribute.style("top", "50%"),
                  attribute.style("transform", "translateY(-50%)"),
                  attribute.style("font-size", "11px"),
                  attribute.style("color", tick_label_color),
                  attribute.style("white-space", "nowrap"),
                ],
                [html.text(format_hour(h))],
              ),
            ]
          }
          _ -> []
        },
      ])

    // Sunset badge — pill with dark-warm bg, rendered in header band.
    let sunset_badge_el = case sun_times {
      Error(_) -> element.none()
      Ok(st) -> {
        let rel = st.sunset - window.start_min
        case rel > 0 && rel < total_min {
          False -> element.none()
          True ->
            html.div(
              [
                attribute.class("pointer-events-none select-none leading-none"),
                attribute.style("position", "absolute"),
                attribute.style(
                  "left",
                  float_pct(int_to_float(rel) /. total_f *. 100.0),
                ),
                attribute.style("top", "50%"),
                attribute.style("transform", "translate(-50%, -50%)"),
                attribute.style("z-index", "2"),
                attribute.style("font-size", "10px"),
                attribute.style("background-color", "oklch(0.38 0.09 55)"),
                attribute.style("color", "oklch(0.92 0.06 70)"),
                attribute.style("border-radius", "3px"),
                attribute.style("padding", "1px 4px"),
                attribute.style("white-space", "nowrap"),
                attribute.style("display", "flex"),
                attribute.style("align-items", "center"),
                attribute.style("gap", "2px"),
              ],
              [
                icons.sunset([
                  attribute.style("width", "10px"),
                  attribute.style("height", "10px"),
                  attribute.attribute("stroke-width", "2.5"),
                  attribute.style("flex-shrink", "0"),
                ]),
                html.text(format_time_min(st.sunset)),
              ],
            )
        }
      }
    }

    // Time grid: sub-rows fill vertical space equally via flex-1.
    // Hour ticks and now-indicator are absolute overlays inside time_grid.
    let time_grid =
      html.div(
        [
          attribute.class(
            "relative flex-1 flex flex-col min-w-0 overflow-hidden",
          ),
          attribute.style("border-left", "1px solid var(--color-gridline-edge)"),
        ],
        list.flatten([
          // Now indicator — absolute, spans full height.
          [now_el],
          // Content wrapper: overlay (gridlines+labels) is absolute inside here.
          // A flow spacer reserves the tick label row height at the top so
          // sub-rows start below the label strip without a separate tick element.
          [
            html.div(
              [attribute.class("relative isolate flex-1 flex flex-col min-w-0")],
              list.flatten([
                // Day/night gradient (behind everything, absolute).
                [sun_gradient_el],
                // Gridlines behind event bars (z-index 0, absolute).
                [grid_line_overlay],
                // Sunrise/sunset markers overlay (absolute).
                [sun_markers_el],
                // Tick header band: dark bg, hour labels, sunset badge.
                // Flow element — reserves height and sits above sub-rows.
                // NOW badge is injected here too.
                [
                  {
                    // Inject NOW badge into the band's children list.
                    let band_children =
                      list.flatten([
                        tick_header_labels,
                        [sunset_badge_el],
                        [now_badge_el],
                      ])
                    html.div(
                      [
                        attribute.class(
                          "shrink-0 relative pointer-events-none overflow-hidden",
                        ),
                        attribute.style(
                          "height",
                          int.to_string(tick_header_px) <> "px",
                        ),
                        attribute.style("background-color", tick_band_bg),
                        attribute.style("z-index", "3"),
                      ],
                      band_children,
                    )
                  },
                ],
                // Event sub-rows (z-index 1, above gridlines).
                [
                  view_sub_row(BarLeft),
                  view_sub_row(BarCenter),
                  view_sub_row(BarRight),
                ],
              ]),
            ),
          ],
        ]),
      )

    html.div(
      [
        attribute.class("flex flex-row flex-1"),
        attribute.class(case is_today {
          True -> "bg-surface-2/40"
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
          list.zip(
            days,
            list.zip(
              day_timed_lists,
              list.zip(day_sun_times, day_moon_info),
            ),
          ),
          fn(pair) {
            let #(day, #(day_timed, #(sun_times, moon_info))) = pair
            let all_day =
              list.filter(events, fn(e) { all_day_spans_date(e, day) })
            view_gantt_day(
              day,
              day == today_date,
              day_timed,
              all_day,
              sun_times,
              moon_info,
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
  days: List(Date),
  day_timed_lists: List(List(Event)),
  travel_mins_for: fn(String) -> #(Int, Int),
  local_offset: duration.Duration,
) -> Window {
  let timed_events = list.flatten(day_timed_lists)

  case timed_events {
    [] -> Window(default_window_start_min, default_window_end_min)
    _ -> {
      // Walk each (day, events) pair so we can compute per-day window bounds
      // correctly.  For a cross-midnight event appearing as an end fragment on
      // a given day its visible portion starts at midnight (0 min), not at the
      // event's actual start time (which was the previous night).  Using the
      // raw start timestamp for such events would never push the window start
      // earlier than the default 7am, causing the end fragment to be clipped.
      let #(start_mins, end_mins) =
        list.zip(days, day_timed_lists)
        |> list.fold(#([], []), fn(acc, pair) {
          let #(starts, ends) = acc
          let #(day, day_events) = pair
          list.fold(day_events, #(starts, ends), fn(acc2, e) {
            let #(starts2, ends2) = acc2
            case e.start, e.end {
              AtTime(ts), AtTime(te) -> {
                let #(start_date, t_start) =
                  timestamp.to_calendar(ts, local_offset)
                let #(end_date, t_end) =
                  timestamp.to_calendar(te, local_offset)
                let is_start_day =
                  calendar.naive_date_compare(start_date, day) == order.Eq
                let is_end_day =
                  calendar.naive_date_compare(end_date, day) == order.Eq
                // For the end-day of a cross-midnight event the visible
                // portion starts at midnight (0), not the actual start time
                // (previous night).
                let start_min = case is_start_day {
                  True -> t_start.hours * 60 + t_start.minutes
                  False -> 0
                }
                // For the start-day of a cross-midnight event the event runs
                // off the right edge of this row (to midnight = 1440).  Using
                // the raw end timestamp gives a small number like 90 (1:30am)
                // which would never expand the window rightward.
                let end_min = case is_end_day {
                  True -> t_end.hours * 60 + t_end.minutes
                  False -> 1440
                }
                let #(drive_to_min, drive_from_min) = travel_mins_for(e.uid)
                // drive_to only applies on the start day; drive_from only on
                // the end day.
                let adjusted_start = case is_start_day {
                  True -> start_min - drive_to_min
                  False -> start_min
                }
                let adjusted_end = case is_end_day {
                  True -> end_min + drive_from_min
                  False -> end_min
                }
                #(
                  [adjusted_start, ..starts2],
                  [adjusted_end, ..ends2],
                )
              }
              AtTime(ts), _ -> {
                let #(_, t) = timestamp.to_calendar(ts, local_offset)
                #([t.hours * 60 + t.minutes, ..starts2], ends2)
              }
              _, AtTime(te) -> {
                let #(_, t) = timestamp.to_calendar(te, local_offset)
                #(starts2, [t.hours * 60 + t.minutes, ..ends2])
              }
              _, _ -> acc2
            }
          })
        })

      let earliest =
        list.fold(start_mins, default_window_start_min, int.min)
      let latest =
        list.fold(end_mins, default_window_end_min, int.max)

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

// MOON PHASE CALCULATION ------------------------------------------------------

/// Moon data for a given day: illumination, phase emoji, moonrise/moonset times.
pub type MoonInfo {
  MoonInfo(
    /// Illumination percentage (0.0 = new moon, 100.0 = full moon).
    illumination: Float,
    /// Unicode emoji for the current phase.
    phase_emoji: String,
    /// Short phase name (e.g. "Full", "Waxing Gibbous").
    phase_name: String,
    /// Moonrise in minutes since midnight (local time), or -1 if none.
    moonrise_min: Int,
    /// Moonset in minutes since midnight (local time), or -1 if none.
    moonset_min: Int,
  )
}

/// Compute moon phase info for a given date and location.
/// The illumination and phase are location-independent.
/// Moonrise/moonset times depend on latitude, longitude, and UTC offset.
pub fn compute_moon_info(
  date: Date,
  lat: Float,
  lon: Float,
  utc_offset_hours: Float,
) -> MoonInfo {
  let year = date.year
  let month = calendar.month_to_int(date.month)
  let day = date.day

  // Julian date (same formula as in compute_sun_times).
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

  // Days since J2000.0 epoch (2000-01-12 12:00 TT).
  let d = jd -. 2_451_545.0

  // --- Moon illumination and phase from synodic cycle ---
  // Known new moon: January 6, 2000 18:14 UTC ≈ JD 2451550.26
  let known_new_moon_jd = 2_451_550.26
  let synodic_month = 29.53059
  let days_since_new = mod_f(jd -. known_new_moon_jd, synodic_month)
  let phase_fraction = days_since_new /. synodic_month
  // Illumination: 0 at new, 1 at full, using cosine curve
  let illumination =
    { 1.0 -. math_cos(phase_fraction *. 2.0 *. pi) } /. 2.0 *. 100.0

  // Phase name and emoji from the phase fraction (0.0 = new moon, 0.5 = full moon)
  let #(phase_name, phase_emoji) = phase_name_and_emoji(phase_fraction)

  // --- Moonrise / Moonset calculation ---
  // Low-precision lunar position (Meeus, Astronomical Algorithms, Ch. 47 simplified)
  let #(moonrise_min, moonset_min) =
    compute_moonrise_moonset(d, lat, lon, utc_offset_hours)

  MoonInfo(
    illumination:,
    phase_emoji:,
    phase_name:,
    moonrise_min:,
    moonset_min:,
  )
}

/// Map phase fraction (0..1) to name and emoji.
/// 0.0 = new moon, ~0.25 = first quarter, ~0.5 = full, ~0.75 = last quarter
fn phase_name_and_emoji(f: Float) -> #(String, String) {
  case True {
    _ if f <. 0.0125 -> #("New", "🌑")
    _ if f <. 0.235 -> #("Wax Crescent", "🌒")
    _ if f <. 0.265 -> #("First Quarter", "🌓")
    _ if f <. 0.485 -> #("Wax Gibbous", "🌔")
    _ if f <. 0.515 -> #("Full", "🌕")
    _ if f <. 0.735 -> #("Wan Gibbous", "🌖")
    _ if f <. 0.765 -> #("Last Quarter", "🌗")
    _ if f <. 0.9875 -> #("Wan Crescent", "🌘")
    _ -> #("New", "🌑")
  }
}

/// Compute moonrise and moonset times for a given day.
/// Uses low-precision lunar position to find the moon's RA/Dec,
/// then computes rise/set hour angles. Returns minutes-since-midnight
/// for each, or -1 if the moon doesn't rise or set on that day.
fn compute_moonrise_moonset(
  d: Float,
  lat: Float,
  lon: Float,
  utc_offset_hours: Float,
) -> #(Int, Int) {
  // Low-precision lunar ecliptic coordinates (Meeus simplified).
  // Mean elements of the lunar orbit.
  let l0 = mod_f(218.3165 +. 13.176396 *. d, 360.0)
  // Mean longitude
  let m_moon = mod_f(134.9634 +. 13.064993 *. d, 360.0)
  // Moon's mean anomaly
  let m_sun = mod_f(357.5291 +. 0.985600 *. d, 360.0)
  // Sun's mean anomaly
  let f = mod_f(93.2720 +. 13.229350 *. d, 360.0)
  // Moon's argument of latitude
  let d_moon = mod_f(297.8502 +. 12.190749 *. d, 360.0)
  // Mean elongation

  // Ecliptic longitude (degrees).
  let ecl_lon =
    l0
    +. 6.289 *. math_sin(to_rad(m_moon))
    -. 1.274 *. math_sin(to_rad(2.0 *. d_moon -. m_moon))
    +. 0.658 *. math_sin(to_rad(2.0 *. d_moon))
    +. 0.214 *. math_sin(to_rad(2.0 *. m_moon))
    -. 0.186 *. math_sin(to_rad(m_sun))
    -. 0.114 *. math_sin(to_rad(2.0 *. f))

  // Ecliptic latitude (degrees).
  let ecl_lat =
    5.128 *. math_sin(to_rad(f))
    +. 0.281 *. math_sin(to_rad(m_moon +. f))
    +. 0.078 *. math_sin(to_rad(2.0 *. d_moon -. f))

  // Obliquity of the ecliptic.
  let obliquity = 23.4393 -. 3.563e-7 *. d

  // Convert ecliptic to equatorial (RA, Dec).
  let sin_lon = math_sin(to_rad(ecl_lon))
  let cos_lon = math_cos(to_rad(ecl_lon))
  let sin_lat = math_sin(to_rad(ecl_lat))
  let cos_lat = math_cos(to_rad(ecl_lat))
  let sin_obl = math_sin(to_rad(obliquity))
  let cos_obl = math_cos(to_rad(obliquity))

  let ra_rad =
    math_atan2(sin_lon *. cos_obl -. sin_lat /. cos_lat *. sin_obl, cos_lon)
  let ra_deg = mod_f(to_deg(ra_rad), 360.0)

  let sin_dec = sin_lat *. cos_obl +. cos_lat *. sin_obl *. sin_lon
  let dec_rad = math_asin(sin_dec)

  // Greenwich Mean Sidereal Time at 0h UT for this day.
  let gmst0 = mod_f(280.46061837 +. 360.98564736629 *. d, 360.0)

  // Local Sidereal Time at 0h local time.
  let lst0 = mod_f(gmst0 +. lon -. utc_offset_hours *. 15.0, 360.0)

  // Hour angle at transit (when moon crosses the meridian).
  let ha_transit = mod_f(ra_deg -. lst0 +. 360.0, 360.0)
  let transit_hours = ha_transit /. 15.0

  // Hour angle for moonrise/moonset: altitude = -0.833° (same correction as sun,
  // though for the moon the parallax makes it closer to +0.125°; we use -0.833°
  // which is standard for a point source — close enough for a display).
  // Using +0.125° accounts for typical horizontal parallax minus refraction.
  let alt = 0.125
  let cos_ha =
    { math_sin(to_rad(alt)) -. math_sin(to_rad(lat)) *. sin_dec }
    /. { math_cos(to_rad(lat)) *. math_cos(dec_rad) }

  case cos_ha >. 1.0 || cos_ha <. -1.0 {
    // Moon doesn't rise or set (circumpolar or never above horizon).
    True -> #(-1, -1)
    False -> {
      let ha_deg = to_deg(math_acos(cos_ha))
      let ha_hours = ha_deg /. 15.0

      let rise_hours = transit_hours -. ha_hours
      let set_hours = transit_hours +. ha_hours

      let rise_min = float_round(mod_f(rise_hours *. 60.0, 1440.0))
      let set_min = float_round(mod_f(set_hours *. 60.0, 1440.0))

      #(rise_min, set_min)
    }
  }
}

const pi = 3.141592653589793

@external(erlang, "math", "atan2")
fn math_atan2(y: Float, x: Float) -> Float

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

// EVENT DETAIL MODAL ----------------------------------------------------------

/// Floating detail panel for a selected event.
/// Clicking the backdrop (outside the panel) fires `on_dismiss`.
pub fn view_event_detail(
  e: Event,
  travel_cache: Dict(String, TravelInfo),
  leg_cache: LegCache,
  home_address: String,
  on_dismiss: msg,
) -> Element(msg) {
  let local_offset = calendar.local_offset()

  // Format the date/time string.
  let time_str = case e.start, e.end {
    AllDay(s), AllDay(en) -> {
      let s_str = weekday_name(s) <> " " <> format_date(s)
      let end_inclusive = date_offset_by(en, -1)
      case s == end_inclusive {
        True -> s_str
        False -> s_str <> " – " <> weekday_name(end_inclusive) <> " " <> format_date(end_inclusive)
      }
    }
    AtTime(s), AtTime(en) -> {
      let #(s_date, _) = timestamp.to_calendar(s, local_offset)
      let #(en_date, _) = timestamp.to_calendar(en, local_offset)
      let start_str =
        weekday_name(s_date)
        <> " "
        <> format_date(s_date)
        <> " "
        <> format_time(s, local_offset)
      case s_date == en_date {
        True -> start_str <> " – " <> format_time(en, local_offset)
        False ->
          start_str
          <> " – "
          <> weekday_name(en_date)
          <> " "
          <> format_date(en_date)
          <> " "
          <> format_time(en, local_offset)
      }
    }
    AtTime(s), AllDay(_) -> {
      let #(s_date, _) = timestamp.to_calendar(s, local_offset)
      weekday_name(s_date) <> " " <> format_date(s_date) <> " " <> format_time(s, local_offset) <> " →"
    }
    AllDay(s), AtTime(en) -> {
      let #(en_date, _) = timestamp.to_calendar(en, local_offset)
      weekday_name(s) <> " " <> format_date(s) <> " – " <> weekday_name(en_date) <> " " <> format_date(en_date) <> " " <> format_time(en, local_offset)
    }
  }

  // Travel info from home to the event location.
  // Hide drive times > 6 hours as they're likely part of travel and not useful.
  let travel_row = case e.location {
    "" -> element.none()
    loc -> {
      let info = dict.get(travel_cache, loc)
      let leg_secs =
        dict.get(leg_cache, travel.leg_cache_key(home_address, loc))
        |> result.or(dict.get(leg_cache, travel.leg_cache_key(loc, home_address)))
      let travel_detail = case info, leg_secs {
        Ok(ti), _ ->
          case ti.duration_secs > 21_600 {
            True -> ""
            False ->
              ti.duration_text <> " · " <> ti.distance_text <> " from home"
          }
        Error(_), Ok(secs) ->
          case secs > 21_600 {
            True -> ""
            False -> secs_to_min_text(secs) <> " min from home"
          }
        Error(_), Error(_) -> ""
      }
      html.div(
        [attribute.class("flex flex-col gap-0.5")],
        list.flatten([
          [detail_row("📍", loc)],
          case travel_detail {
            "" -> []
            t -> [detail_row("🚗", t)]
          },
        ]),
      )
    }
  }

  let free_row = case e.free {
    True -> detail_row("○", "Free / transparent")
    False -> element.none()
  }

  let description_rows = case e.description {
    "" -> []
    d ->
      string.split(d, "\\n")
      |> list.map(fn(line) {
        html.p(
          [
            attribute.class("text-sm text-text leading-tight"),
            attribute.style("white-space", "pre-wrap"),
            attribute.style("word-break", "break-word"),
          ],
          [html.text(line)],
        )
      })
  }

  let url_row = case e.url {
    "" -> element.none()
    u ->
      html.a(
        [
          attribute.class("text-sm text-accent underline break-all"),
          attribute.attribute("href", u),
          attribute.attribute("target", "_blank"),
          attribute.attribute("rel", "noopener noreferrer"),
        ],
        [html.text(u)],
      )
  }

  let panel_children =
    list.flatten([
      // Close button
      [
        html.button(
          [
            attribute.class(
              "absolute top-2 right-2 text-text-muted hover:text-text leading-none",
            ),
            attribute.style("font-size", "18px"),
            attribute.style("background", "none"),
            attribute.style("border", "none"),
            attribute.style("cursor", "pointer"),
            attribute.style("padding", "4px 8px"),
            event.on_click(on_dismiss),
          ],
          [html.text("×")],
        ),
      ],
      // Title
      [
        html.h2(
          [
            attribute.class("font-semibold text-text leading-tight pr-6"),
            attribute.style("font-size", "16px"),
          ],
          [html.text(e.summary)],
        ),
      ],
      // Calendar name
      [detail_row("📅", e.calendar_name)],
      // Date/time
      [detail_row("🕐", time_str)],
      // Location + travel
      [travel_row],
      // Free/busy
      [free_row],
      // Description
      case description_rows {
        [] -> []
        rows -> [
          html.div(
            [attribute.class("flex flex-col gap-1 pt-1 border-t border-border")],
            rows,
          ),
        ]
      },
      // URL
      case e.url {
        "" -> []
        _ -> [url_row]
      },
    ])

  // Two siblings inside a fixed wrapper:
  //   1. A full-screen backdrop that dismisses on click.
  //   2. The panel centered via absolute positioning, above the backdrop.
  // The panel does NOT get a click handler so clicks on it don't bubble to
  // the backdrop — they stop at the wrapper which has pointer-events:none
  // except on the backdrop child.
  html.div(
    [
      attribute.class("fixed inset-0"),
      attribute.style("z-index", "40"),
    ],
    [
      // Backdrop layer
      html.div(
        [
          attribute.class("absolute inset-0"),
          attribute.style("background-color", "rgba(0,0,0,0.5)"),
          event.on_click(on_dismiss),
        ],
        [],
      ),
      // Panel layer — centered, above backdrop
      html.div(
        [
          attribute.class("absolute inset-0 flex items-center justify-center"),
          attribute.style("pointer-events", "none"),
        ],
        [
          html.div(
            [
              attribute.class(
                "relative bg-surface rounded-lg p-4 flex flex-col gap-2 overflow-y-auto",
              ),
              attribute.style("max-width", "min(480px, calc(100vw - 2rem))"),
              attribute.style("max-height", "calc(100vh - 4rem)"),
              attribute.style("box-shadow", "0 8px 32px rgba(0,0,0,0.6)"),
              attribute.style("pointer-events", "auto"),
            ],
            panel_children,
          ),
        ],
      ),
    ],
  )
}

fn detail_row(icon: String, text: String) -> Element(msg) {
  html.div(
    [attribute.class("flex flex-row gap-2 items-baseline")],
    [
      html.span(
        [attribute.class("shrink-0 text-text-muted"), attribute.style("font-size", "12px")],
        [html.text(icon)],
      ),
      html.span(
        [attribute.class("text-sm text-text"), attribute.style("word-break", "break-word")],
        [html.text(text)],
      ),
    ],
  )
}

fn date_offset_by(date: Date, n: Int) -> Date {
  case n {
    0 -> date
    _ if n > 0 -> date_offset_by(advance_date(date), n - 1)
    _ -> date_offset_by(retreat_date(date), n + 1)
  }
}

fn retreat_date(date: Date) -> Date {
  case date.day > 1 {
    True -> Date(..date, day: date.day - 1)
    False -> {
      let pm = prev_month(date.month)
      let py = case date.month {
        calendar.January -> date.year - 1
        _ -> date.year
      }
      Date(year: py, month: pm, day: days_in_month(pm, py))
    }
  }
}

fn prev_month(m: calendar.Month) -> calendar.Month {
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
