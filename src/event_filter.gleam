//// Per-calendar regex include/exclude filtering for events.
////
//// Filters are configured via `state.CalendarConfig.{include_filters,
//// exclude_filters}`. Each `EventFilter` names one event field
//// (summary, description, location) and a regex pattern to match against.
////
//// Semantics:
////   * If `include_filters` is non-empty, an event is kept only if at least
////     one include filter matches.
////   * Then, if any `exclude_filters` match, the event is dropped.
////   * Both lists empty (the default) = keep everything.
////
//// Patterns are compiled case-insensitively. Patterns that fail to compile
//// are silently dropped (the rest of the filter set still applies) so that
//// a single bad regex in `config.json` cannot make every event vanish.

import cal.{type Event}
import gleam/list
import gleam/regexp.{type Regexp}
import state.{
  type CalendarConfig, type EventField, type EventFilter, FieldDescription,
  FieldLocation, FieldSummary,
}

/// One pattern, compiled, with the field it targets.
pub type CompiledFilter {
  CompiledFilter(field: EventField, regex: Regexp)
}

/// The include/exclude filter pair for a single calendar, pre-compiled so
/// regex compilation runs once per render rather than once per event.
pub type Compiled {
  Compiled(include: List(CompiledFilter), exclude: List(CompiledFilter))
}

/// Empty filter set. Equivalent to "keep everything".
pub fn empty() -> Compiled {
  Compiled(include: [], exclude: [])
}

/// Compile the include and exclude filter lists from a `CalendarConfig`.
/// Patterns that fail to compile are dropped from the result.
pub fn compile(cfg: CalendarConfig) -> Compiled {
  Compiled(
    include: list.filter_map(cfg.include_filters, compile_one),
    exclude: list.filter_map(cfg.exclude_filters, compile_one),
  )
}

fn compile_one(f: EventFilter) -> Result(CompiledFilter, Nil) {
  let opts = regexp.Options(case_insensitive: True, multi_line: False)
  case regexp.compile(f.pattern, opts) {
    Ok(re) -> Ok(CompiledFilter(field: f.field, regex: re))
    Error(_) -> Error(Nil)
  }
}

/// Returns True if `event` should be kept under the given compiled filter set.
///
/// Note: when `include` is empty, the include phase is a no-op (keep). When
/// `exclude` is empty, the exclude phase is a no-op (keep). With both empty
/// every event passes through unchanged.
pub fn keep(event: Event, c: Compiled) -> Bool {
  let included = case c.include {
    [] -> True
    filters -> list.any(filters, matches(event, _))
  }
  case included {
    False -> False
    True ->
      case c.exclude {
        [] -> True
        filters -> !list.any(filters, matches(event, _))
      }
  }
}

fn matches(event: Event, f: CompiledFilter) -> Bool {
  regexp.check(f.regex, field_value(event, f.field))
}

fn field_value(event: Event, field: EventField) -> String {
  case field {
    FieldSummary -> event.summary
    FieldDescription -> event.description
    FieldLocation -> event.location
  }
}
