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
/// `color_for` maps calendar_name → CSS color (used for all-day events).
/// `bars_for_event` returns one (BarPos, color) pair per assigned person — used for
///   rendering event segments and travel blocks on each person's bar.
pub fn view_seven_days(
  events: List(Event),
  color_for: fn(String) -> String,
  travel_cache: Dict(String, TravelInfo),
  leg_cache: LegCache,
  home_address: String,
  bars_for_event: fn(Event) -> List(#(BarPos, String)),
) -> Element(msg) {
  let now = timestamp.system_time()
  let local_offset = calendar.local_offset()
  let today_date = timestamp.to_calendar(now, local_offset).0
  let days = next_n_dates(today_date, 7)

  // Collect per-day timed event lists (for window computation).
  // An event belongs to a day if any part of its span falls on that day:
  //   start_date <= day < end_date  (or start_date == day for same-day events).
  let day_timed_lists =
    list.map(days, fn(day) {
      list.filter(events, fn(e) {
        case e.start, e.end {
          AtTime(s), AtTime(en) -> {
            let start_date = timestamp.to_calendar(s, local_offset).0
            let end_date = timestamp.to_calendar(en, local_offset).0
            // Event overlaps `day` if start_date <= day <= end_date.
            // This correctly includes the final day of a cross-midnight event.
            date_lte(start_date, day) && date_gte(end_date, day)
          }
          _, _ -> False
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
            bars_for_event,
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
        bars_for_event,
      )
    }),
  )
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
  travel_cache: Dict(String, TravelInfo),
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

  // Hour gridlines — shared across all rows.
  let first_hour = case window.start_min % 60 {
    0 -> window.start_min / 60
    _ -> window.start_min / 60 + 1
  }
  let last_hour = window.end_min / 60
  let hour_lines =
    list.filter_map(list.range(first_hour, last_hour), fn(h) {
      let min = h * 60 - window.start_min
      case min > 0 && min < total_min {
        False -> Error(Nil)
        True ->
          Ok(
            html.div(
              [
                attribute.class(
                  "absolute top-0 bottom-0 border-l border-border/40 pointer-events-none",
                ),
                attribute.style("left", xpct(min)),
              ],
              [],
            ),
          )
      }
    })

  // Render one day row.
  let view_gantt_day = fn(
    day: Date,
    is_today: Bool,
    day_timed: List(Event),
    day_blocks: List(TravelBlock),
    all_day_events: List(Event),
  ) -> Element(msg) {
    // Build horizontal bar segments for timed events.
    // left_min = start offset from window start; width_min = duration.
    let event_bars =
      list.flat_map(day_timed, fn(e) {
        case e.start, e.end {
          AtTime(s), AtTime(en) -> {
            let #(start_date, st) = timestamp.to_calendar(s, local_offset)
            let #(end_date, et) = timestamp.to_calendar(en, local_offset)
            let start_min = case calendar.naive_date_compare(start_date, day) {
              order.Eq -> st.hours * 60 + st.minutes
              _ -> 0
            }
            let end_min = case calendar.naive_date_compare(end_date, day) {
              order.Eq -> et.hours * 60 + et.minutes
              _ -> 1440
            }
            let left_min =
              int.max(start_min, window.start_min) - window.start_min
            let right_min = int.min(end_min, window.end_min) - window.start_min
            let width_min = int.max(right_min - left_min, 1)
            let time_str =
              format_time(s, local_offset)
              <> "–"
              <> format_time(en, local_offset)
            let loc_suffix = case e.location {
              "" -> ""
              loc ->
                case dict.get(travel_cache, loc) {
                  Ok(info) -> " · " <> info.city
                  Error(_) -> ""
                }
            }
            list.map(bars_for_event(e), fn(pair) {
              let #(bar, color) = pair
              #(
                bar,
                left_min,
                width_min,
                color,
                True,
                e.summary <> loc_suffix,
                time_str,
              )
            })
          }
          _, _ -> []
        }
      })

    // Travel block bars (thin, low opacity).
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
                Ok(#(bar, left_min, width_min, color, False, travel_text, ""))
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
                  travel_text <> " home",
                  "",
                ))
            }
          }
        }
      })

    let all_bars = list.append(event_bars, travel_bars)

    // Filter bars to a specific sub-row (BarPos).
    let bars_for = fn(pos: BarPos) {
      list.filter(all_bars, fn(t) { t.0 == pos })
    }

    // Render a single sub-row of bars.
    let view_sub_row = fn(pos: BarPos, row_label: String) -> Element(msg) {
      let bars = bars_for(pos)
      let bar_els =
        list.flat_map(bars, fn(b) {
          let #(_, left_min, width_min, color, thick, label, label2) = b
          let bar_h = case thick {
            True -> "70%"
            False -> "40%"
          }
          let bar_top = case thick {
            True -> "15%"
            False -> "30%"
          }
          let opacity = case thick {
            True -> "0.85"
            False -> "0.55"
          }
          let bar_right = left_min + width_min
          // The bar strip itself.
          let strip =
            html.div(
              [
                attribute.class("absolute rounded-sm pointer-events-none"),
                attribute.style("left", xpct(left_min)),
                attribute.style("width", xfpct(int_to_float(width_min))),
                attribute.style("top", bar_top),
                attribute.style("height", bar_h),
                attribute.style("background-color", color),
                attribute.style("opacity", opacity),
              ],
              [],
            )
          // Label floats right of the bar, within the time slot to end of row.
          let label_el = case label {
            "" -> element.none()
            _ ->
              html.div(
                [
                  attribute.class(
                    "absolute top-0 bottom-0 flex flex-col justify-center overflow-hidden pointer-events-none select-none",
                  ),
                  attribute.style("left", xpct(bar_right)),
                  attribute.style("right", "0"),
                ],
                [
                  html.p(
                    [
                      attribute.class("leading-tight font-medium m-0 truncate"),
                      attribute.style("font-size", "9px"),
                      attribute.style(
                        "color",
                        "hsl(from " <> color <> " h s 30%)",
                      ),
                    ],
                    [html.text(label)],
                  ),
                  case label2 {
                    "" -> element.none()
                    t ->
                      html.p(
                        [
                          attribute.class("leading-tight m-0 truncate"),
                          attribute.style("font-size", "9px"),
                          attribute.style("color", "rgba(128,128,128,0.7)"),
                        ],
                        [html.text(t)],
                      )
                  },
                ],
              )
          }
          [strip, label_el]
        })
      // Sub-row label (person name) on the left — zero-width, doesn't affect layout.
      let row_name_el = case row_label {
        "" -> element.none()
        name ->
          html.div(
            [
              attribute.class(
                "absolute left-0 top-0 bottom-0 flex items-center pointer-events-none select-none z-10",
              ),
              attribute.style("transform", "translateX(-100%)"),
            ],
            [
              html.span(
                [
                  attribute.class("text-text-faint pr-1"),
                  attribute.style("font-size", "8px"),
                ],
                [html.text(name)],
              ),
            ],
          )
      }
      html.div(
        [
          attribute.class("relative flex-1 min-h-0"),
          ..case pos {
            BarLeft -> [attribute.class("border-b border-border/20")]
            BarCenter -> [attribute.class("border-b border-border/20")]
            BarRight -> []
          }
        ],
        list.flatten([[row_name_el], hour_lines, bar_els]),
      )
    }

    // Now indicator — vertical line at current time, only for today.
    let now_el = case is_today {
      False -> element.none()
      True -> {
        let now_offset = now_min - window.start_min
        case now_offset >= 0 && now_offset <= total_min {
          False -> element.none()
          True ->
            html.div(
              [
                attribute.class(
                  "absolute top-0 bottom-0 w-px bg-accent-border z-20 pointer-events-none",
                ),
                attribute.style("left", xpct(now_offset)),
              ],
              [],
            )
        }
      }
    }

    // All-day chips in the day header section.
    let all_day_chips =
      list.map(all_day_events, fn(e) {
        let color = color_for(e.calendar_name)
        html.span(
          [
            attribute.class(
              "inline-block px-1 rounded text-white leading-tight truncate max-w-full",
            ),
            attribute.style("font-size", "9px"),
            attribute.style("background-color", color),
          ],
          [html.text(e.summary)],
        )
      })

    let date_label =
      html.div(
        [
          attribute.class(
            "flex flex-col items-start gap-0.5 shrink-0 pr-2 select-none",
          ),
          attribute.style("width", "3.5rem"),
        ],
        [
          html.div(
            [
              attribute.class(case is_today {
                True -> "font-bold text-accent-border text-xs leading-tight"
                False -> "font-medium text-text-muted text-xs leading-tight"
              }),
            ],
            [html.text(weekday_name(day) <> " " <> format_date(day))],
          ),
          ..all_day_chips
        ],
      )

    // The time grid: relative container for hour lines, now line, and sub-rows.
    let time_grid =
      html.div(
        [
          attribute.class(
            "relative flex-1 flex flex-col min-w-0 border-l border-border/30",
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
        attribute.class(
          "flex flex-row items-stretch px-1 border-b border-border/40",
        ),
        attribute.class(case is_today {
          True -> "bg-surface-2/30"
          False -> ""
        }),
      ],
      [date_label, time_grid],
    )
  }

  // Render all 7 day rows.
  html.div(
    [attribute.class("flex-1 min-h-0 flex flex-col overflow-hidden p-2 gap-px")],
    list.map(list.zip(days, day_timed_and_blocks), fn(pair) {
      let #(day, #(day_timed, day_blocks)) = pair
      let all_day = list.filter(events, fn(e) { all_day_spans_date(e, day) })
      view_gantt_day(day, day == today_date, day_timed, day_blocks, all_day)
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
  bars_for_event: fn(Event) -> List(#(BarPos, String)),
) -> Element(msg) {
  html.div(
    [
      attribute.class(
        "flex flex-col rounded-lg overflow-hidden border-2 bg-surface",
      ),
      attribute.class(case is_today {
        True -> "border-accent-border"
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
        bars_for_event,
      ),
      view_timeline(
        timed_events,
        date,
        local_offset,
        window,
        is_today,
        travel_cache,
        day_blocks,
        bars_for_event,
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
  bars_for_event: fn(Event) -> List(#(BarPos, String)),
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
          let city_suffix = case e.location {
            "" -> ""
            loc ->
              case dict.get(travel_cache, loc) {
                Ok(info) -> " · " <> info.city
                Error(_) -> ""
              }
          }
          let bar = case bars_for_event(e) {
            [#(b, _), ..] -> b
            [] -> BarCenter
          }
          let #(text_align, border_class, border_color_prop) = case bar {
            BarLeft -> #("left", "border-l-2", "border-left-color")
            BarRight -> #("right", "border-r-2", "border-right-color")
            BarCenter -> #("center", "", "")
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
                      "flex-1 text-xs leading-none truncate p-2 rounded-lg "
                      <> border_class,
                    ),
                    attribute.style(border_color_prop, case border_color_prop {
                      "" -> ""
                      _ -> color
                    }),
                    attribute.style("background-color", bgcolor(color)),
                    attribute.style("text-align", text_align),
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
/// `col` and `col_count` are assigned after overlap detection — overlapping
/// segments within the same bar are spread into side-by-side lanes.
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
    /// Lane within this bar (0 = primary, 1 = first overlap lane, …).
    col: Int,
    /// Total number of lanes in this bar's widest overlap group.
    col_count: Int,
  )
}

/// The time-positioned portion of a day column.
/// Renders three vertical timeline bars (left/center/right).
/// Event and travel segments thicken the bar at their time slot.
/// Labels float into the center area.
/// `bars_for_event` returns one (BarPos, color) pair per assigned person.
fn view_timeline(
  events: List(Event),
  day: Date,
  local_offset: duration.Duration,
  window: Window,
  is_today: Bool,
  travel_cache: Dict(String, TravelInfo),
  travel_blocks: List(TravelBlock),
  bars_for_event: fn(Event) -> List(#(BarPos, String)),
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

  // ── Collect segments per bar ───────────────────────────────────────────────
  // Events → one segment per (bar, color) pair.
  // An event assigned to both people appears on both bars simultaneously.
  let event_segs =
    list.flat_map(events, fn(e) {
      case e.start, e.end {
        AtTime(s), AtTime(en) -> {
          let #(start_date, st) = timestamp.to_calendar(s, local_offset)
          let #(end_date, et) = timestamp.to_calendar(en, local_offset)
          // Clamp start to day boundary: if the event started on a previous day,
          // its start on this day is 0 (midnight / window start).
          let start_min = case calendar.naive_date_compare(start_date, day) {
            order.Eq -> st.hours * 60 + st.minutes
            _ -> 0
          }
          // Clamp end to day boundary: if the event ends on a later day,
          // its end on this day is 1440 (midnight of next day).
          let end_min = case calendar.naive_date_compare(end_date, day) {
            order.Eq -> et.hours * 60 + et.minutes
            _ -> 1440
          }
          let top_min = int.max(start_min, window.start_min) - window.start_min
          let bot_min = int.min(end_min, window.end_min) - window.start_min
          let dur_min = int.max(bot_min - top_min, 1)
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
          list.map(bars_for_event(e), fn(pair) {
            let #(bar, color) = pair
            #(
              bar,
              BarSegment(
                top_min:,
                dur_min:,
                color:,
                thick: True,
                label: e.summary <> loc_suffix,
                label2: time_str,
                col: 0,
                col_count: 1,
              ),
            )
          })
        }
        _, _ -> []
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
                  col: 0,
                  col_count: 1,
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
                  col: 0,
                  col_count: 1,
                ),
              ))
          }
        }
      }
    })

  let event_segs_for = fn(bar: BarPos) -> List(BarSegment) {
    list.filter_map(event_segs, fn(pair) {
      let #(b, seg) = pair
      case b == bar {
        True -> Ok(seg)
        False -> Error(Nil)
      }
    })
  }

  let travel_segs_for = fn(bar: BarPos) -> List(BarSegment) {
    list.filter_map(travel_segs, fn(pair) {
      let #(b, seg) = pair
      case b == bar {
        True -> Ok(seg)
        False -> Error(Nil)
      }
    })
  }

  // ── Lane assignment ────────────────────────────────────────────────────────
  // Event segs are packed into lanes by interval overlap or abutment.
  // Two strips abut when one ends exactly where the next begins — they get
  // separate lanes so they are visually distinct (especially same-color strips).
  // Travel segs inherit the lane of their temporally adjacent parent event:
  //   DriveFrom: travel starts where event ends  → match ev where ev.end == seg.top_min
  //   DriveTo:   travel ends where event starts   → match ev where ev.top_min == seg.end
  // Fall back to color-only match if no adjacency found.
  let assign_lanes = fn(
    event_segs: List(BarSegment),
    travel_segs: List(BarSegment),
  ) -> List(BarSegment) {
    let sorted =
      list.sort(event_segs, fn(a, b) { int.compare(a.top_min, b.top_min) })
    let #(assigned_events, lane_ends) =
      list.fold(sorted, #([], []), fn(acc, seg) {
        let #(out, lane_ends) = acc
        let end_min = seg.top_min + seg.dur_min
        let maybe_lane =
          list.fold(lane_ends, Error(Nil), fn(found, pair) {
            case found {
              Ok(_) -> found
              Error(_) -> {
                let #(lane, last_end) = pair
                // Strict < so abutting strips (last_end == seg.top_min) go to a new lane.
                case last_end < seg.top_min {
                  True -> Ok(lane)
                  False -> Error(Nil)
                }
              }
            }
          })
        case maybe_lane {
          Ok(lane) -> {
            let new_ends =
              list.map(lane_ends, fn(pair) {
                let #(l, _) = pair
                case l == lane {
                  True -> #(l, end_min)
                  False -> pair
                }
              })
            #(list.append(out, [BarSegment(..seg, col: lane)]), new_ends)
          }
          Error(_) -> {
            let lane = list.length(lane_ends)
            #(
              list.append(out, [BarSegment(..seg, col: lane)]),
              list.append(lane_ends, [#(lane, end_min)]),
            )
          }
        }
      })
    let total_lanes = int.max(list.length(lane_ends), 1)
    let assigned_events =
      list.map(assigned_events, fn(seg) {
        BarSegment(..seg, col_count: total_lanes)
      })
    // Travel segs: find the event that temporally touches this travel block.
    // A DriveFrom travel starts where its event ends; a DriveTo travel ends where its event starts.
    // We prefer adjacency match (exact touch) over color-only match so that when multiple
    // events share the same color, we pick the right one.
    let assigned_travel =
      list.map(travel_segs, fn(seg) {
        let seg_end = seg.top_min + seg.dur_min
        let col =
          list.fold(assigned_events, Error(0), fn(found, ev) {
            let ev_end = ev.top_min + ev.dur_min
            case
              // Already found an adjacent match — keep it.
              found,
              // DriveFrom: event ends exactly where travel starts.
              ev_end == seg.top_min && ev.color == seg.color,
              // DriveTo: travel ends exactly where event starts.
              ev.top_min == seg_end && ev.color == seg.color
            {
              Ok(c), _, _ -> Ok(c)
              _, True, _ -> Ok(ev.col)
              _, _, True -> Ok(ev.col)
              Error(c), False, False ->
                case ev.color == seg.color {
                  // Color-only fallback — keep updating so we get the last match,
                  // but mark as Error so a later adjacency match can override it.
                  True -> Error(ev.col)
                  False -> Error(c)
                }
            }
          })
          |> fn(r) {
            case r {
              Ok(c) -> c
              Error(c) -> c
            }
          }
        BarSegment(..seg, col:, col_count: total_lanes)
      })
    list.append(assigned_events, assigned_travel)
  }

  let left_segs =
    assign_lanes(event_segs_for(BarLeft), travel_segs_for(BarLeft))
  let right_segs =
    assign_lanes(event_segs_for(BarRight), travel_segs_for(BarRight))
  let center_segs =
    assign_lanes(event_segs_for(BarCenter), travel_segs_for(BarCenter))

  // ── Layout constants ───────────────────────────────────────────────────────
  // lane_w: strip width in px. lane_stride: px between lane anchors.
  // Left bar anchor (from left): 24px — clears the hour-label gutter.
  // Right bar anchor (from right): 8px.
  let lane_w = 12
  let lane_stride = 14
  let left_anchor_px = 24
  let right_anchor_px = 8

  // px_str: integer → "Npx"
  let px_str = fn(n: Int) -> String { int.to_string(n) <> "px" }

  // ── Render a bar + its labels ──────────────────────────────────────────────
  // `from_right`: True = bar anchored from right edge; False = from left edge.
  // `anchor_px`: px from the anchor edge to the near side of lane 0.
  // `center_bar`: True = strips use calc(50% ± offset) so the group is centered.
  // `opposing_segs`: segs from the other side bar (left→right, right→left).
  //   Used to determine per-label width: a label may extend to the full column
  //   width unless an opposing seg's time range overlaps, in which case the label
  //   is constrained to its own half so the two labels don't collide.
  // Lanes expand inward. Labels float past the group into the column center.
  let render_bar = fn(
    segs: List(BarSegment),
    from_right: Bool,
    anchor_px: Int,
    center_bar: Bool,
    opposing_segs: List(BarSegment),
  ) -> List(Element(msg)) {
    let total_lanes =
      list.fold(segs, 1, fn(acc, seg) { int.max(acc, seg.col_count) })

    let seg_els =
      list.map(segs, fn(seg) {
        let strip_w = case seg.thick {
          True -> lane_w
          False -> lane_w - 3
        }
        let opacity = case seg.thick {
          True -> "0.9"
          False -> "0.55"
        }
        // Center the strip over its lane's anchor point.
        // Lane i's center is at anchor_px + i*lane_stride from the anchor edge.
        // Strip left edge = center - strip_w/2.
        let lane_center = anchor_px + seg.col * lane_stride
        let strip_edge = lane_center - strip_w / 2
        // For center bar: mirror so the group center is at 50%.
        // Group center offset from left = total_lanes*lane_stride/2.
        // So each strip's left = calc(50% - group_half + strip_edge).
        let pos_css = case center_bar {
          True ->
            "calc(50% + "
            <> px_str(strip_edge - total_lanes * lane_stride / 2)
            <> ")"
          False -> px_str(strip_edge)
        }
        html.div(
          [
            attribute.class("absolute pointer-events-none"),
            attribute.styles([
              #(
                case from_right {
                  True -> "right"
                  False -> "left"
                },
                pos_css,
              ),
              #(
                case from_right {
                  True -> "left"
                  False -> "right"
                },
                "auto",
              ),
              #("top", pct(seg.top_min)),
              #("height", fpct(int_to_float(seg.dur_min))),
              #("width", px_str(strip_w)),
              #("background-color", seg.color),
              #("opacity", opacity),
            ]),
          ],
          [],
        )
      })

    // Labels: one absolutely-positioned flex column per bar, containing normal-flow
    // label divs. Each label gets a margin-top equal to the time gap since the
    // previous seg's top_min (as a percentage of the window). The browser handles
    // text wrapping, natural height, and stacking — no height estimation needed.
    // If a label is taller than its time gap the next label just flows down below it.
    //
    // Horizontal extent: the column runs from label_edge (past the outermost strip)
    // to the far edge by default. When an opposing-bar seg overlaps this seg's time
    // range we constrain the label to its own half so the two don't collide.
    // We test against seg.top_min..seg.top_min+seg.dur_min (the strip time range),
    // which is exact and needs no height estimate.
    let label_edge =
      anchor_px + { total_lanes - 1 } * lane_stride + lane_w / 2 + 2

    let sorted_segs =
      list.sort(segs, fn(a, b) { int.compare(a.top_min, b.top_min) })

    // Whether any opposing seg exists at all — used to constrain the label
    // column width so left and right labels don't collide in columns where
    // both bars have events.
    let has_opposing = !list.is_empty(opposing_segs)

    // Build label divs, absolutely positioned within the column.
    // Each label's top = max(seg.top_min, prev_label_bottom + gap) so labels
    // never overlap each other. We track last_bottom in minutes to nudge;
    // cap the reservation at 90min so spanning events (dur_min ~840) don't
    // push all subsequent labels off screen.
    let label_gap_min = 3
    let label_reserve = fn(seg: BarSegment) -> Int {
      int.max(int.min(seg.dur_min, 90), 12)
    }
    let label_children =
      list.fold(sorted_segs, #([], -999), fn(acc, seg) {
        let #(children, last_bottom) = acc
        case seg.label {
          "" -> #(children, last_bottom)
          _ -> {
            let top = int.max(seg.top_min, last_bottom + label_gap_min)
            let label_div =
              html.div(
                [
                  attribute.class(
                    "absolute select-none pointer-events-none min-w-0",
                  ),
                  attribute.style("top", pct(top)),
                  attribute.style("left", "0"),
                  attribute.style("right", "0"),
                ],
                [
                  html.p(
                    [
                      attribute.class("leading-tight font-medium m-0"),
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
                      html.p(
                        [
                          attribute.class("leading-tight m-0"),
                          attribute.style("font-size", "9px"),
                          attribute.style("color", "rgba(128,128,128,0.7)"),
                        ],
                        [html.text(t)],
                      )
                  },
                ],
              )
            #(list.append(children, [label_div]), top + label_reserve(seg))
          }
        }
      })
      |> fn(p) { p.0 }

    // Wrap label children in a single absolutely-positioned flex column.
    // When both bars have events (has_opposing), constrain to the near half
    // of the column so left and right labels don't overlap horizontally.
    let far_edge = case has_opposing {
      True -> "50%"
      False -> "0"
    }
    let label_col_attrs = case center_bar {
      True -> [
        attribute.style(
          "left",
          "calc(50% + " <> px_str(total_lanes * lane_stride / 2 + 2) <> ")",
        ),
        attribute.style("right", "0"),
        attribute.style("text-align", "left"),
      ]
      False ->
        case from_right {
          False -> [
            attribute.style("left", px_str(label_edge)),
            attribute.style("right", far_edge),
            attribute.style("text-align", "left"),
          ]
          True -> [
            attribute.style("left", far_edge),
            attribute.style("right", px_str(label_edge)),
            attribute.style("text-align", "right"),
          ]
        }
    }

    let label_col =
      html.div(
        [
          attribute.class(
            "absolute top-0 bottom-0 flex flex-col select-none pointer-events-none overflow-hidden",
          ),
          ..label_col_attrs
        ],
        label_children,
      )

    let label_els = [label_col]

    list.append(seg_els, label_els)
  }

  // ── Render the three bars ──────────────────────────────────────────────────
  // Pass opposing segs so each bar's labels know when to constrain their width.
  // Left labels may widen when no right-bar seg overlaps; right labels likewise.
  // Center bar has no opponent (it occupies the middle), so pass empty list.
  let left_els = render_bar(left_segs, False, left_anchor_px, False, right_segs)
  let right_els =
    render_bar(right_segs, True, right_anchor_px, False, left_segs)
  let center_els = render_bar(center_segs, False, 0, True, [])

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
