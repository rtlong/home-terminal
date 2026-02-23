// IMPORTS ---------------------------------------------------------------------

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
  )
}

// LAYOUT CONSTANTS ------------------------------------------------------------

/// Pixels per minute on the timeline.
const px_per_min = 1.5

/// Default visible window: 7:00 am.
const default_window_start_min = 420

/// Default visible window: 9:00 pm.
const default_window_end_min = 1260

/// Minimum event block height in pixels (so tiny events are still clickable).
const min_event_height_px = 18

/// Width of the hour-label gutter on the left of each day column.
const gutter_px = 32

// VIEW ------------------------------------------------------------------------

/// Rendered while calendar_server has not yet delivered its first fetch.
pub fn view_loading() -> Element(msg) {
  html.p([attribute.class("p-4 text-gray-500 italic text-sm")], [
    html.text("Loading calendar…"),
  ])
}

/// Rendered when the CalDAV fetch failed.
pub fn view_error(reason: String) -> Element(msg) {
  html.p([attribute.class("p-4 text-red-400 text-sm")], [
    html.text("Calendar error: " <> reason),
  ])
}

/// The main 7-day view. Shows events for today and the next 6 days.
/// All columns share the same time window so timelines are aligned.
/// `color_for` is a fn(calendar_name) -> css_color_string for per-cal coloring.
pub fn view_seven_days(
  events: List(Event),
  color_for: fn(String) -> String,
) -> Element(msg) {
  let now = timestamp.system_time()
  let local_offset = calendar.local_offset()
  let today_date = timestamp.to_calendar(now, local_offset).0
  let days = next_n_dates(today_date, 7)

  // Collect per-day event lists once so we can inspect them for layout.
  let day_event_lists =
    list.map(days, fn(day) { events_on_date(events, day, local_offset) })

  // Shared time window: start = min of all event starts (floor to hour),
  // end = max of all event ends (ceil to hour), clamped to defaults.
  let window = compute_window(day_event_lists, local_offset)

  // How many all-day rows does the busiest day need?  All columns reserve
  // the same number of rows so the timelines start at the same vertical offset.
  let max_all_day =
    list.fold(day_event_lists, 0, fn(acc, day_evts) {
      let n =
        list.count(day_evts, fn(e) {
          case e.start {
            AllDay(_) -> True
            AtTime(_) -> False
          }
        })
      int.max(acc, n)
    })

  html.div(
    [
      attribute.class(
        "flex-1 grid grid-cols-7 gap-px p-2 overflow-y-auto bg-gray-900",
      ),
    ],
    list.map2(days, day_event_lists, fn(day, day_evts) {
      view_day(
        day,
        day == today_date,
        day_evts,
        local_offset,
        window,
        max_all_day,
        color_for,
      )
    }),
  )
}

// TIME WINDOW -----------------------------------------------------------------

/// Minutes-since-midnight window shared across all day columns.
type Window {
  Window(start_min: Int, end_min: Int)
}

/// Compute the shared time window from all events across all days.
/// Snaps to hour boundaries; applies default min/max clamps.
fn compute_window(
  day_event_lists: List(List(Event)),
  local_offset: duration.Duration,
) -> Window {
  let timed_events =
    list.flatten(day_event_lists)
    |> list.filter(fn(e) {
      case e.start {
        AtTime(_) -> True
        AllDay(_) -> False
      }
    })

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

      // Snap earliest down to the hour, latest up to the hour.
      let snapped_start = earliest / 60 * 60
      let snapped_end = case latest % 60 {
        0 -> latest
        _ -> { latest / 60 + 1 } * 60
      }

      // Apply min/max defaults.
      Window(
        start_min: int.min(snapped_start, default_window_start_min),
        end_min: int.max(snapped_end, default_window_end_min),
      )
    }
  }
}

// DAY VIEW --------------------------------------------------------------------

