// IMPORTS ---------------------------------------------------------------------

import lustre/element.{type Element}
import lustre/element/html

// TYPES -----------------------------------------------------------------------

/// A single calendar event, as fetched and parsed from CalDAV.
pub type Event {
  Event(
    uid: String,
    summary: String,
    start: String,
    // TODO: replace with a proper datetime type once we add a date library
    end: String,
    all_day: Bool,
    calendar_name: String,
  )
}

// VIEW ------------------------------------------------------------------------

/// Rendered while calendar_server has not yet delivered its first fetch.
pub fn view_loading() -> Element(msg) {
  html.p([], [html.text("Loading calendar…")])
}

/// Rendered when the CalDAV fetch failed.
pub fn view_error(reason: String) -> Element(msg) {
  html.p([], [html.text("Calendar error: " <> reason)])
}

/// The main 7-day view. Receives the list of events from tabs.gleam, which
/// gets them from calendar_server.
pub fn view_seven_days(_events: List(Event)) -> Element(msg) {
  // TODO: implement 7-day grid
  html.p([], [html.text("7-day view coming soon")])
}
