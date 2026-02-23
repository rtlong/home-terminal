// Local persistent state for home-terminal.
//
// Two files live under the XDG data directory
// (~/.local/share/home-terminal/ or $XDG_DATA_HOME/home-terminal/):
//
//   cache.json   — last-known CalDAV event list; shown immediately on restart
//   config.json  — per-calendar display settings (visibility, color)
//
// Both files are optional: a missing file is treated as empty/default state.

// IMPORTS ---------------------------------------------------------------------

import cal.{type Event, AllDay, AtTime, Event}
import envoy
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import gleam/time/calendar.{type Date, Date}
import gleam/time/timestamp

// TYPES -----------------------------------------------------------------------

/// Per-calendar display configuration.
pub type CalendarConfig {
  CalendarConfig(visible: Bool, color: String)
}

/// The full persisted config: a map from calendar display-name to its config.
/// Keyed by display name since that's what's stable across re-discoveries.
pub type Config =
  Dict(String, CalendarConfig)

/// An empty config dict — used as initial state before config.json is read.
pub fn empty_config() -> Config {
  dict.new()
}

/// Default config for a calendar not yet seen in config.json.
pub fn default_calendar_config() -> CalendarConfig {
  CalendarConfig(visible: True, color: "#4a88cc")
}

// DATA DIR --------------------------------------------------------------------

/// Resolve the data directory path using XDG spec.
/// Falls back to ~/.local/share/home-terminal if XDG_DATA_HOME is not set.
pub fn data_dir() -> String {
  let base = case envoy.get("XDG_DATA_HOME") {
    Ok(xdg) -> xdg
    Error(_) ->
      case envoy.get("HOME") {
        Ok(home) -> home <> "/.local/share"
        Error(_) -> "/tmp"
      }
  }
  base <> "/home-terminal"
}

// CACHE -----------------------------------------------------------------------

/// Read the cached event list from disk. Returns [] if file is absent or corrupt.
pub fn read_cache(dir: String) -> List(Event) {
  let path = dir <> "/cache.json"
  case file_read(path) {
    Error(_) -> []
    Ok(bits) ->
      case bit_array.to_string(bits) {
        Error(_) -> []
        Ok(text) ->
          case json.parse(text, decode.list(event_decoder())) {
            Ok(events) -> events
            Error(_) -> []
          }
      }
  }
}

/// Write the event list to cache.json, creating the directory if needed.
pub fn write_cache(dir: String, events: List(Event)) -> Nil {
  let _ = filelib_ensure_dir(dir <> "/placeholder")
  let json_str = json.to_string(json.array(events, encode_event))
  let _ = file_write(dir <> "/cache.json", bit_array.from_string(json_str))
  Nil
}

// CONFIG ----------------------------------------------------------------------

/// Read per-calendar config from config.json. Returns empty dict if absent.
pub fn read_config(dir: String) -> Config {
  let path = dir <> "/config.json"
  case file_read(path) {
    Error(_) -> dict.new()
    Ok(bits) ->
      case bit_array.to_string(bits) {
        Error(_) -> dict.new()
        Ok(text) ->
          case json.parse(text, config_decoder()) {
            Ok(cfg) -> cfg
            Error(_) -> dict.new()
          }
      }
  }
}

/// Write the config dict to config.json.
pub fn write_config(dir: String, config: Config) -> Nil {
  let _ = filelib_ensure_dir(dir <> "/placeholder")
  let json_str = json.to_string(encode_config(config))
  let _ = file_write(dir <> "/config.json", bit_array.from_string(json_str))
  Nil
}

/// Look up a calendar's config, returning the default if not present.
pub fn get_calendar_config(config: Config, name: String) -> CalendarConfig {
  dict.get(config, name) |> result.unwrap(default_calendar_config())
}

// JSON ENCODING ---------------------------------------------------------------

fn encode_event(event: Event) -> json.Json {
  json.object([
    #("uid", json.string(event.uid)),
    #("summary", json.string(event.summary)),
    #("calendar_name", json.string(event.calendar_name)),
    #("location", json.string(event.location)),
    #("start", encode_event_time(event.start)),
    #("end", encode_event_time(event.end)),
  ])
}