fn view_day(
  date: Date,
  is_today: Bool,
  day_events: List(Event),
  local_offset: duration.Duration,
  window: Window,
  max_all_day: Int,
  color_for: fn(String) -> String,
) -> Element(msg) {
  let all_day_events =
    list.filter(day_events, fn(e) {
      case e.start {
        AllDay(_) -> True
        AtTime(_) -> False
      }
    })
  let timed_events =
    list.filter(day_events, fn(e) {
      case e.start {
        AtTime(_) -> True
        AllDay(_) -> False
      }
    })

  let header_bg = case is_today {
    True -> "bg-gray-800 border-b border-emerald-800"
    False -> "bg-gray-900 border-b border-gray-800"
  }
  let weekday_cls = case is_today {
    True -> "text-xs font-semibold uppercase tracking-wide text-emerald-400"
    False -> "text-xs font-semibold uppercase tracking-wide text-gray-500"
  }
  let date_cls = case is_today {
    True -> "text-xs text-emerald-600"
    False -> "text-xs text-gray-600"
  }
  let col_border = case is_today {
    True -> "border border-gray-700 bg-gray-900"
    False -> "border border-gray-800"
  }

  html.div(
    [attribute.class("flex flex-col rounded-lg overflow-hidden " <> col_border)],
    [
      // Date header
      html.div(
        [
          attribute.class(
            "flex items-baseline gap-2 px-2 py-1.5 shrink-0 " <> header_bg,
          ),
        ],
        [
          html.span([attribute.class(weekday_cls)], [
            html.text(weekday_name(date)),
          ]),
          html.span([attribute.class(date_cls)], [html.text(format_date(date))]),
        ],
      ),
      // All-day event rows (fixed count = max_all_day so timelines align)
      view_all_day_strip(all_day_events, max_all_day, color_for),
      // Scrollable timeline
      view_timeline(timed_events, local_offset, window, is_today, color_for),
    ],
  )
}

// ALL-DAY STRIP ---------------------------------------------------------------

/// Each all-day event gets its own fixed-height row. Empty rows are rendered
/// as spacers so all day columns have the same height for this section.
fn view_all_day_strip(
  events: List(Event),
  max_rows: Int,
  color_for: fn(String) -> String,
) -> Element(msg) {
  // Each row is 20px tall.
  let row_h = 20
  let strip_h = max_rows * row_h

  let event_els =
    list.index_map(events, fn(e, i) {
      let color = color_for(e.calendar_name)
      html.div(
        [
          attribute.class(
            "absolute left-0 right-0 flex items-center px-1 overflow-hidden",
          ),
          attribute.styles([
            #("top", px(i * row_h)),
            #("height", px(row_h - 1)),
          ]),
        ],
        [
          html.div(
            [
              attribute.class(
                "flex-1 text-xs leading-none truncate border-l-2 pl-1 rounded-sm",
              ),
              attribute.style("border-left-color", color),
            ],
            [html.text(e.summary)],
          ),
        ],
      )
    })

  html.div(
    [
      attribute.class("relative shrink-0 border-b border-gray-800"),
      attribute.style("height", px(strip_h)),
    ],
    event_els,
  )
}

// TIMELINE --------------------------------------------------------------------

