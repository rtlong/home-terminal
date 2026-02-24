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

import cal.{type Event, type TravelInfo, AllDay, AtTime, Event, TravelInfo}
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

/// Top-level application config, persisted to config.json.
pub type Config {
  Config(
    /// Address used as the origin for travel-time calculations, e.g.
    /// "123 Main St, Boston MA 02101".
    home_address: String,
    /// Ordered list of people tracked in this household, e.g. ["Ryan", "Alex"].
    people: List(String),
    /// Maps calendar display-name → list of people who share that calendar.
    calendar_people: Dict(String, List(String)),
    /// Maps person name → CSS color string for travel block tinting.
    /// e.g. {"Ryan": "#4a88cc", "Alex": "#e06ea0"}
    people_colors: Dict(String, String),
    /// Per-calendar display settings (visibility, color).
    calendars: Dict(String, CalendarConfig),
    /// Geographic coordinates for sunrise/sunset calculation.
    /// Decimal degrees: positive = N/E, negative = S/W.
    latitude: Float,
    longitude: Float,
  )
}

/// An empty config — used as initial state before config.json is read.
pub fn empty_config() -> Config {
  Config(
    home_address: "",
    people: [],
    calendar_people: dict.new(),
    people_colors: dict.new(),
    calendars: dict.new(),
    latitude: 0.0,
    longitude: 0.0,
  )
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

// TRAVEL CACHE ----------------------------------------------------------------

/// Persisted travel caches: home→loc TravelInfo and point-to-point leg durations.
pub type TravelCaches {
  TravelCaches(travel_cache: Dict(String, TravelInfo), leg_cache: cal.LegCache)
}

/// Read travel caches from travel_cache.json. Returns empty caches if absent.
pub fn read_travel_caches(dir: String) -> TravelCaches {
  let path = dir <> "/travel_cache.json"
  case file_read(path) {
    Error(_) -> TravelCaches(travel_cache: dict.new(), leg_cache: dict.new())
    Ok(bits) ->
      case bit_array.to_string(bits) {
        Error(_) ->
          TravelCaches(travel_cache: dict.new(), leg_cache: dict.new())
        Ok(text) ->
          case json.parse(text, travel_caches_decoder()) {
            Ok(tc) -> tc
            Error(_) ->
              TravelCaches(travel_cache: dict.new(), leg_cache: dict.new())
          }
      }
  }
}

/// Write travel caches to travel_cache.json.
pub fn write_travel_caches(
  dir: String,
  travel_cache: Dict(String, TravelInfo),
  leg_cache: cal.LegCache,
) -> Nil {
  let _ = filelib_ensure_dir(dir <> "/placeholder")
  let json_str = json.to_string(encode_travel_caches(travel_cache, leg_cache))
  let _ =
    file_write(dir <> "/travel_cache.json", bit_array.from_string(json_str))
  Nil
}

fn encode_travel_caches(
  travel_cache: Dict(String, TravelInfo),
  leg_cache: cal.LegCache,
) -> json.Json {
  let tc_entries =
    dict.to_list(travel_cache)
    |> list.map(fn(pair) {
      let #(loc, info) = pair
      #(
        loc,
        json.object([
          #("city", json.string(info.city)),
          #("distance_text", json.string(info.distance_text)),
          #("duration_text", json.string(info.duration_text)),
          #("duration_secs", json.int(info.duration_secs)),
        ]),
      )
    })
  let lc_entries =
    dict.to_list(leg_cache)
    |> list.map(fn(pair) {
      let #(key, secs) = pair
      #(key, json.int(secs))
    })
  json.object([
    #("travel_cache", json.object(tc_entries)),
    #("leg_cache", json.object(lc_entries)),
  ])
}

fn travel_caches_decoder() -> decode.Decoder(TravelCaches) {
  use travel_cache <- decode.optional_field(
    "travel_cache",
    dict.new(),
    decode.dict(decode.string, travel_info_decoder()),
  )
  use leg_cache <- decode.optional_field(
    "leg_cache",
    dict.new(),
    decode.dict(decode.string, decode.int),
  )
  decode.success(TravelCaches(travel_cache:, leg_cache:))
}