fn encode_event_time(et: cal.EventTime) -> json.Json {
  case et {
    AllDay(date) ->
      json.object([
        #("type", json.string("all_day")),
        #("date", json.string(encode_date(date))),
      ])
    AtTime(ts) ->
      json.object([
        #("type", json.string("at_time")),
        #(
          "unix_seconds",
          json.int(timestamp.to_unix_seconds_and_nanoseconds(ts).0),
        ),
      ])
  }
}

fn encode_date(date: Date) -> String {
  pad4(date.year) <> pad2(calendar.month_to_int(date.month)) <> pad2(date.day)
}

fn encode_config(config: Config) -> json.Json {
  let entries =
    dict.to_list(config)
    |> list.map(fn(pair) {
      let #(name, cal_cfg) = pair
      #(
        name,
        json.object([
          #("visible", json.bool(cal_cfg.visible)),
          #("color", json.string(cal_cfg.color)),
        ]),
      )
    })
  json.object(entries)
}

// JSON DECODING ---------------------------------------------------------------

fn event_decoder() -> decode.Decoder(Event) {
  use uid <- decode.field("uid", decode.string)
  use summary <- decode.field("summary", decode.string)
  use calendar_name <- decode.field("calendar_name", decode.string)
  use start <- decode.field("start", event_time_decoder())
  use end <- decode.field("end", event_time_decoder())
  use location <- decode.optional_field("location", "", decode.string)
  decode.success(Event(uid:, summary:, calendar_name:, start:, end:, location:))
}

fn event_time_decoder() -> decode.Decoder(cal.EventTime) {
  use type_str <- decode.field("type", decode.string)
  case type_str {
    "all_day" -> {
      use date_str <- decode.field("date", decode.string)
      case parse_date_string(date_str) {
        Ok(date) -> decode.success(AllDay(date))
        Error(_) ->
          decode.failure(
            AllDay(Date(2000, calendar.January, 1)),
            "invalid date",
          )
      }
    }
    "at_time" -> {
      use secs <- decode.field("unix_seconds", decode.int)
      decode.success(AtTime(timestamp.from_unix_seconds(secs)))
    }
    _ ->
      decode.failure(
        AllDay(Date(2000, calendar.January, 1)),
        "unknown EventTime type",
      )
  }
}

fn config_decoder() -> decode.Decoder(Config) {
  decode.dict(decode.string, calendar_config_decoder())
}

fn calendar_config_decoder() -> decode.Decoder(CalendarConfig) {
  use visible <- decode.field("visible", decode.bool)
  use color <- decode.field("color", decode.string)
  decode.success(CalendarConfig(visible:, color:))
}

// DATE PARSING ----------------------------------------------------------------

fn parse_date_string(s: String) -> Result(Date, Nil) {
  use year <- result.try(parse_int_slice(s, 0, 4))
  use month_int <- result.try(parse_int_slice(s, 4, 2))
  use day <- result.try(parse_int_slice(s, 6, 2))
  use month <- result.try(calendar.month_from_int(month_int))
  Ok(Date(year:, month:, day:))
}

fn parse_int_slice(s: String, offset: Int, length: Int) -> Result(Int, Nil) {
  string.slice(s, offset, length) |> int.parse
}

// PADDING HELPERS -------------------------------------------------------------

fn pad2(n: Int) -> String {
  string.pad_start(string.inspect(n), 2, "0")
}

fn pad4(n: Int) -> String {
  string.pad_start(string.inspect(n), 4, "0")
}

// FILE I/O FFI ----------------------------------------------------------------

@external(erlang, "file", "read_file")
fn file_read(path: String) -> Result(BitArray, FileError)

@external(erlang, "file", "write_file")
fn file_write(path: String, data: BitArray) -> Result(Nil, FileError)

@external(erlang, "filelib", "ensure_dir")
fn filelib_ensure_dir(path: String) -> Result(Nil, FileError)

type FileError