/// The time-positioned portion of a day column.
fn view_timeline(
  events: List(Event),
  local_offset: duration.Duration,
  window: Window,
  is_today: Bool,
  color_for: fn(String) -> String,
) -> Element(msg) {
  let total_min = window.end_min - window.start_min
  let total_h = float_px(int_to_float(total_min) *. px_per_min)

  // Build hour marks from first full hour inside window to last.
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
      let top = float_px(int_to_float(top_min) *. px_per_min)
      let half_top_min = top_min + 30
      let half_top = float_px(int_to_float(half_top_min) *. px_per_min)
      let show_half = h * 60 + 30 < window.end_min

      let hour_line =
        html.div(
          [
            attribute.class("absolute left-0 right-0 flex items-center"),
            attribute.style("top", top),
          ],
          [
            // Hour label
            html.span(
              [
                attribute.class(
                  "text-gray-600 text-xs leading-none select-none shrink-0",
                ),
                attribute.style("width", px(gutter_px)),
                attribute.style("font-size", "9px"),
              ],
              [html.text(format_hour(h))],
            ),
            // Solid hour line
            html.div([attribute.class("flex-1 border-t border-gray-800")], []),
          ],
        )

      let half_line = case show_half {
        False -> []
        True -> [
          html.div(
            [
              attribute.class(
                "absolute right-0 border-t border-dashed border-gray-900",
              ),
              attribute.styles([
                #("top", half_top),
                #("left", px(gutter_px)),
              ]),
            ],
            [],
          ),
        ]
      }

      [hour_line, ..half_line]
    })

  // Now-line: only shown for today.
  let now_line = case is_today {
    False -> []
    True -> {
      let now = timestamp.system_time()
      let #(_, t) = timestamp.to_calendar(now, local_offset)
      let now_min = t.hours * 60 + t.minutes
      case now_min >= window.start_min && now_min <= window.end_min {
        False -> []
        True -> {
          let top =
            float_px(int_to_float(now_min - window.start_min) *. px_per_min)
          [
            html.div(
              [
                attribute.class(
                  "absolute right-0 border-t border-emerald-500/60 z-10",
                ),
                attribute.styles([
                  #("top", top),
                  #("left", px(gutter_px)),
                ]),
              ],
              [],
            ),
          ]
        }
      }
    }
  }

  let event_els =
    list.filter_map(events, fn(e) {
      case e.start, e.end {
        AtTime(s), AtTime(en) -> {
          let #(_, st) = timestamp.to_calendar(s, local_offset)
          let #(_, et) = timestamp.to_calendar(en, local_offset)
          let start_min = st.hours * 60 + st.minutes
          let end_min = et.hours * 60 + et.minutes
          // Clamp to window
          let clamped_start = int.max(start_min, window.start_min)
          let clamped_end = int.min(end_min, window.end_min)
          let dur_min = int.max(clamped_end - clamped_start, 0)
          let top_f =
            int_to_float(clamped_start - window.start_min) *. px_per_min
          let h_f = int_to_float(dur_min) *. px_per_min
          let h_f_min = case h_f <. int_to_float(min_event_height_px) {
            True -> int_to_float(min_event_height_px)
            False -> h_f
          }
          let color = color_for(e.calendar_name)
          let time_str =
            format_time(s, local_offset) <> "–" <> format_time(en, local_offset)
          Ok(
            html.div(
              [
                attribute.class(
                  "absolute overflow-hidden rounded-sm border-l-2 px-1 hover:brightness-125 cursor-default",
                ),
                attribute.styles([
                  #("top", float_px(top_f)),
                  #("height", float_px(h_f_min)),
                  #("left", px(gutter_px + 2)),
                  #("right", "2px"),
                  #("background-color", color <> "22"),
                  #("border-left-color", color),
                ]),
              ],
              [
                html.p(
                  [
                    attribute.class(
                      "text-xs leading-tight truncate text-gray-200 font-medium",
                    ),
                  ],
                  [html.text(e.summary)],
                ),
                html.p(
                  [
                    attribute.class("leading-none text-gray-500"),
                    attribute.style("font-size", "9px"),
                  ],
                  [html.text(time_str)],
                ),
              ],
            ),
          )
        }
        _, _ -> Error(Nil)
      }
    })

  html.div(
    [
      attribute.class("relative overflow-y-auto"),
      attribute.style("height", total_h),
    ],
    list.flatten([hour_lines, now_line, event_els]),
  )
}

// EVENT FILTERING -------------------------------------------------------------

/// Return all events whose start date (in local time) matches `date`.
fn events_on_date(
  events: List(Event),
  date: Date,
  local_offset: duration.Duration,
) -> List(Event) {
  list.filter(events, fn(e) {
    case e.start {
      AllDay(d) -> calendar.naive_date_compare(d, date) == order.Eq
      AtTime(ts) -> {
        let event_date = timestamp.to_calendar(ts, local_offset).0
        calendar.naive_date_compare(event_date, date) == order.Eq
      }
    }
  })
}

// DATE HELPERS ----------------------------------------------------------------

/// Generate a list of `n` consecutive dates starting from `start`.
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

/// Advance a date by one day, handling month and year rollovers.
fn advance_date(date: Date) -> Date {
  let days_in = days_in_month(date.month, date.year)
  case date.day < days_in {
    True -> Date(..date, day: date.day + 1)
    False -> {
      case date.month {
        calendar.December ->
          Date(year: date.year + 1, month: calendar.January, day: 1)
        _ -> Date(..date, month: next_month(date.month), day: 1)
      }
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

/// Format an hour (0–23) as "7a", "12p", "1p" etc.
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

/// Compute weekday name using Tomohiko Sakamoto's algorithm.
/// Returns "Sun", "Mon", …, "Sat".
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

/// Integer pixels as a CSS string, e.g. 42 -> "42px".
fn px(n: Int) -> String {
  string.inspect(n) <> "px"
}

/// Float pixels as a CSS string, rounded to 1 decimal place.
fn float_px(f: Float) -> String {
  // Gleam has no built-in float formatting to N decimals without FFI,
  // so we round to the nearest integer.
  let rounded = float_round(f)
  string.inspect(rounded) <> "px"
}

fn int_to_float(n: Int) -> Float {
  int.to_float(n)
}

@external(erlang, "erlang", "round")
fn float_round(f: Float) -> Int
