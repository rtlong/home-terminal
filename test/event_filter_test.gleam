//// Tests for `event_filter`: per-calendar include/exclude regex filtering.

import cal.{type Event, AllDay, Event}
import event_filter
import gleam/list
import gleam/time/calendar
import state.{
  type CalendarConfig, type EventFilter, CalendarConfig, EventFilter,
  FieldDescription, FieldLocation, FieldSummary,
}

// ---- Helpers ---------------------------------------------------------------

fn make_event(
  uid: String,
  summary: String,
  description: String,
  location: String,
) -> Event {
  let d = calendar.Date(2026, calendar.June, 16)
  Event(
    uid: uid,
    summary: summary,
    start: AllDay(d),
    end: AllDay(d),
    calendar_name: "test",
    location: location,
    free: False,
    description: description,
    url: "",
  )
}

fn cfg(includes: List(EventFilter), excludes: List(EventFilter)) -> CalendarConfig {
  CalendarConfig(
    visible: True,
    show_location: True,
    include_filters: includes,
    exclude_filters: excludes,
  )
}

fn keep_summaries(
  events: List(Event),
  c: CalendarConfig,
) -> List(String) {
  let compiled = event_filter.compile(c)
  events
  |> list.filter(event_filter.keep(_, compiled))
  |> list.map(fn(e: Event) { e.summary })
}

// ---- Tests -----------------------------------------------------------------

// Empty include + empty exclude = identity (every event survives).
pub fn no_filters_pass_through_test() -> Nil {
  let events = [
    make_event("a", "Meeting", "", ""),
    make_event("b", "Lunch", "", ""),
    make_event("c", "Standup", "", ""),
  ]
  assert keep_summaries(events, cfg([], [])) == ["Meeting", "Lunch", "Standup"]
}

// Non-empty include keeps only matching events.
pub fn include_only_keeps_matches_test() -> Nil {
  let events = [
    make_event("a", "Team Standup", "", ""),
    make_event("b", "Lunch", "", ""),
    make_event("c", "Standup retro", "", ""),
  ]
  let c = cfg([EventFilter(FieldSummary, "Standup")], [])
  assert keep_summaries(events, c) == ["Team Standup", "Standup retro"]
}

// Empty include + non-empty exclude drops matching events.
pub fn exclude_only_drops_matches_test() -> Nil {
  let events = [
    make_event("a", "Team Standup", "", ""),
    make_event("b", "Lunch", "", ""),
    make_event("c", "Standup retro", "", ""),
  ]
  let c = cfg([], [EventFilter(FieldSummary, "Standup")])
  assert keep_summaries(events, c) == ["Lunch"]
}

// Include filter applies, then exclude further trims the result.
pub fn include_then_exclude_test() -> Nil {
  let events = [
    make_event("a", "Team Standup", "", ""),
    make_event("b", "Lunch", "", ""),
    make_event("c", "Standup retro", "", ""),
    make_event("d", "Standup canceled", "", ""),
  ]
  let c =
    cfg(
      [EventFilter(FieldSummary, "Standup")],
      [EventFilter(FieldSummary, "canceled")],
    )
  assert keep_summaries(events, c) == ["Team Standup", "Standup retro"]
}

// Patterns are matched case-insensitively by default.
pub fn case_insensitive_test() -> Nil {
  let events = [
    make_event("a", "STANDUP", "", ""),
    make_event("b", "standup", "", ""),
    make_event("c", "StAnDuP", "", ""),
    make_event("d", "Lunch", "", ""),
  ]
  let c = cfg([EventFilter(FieldSummary, "standup")], [])
  assert keep_summaries(events, c) == ["STANDUP", "standup", "StAnDuP"]
}

// Each filter can target a different event field; the include list ORs them.
pub fn multi_field_include_test() -> Nil {
  let events = [
    make_event("a", "Meeting", "discuss roadmap", ""),
    make_event("b", "Lunch", "", "Cafeteria"),
    make_event("c", "Other", "", ""),
  ]
  let c =
    cfg(
      [
        EventFilter(FieldDescription, "roadmap"),
        EventFilter(FieldLocation, "Cafeteria"),
      ],
      [],
    )
  assert keep_summaries(events, c) == ["Meeting", "Lunch"]
}

// Exclude filter on `description` field still drops the event.
pub fn exclude_on_description_test() -> Nil {
  let events = [
    make_event("a", "Meeting", "weekly recurring planning", ""),
    make_event("b", "Meeting", "ad-hoc", ""),
  ]
  let c = cfg([], [EventFilter(FieldDescription, "recurring")])
  assert keep_summaries(events, c) == ["Meeting"]
  // (the b instance, which has no "recurring" in description)
}

// A regex (not just a literal substring) works.
pub fn regex_pattern_test() -> Nil {
  let events = [
    make_event("a", "Bug #123 fix", "", ""),
    make_event("b", "Feature #456 plan", "", ""),
    make_event("c", "No ticket here", "", ""),
  ]
  let c = cfg([EventFilter(FieldSummary, "#\\d+")], [])
  assert keep_summaries(events, c) == ["Bug #123 fix", "Feature #456 plan"]
}

// A pattern that fails to compile is dropped, leaving the rest of the
// filter set functional (rather than crashing or vanishing all events).
pub fn invalid_pattern_is_ignored_test() -> Nil {
  let events = [
    make_event("a", "Standup", "", ""),
    make_event("b", "Lunch", "", ""),
  ]
  // Unclosed character class is invalid; the second filter still matches.
  let c =
    cfg(
      [
        EventFilter(FieldSummary, "[unclosed"),
        EventFilter(FieldSummary, "Standup"),
      ],
      [],
    )
  assert keep_summaries(events, c) == ["Standup"]
}

// An include list containing ONLY invalid patterns compiles to an empty
// include list, which means "no include filter applied" — so events pass.
// (Tradeoff: prefer "show everything" over "show nothing" on user typos.)
pub fn all_invalid_include_acts_as_no_filter_test() -> Nil {
  let events = [
    make_event("a", "Standup", "", ""),
    make_event("b", "Lunch", "", ""),
  ]
  let c = cfg([EventFilter(FieldSummary, "[unclosed")], [])
  assert keep_summaries(events, c) == ["Standup", "Lunch"]
}