fn travel_info_decoder() -> decode.Decoder(TravelInfo) {
  use city <- decode.field("city", decode.string)
  use distance_text <- decode.field("distance_text", decode.string)
  use duration_text <- decode.field("duration_text", decode.string)
  use duration_secs <- decode.field("duration_secs", decode.int)
  decode.success(TravelInfo(
    city:,
    distance_text:,
    duration_text:,
    duration_secs:,
  ))
}

// CONFIG ----------------------------------------------------------------------

/// Read config from config.json. Returns empty config if absent or corrupt.
pub fn read_config(dir: String) -> Config {
  let path = dir <> "/config.json"
  case file_read(path) {
    Error(_) -> empty_config()
    Ok(bits) ->
      case bit_array.to_string(bits) {
        Error(_) -> empty_config()
        Ok(text) ->
          case json.parse(text, config_decoder()) {
            Ok(cfg) -> cfg
            Error(_) -> empty_config()
          }
      }
  }
}

/// Write the config to config.json.
pub fn write_config(dir: String, config: Config) -> Nil {
  let _ = filelib_ensure_dir(dir <> "/placeholder")
  let json_str = json.to_string(encode_config(config))
  let _ = file_write(dir <> "/config.json", bit_array.from_string(json_str))
  Nil
}

/// Look up a calendar's config, returning the default if not present.
pub fn get_calendar_config(config: Config, name: String) -> CalendarConfig {
  dict.get(config.calendars, name) |> result.unwrap(default_calendar_config())
}

// JSON ENCODING ---------------------------------------------------------------

fn encode_event(event: Event) -> json.Json {
  json.object([
    #("uid", json.string(event.uid)),
    #("summary", json.string(event.summary)),
    #("calendar_name", json.string(event.calendar_name)),
    #("location", json.string(event.location)),
    #("free", json.bool(event.free)),
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
  let cal_entries =
    dict.to_list(config.calendars)
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
  let cal_people_entries =
    dict.to_list(config.calendar_people)
    |> list.map(fn(pair) {
      let #(name, people) = pair
      #(name, json.array(people, json.string))
    })
  let people_colors_entries =
    dict.to_list(config.people_colors)
    |> list.map(fn(pair) {
      let #(person, color) = pair
      #(person, json.string(color))
    })
  json.object([
    #("home_address", json.string(config.home_address)),
    #("people", json.array(config.people, json.string)),
    #("calendar_people", json.object(cal_people_entries)),
    #("people_colors", json.object(people_colors_entries)),
    #("calendars", json.object(cal_entries)),
    #("latitude", json.float(config.latitude)),
    #("longitude", json.float(config.longitude)),
  ])
}

// JSON DECODING ---------------------------------------------------------------

fn event_decoder() -> decode.Decoder(Event) {
  use uid <- decode.field("uid", decode.string)
  use summary <- decode.field("summary", decode.string)
  use calendar_name <- decode.field("calendar_name", decode.string)
  use start <- decode.field("start", event_time_decoder())
  use end <- decode.field("end", event_time_decoder())
  use location <- decode.optional_field("location", "", decode.string)
  use free <- decode.optional_field("free", False, decode.bool)
  decode.success(Event(
    uid:,
    summary:,
    calendar_name:,
    start:,
    end:,
    location:,
    free:,
  ))
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
  use home_address <- decode.optional_field("home_address", "", decode.string)
  use people <- decode.optional_field("people", [], decode.list(decode.string))
  use calendar_people <- decode.optional_field(
    "calendar_people",
    dict.new(),
    decode.dict(decode.string, decode.list(decode.string)),
  )
  use people_colors <- decode.optional_field(
    "people_colors",
    dict.new(),
    decode.dict(decode.string, decode.string),
  )
  use calendars <- decode.optional_field(
    "calendars",
    dict.new(),
    decode.dict(decode.string, calendar_config_decoder()),
  )
  use latitude <- decode.optional_field("latitude", 0.0, decode.float)
  use longitude <- decode.optional_field("longitude", 0.0, decode.float)
  decode.success(Config(
    home_address:,
    people:,
    calendar_people:,
    people_colors:,
    calendars:,
    latitude:,
    longitude:,
  ))
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
