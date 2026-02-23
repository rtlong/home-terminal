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

/// The main 7-day view. Shows events for today and the next 6 days,
/// grouped by day, with timed events after all-day events within each day.
/// `color_for` is a fn(calendar_name) -> css_color_string for per-cal coloring.
pub fn view_seven_days(
  events: List(Event),
  color_for: fn(String) -> String,
) -> Element(msg) {
  let now = timestamp.system_time()
  let local_offset = calendar.local_offset()
  let today_date = timestamp.to_calendar(now, local_offset).0
  let days = next_n_dates(today_date, 7)

  html.div(
    [attribute.class("grid grid-cols-7 gap-3 p-4 h-screen")],
    list.map(days, fn(day) {
      view_day(day, day == today_date, events, local_offset, color_for)
    }),
  )
}

// DAY VIEW --------------------------------------------------------------------

fn view_day(
  date: Date,
  is_today: Bool,
  all_events: List(Event),
  local_offset: duration.Duration,
  color_for: fn(String) -> String,
) -> Element(msg) {
  let day_events = events_on_date(all_events, date, local_offset)
  let timed =
    list.filter(day_events, fn(e) {
      case e.start {
        AtTime(_) -> True
        AllDay(_) -> False
      }
    })
  let all_day =
    list.filter(day_events, fn(e) {
      case e.start {
        AllDay(_) -> True
        AtTime(_) -> False
      }
    })
  let sorted_timed = list.sort(timed, fn(a, b) { compare_event_start(a, b) })
  // All-day events first, then timed events sorted by start
  let ordered = list.append(all_day, sorted_timed)

  let day_classes = case is_today {
    True ->
      "flex flex-col min-h-0 rounded-lg border border-gray-700 overflow-hidden bg-gray-900"
    False ->
      "flex flex-col min-h-0 rounded-lg border border-gray-800 overflow-hidden"
  }
  let header_classes = case is_today {
    True ->
      "flex items-baseline gap-2 px-2 py-1.5 bg-gray-800 border-b border-emerald-800 shrink-0"
    False ->
      "flex items-baseline gap-2 px-2 py-1.5 bg-gray-900 border-b border-gray-800 shrink-0"
  }
  let weekday_classes = case is_today {
    True -> "text-xs font-semibold uppercase tracking-wide text-emerald-400"
    False -> "text-xs font-semibold uppercase tracking-wide text-gray-500"
  }
  let date_classes = case is_today {
    True -> "text-xs text-emerald-600"
    False -> "text-xs text-gray-600"
  }

  html.div([attribute.class(day_classes)], [
    html.div([attribute.class(header_classes)], [
      html.span([attribute.class(weekday_classes)], [
        html.text(weekday_name(date)),
      ]),
      html.span([attribute.class(date_classes)], [html.text(format_date(date))]),
    ]),
    html.ul(
      [attribute.class("flex flex-col gap-px py-1 overflow-y-auto min-h-0")],
      case ordered {
        [] -> [
          html.li(
            [attribute.class("px-2 py-0.5 text-xs text-gray-700 italic")],
            [html.text("—")],
          ),
        ]
        _ -> list.map(ordered, fn(e) { view_event(e, local_offset, color_for) })
      },
    ),
  ])
}

fn view_event(
  event: Event,
  local_offset: duration.Duration,
  color_for: fn(String) -> String,
) -> Element(msg) {
  let color = color_for(event.calendar_name)
  let time_str = case event.start {
    AllDay(_) -> "all day"
    AtTime(ts) -> format_time(ts, local_offset)
  }
  html.li(
    [
      attribute.class(
        "flex flex-col gap-px px-1.5 py-0.5 border-l-2 mx-1 rounded-sm hover:bg-gray-800 cursor-default",
      ),
      attribute.style("border-left-color", color),
    ],
    [
      html.span([attribute.class("text-xs text-gray-500 leading-none")], [
        html.text(time_str),
      ]),
      html.span([attribute.class("text-xs text-gray-200 leading-snug")], [
        html.text(event.summary),
      ]),
    ],
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

fn compare_event_start(a: Event, b: Event) -> order.Order {
  case a.start, b.start {
    AtTime(ta), AtTime(tb) -> timestamp.compare(ta, tb)
    AllDay(da), AllDay(db) -> calendar.naive_date_compare(da, db)
    AtTime(_), AllDay(_) -> order.Lt
    AllDay(_), AtTime(_) -> order.Gt
  }
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
