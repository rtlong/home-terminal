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
import gleam/float
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
  CalendarConfig(visible: Bool)
}

/// An external iCal feed URL with a display name and refresh interval.
pub type IcalUrl {
  IcalUrl(
    name: String,
    url: String,
    /// Human-readable refresh interval, e.g. "5 minutes", "hourly", "daily".
    /// Parsed by parse_refresh_interval/1. Defaults to "" (every poll cycle).
    refresh: String,
  )
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
    /// Maps person name → hue angle (0–360°) for color generation.
    /// e.g. {"Ryan": 187.0, "Alex": 300.0}
    people_colors: Dict(String, Float),
    /// Per-calendar display settings (visibility, color).
    calendars: Dict(String, CalendarConfig),
    /// External iCal feed URLs (e.g. shared Google Calendar links).
    ical_urls: List(IcalUrl),
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
    ical_urls: [],
    latitude: 0.0,
    longitude: 0.0,
  )
}

/// Default config for a calendar not yet seen in config.json.
pub fn default_calendar_config() -> CalendarConfig {
  CalendarConfig(visible: True)
}

/// Parse a human-readable refresh interval string into seconds.
/// Supports: "daily", "hourly", "weekly",
///           "<N> minute(s)", "<N> hour(s)", "<N> day(s)", "<N> second(s)".
/// Returns 0 for empty or unrecognised strings (meaning "every poll cycle").
pub fn parse_refresh_interval(s: String) -> Int {
  let trimmed = string.trim(s) |> string.lowercase
  case trimmed {
    "" -> 0
    "daily" -> 86_400
    "hourly" -> 3600
    "weekly" -> 604_800
    _ -> parse_quantity_unit(trimmed)
  }
}

/// Parse "<number> <unit>" patterns like "15 minutes", "6 hours", "1 day".
fn parse_quantity_unit(s: String) -> Int {
  // Split on first space or find where digits end.
  let parts =
    string.split(s, " ")
    |> list.filter(fn(p) { p != "" })
  case parts {
    [num_str, unit_str, ..] ->
      case int.parse(num_str) {
        Ok(n) -> n * unit_to_seconds(string.lowercase(unit_str))
        Error(_) -> 0
      }
    _ -> 0
  }
}

/// Map a unit word (possibly plural) to seconds.
fn unit_to_seconds(unit: String) -> Int {
  case unit {
    "second" | "seconds" | "sec" | "secs" | "s" -> 1
    "minute" | "minutes" | "min" | "mins" | "m" -> 60
    "hour" | "hours" | "hr" | "hrs" | "h" -> 3600
    "day" | "days" | "d" -> 86_400
    "week" | "weeks" | "w" -> 604_800
    _ -> 0
  }
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

// ICAL FEED CACHE -------------------------------------------------------------

/// Persisted iCal feed cache: last-fetched timestamps and cached events per URL.
pub type IcalFeedCache {
  IcalFeedCache(
    last_fetched: Dict(String, Int),
    cached_events: Dict(String, List(Event)),
  )
}

/// Read iCal feed cache from ical_cache.json. Returns empty caches if absent.
pub fn read_ical_cache(dir: String) -> IcalFeedCache {
  let path = dir <> "/ical_cache.json"
  case file_read(path) {
    Error(_) ->
      IcalFeedCache(last_fetched: dict.new(), cached_events: dict.new())
    Ok(bits) ->
      case bit_array.to_string(bits) {
        Error(_) ->
          IcalFeedCache(last_fetched: dict.new(), cached_events: dict.new())
        Ok(text) ->
          case json.parse(text, ical_feed_cache_decoder()) {
            Ok(ic) -> ic
            Error(_) ->
              IcalFeedCache(
                last_fetched: dict.new(),
                cached_events: dict.new(),
              )
          }
      }
  }
}

/// Write iCal feed cache to ical_cache.json.
pub fn write_ical_cache(
  dir: String,
  last_fetched: Dict(String, Int),
  cached_events: Dict(String, List(Event)),
) -> Nil {
  let _ = filelib_ensure_dir(dir <> "/placeholder")
  let json_str =
    json.to_string(encode_ical_feed_cache(last_fetched, cached_events))
  let _ =
    file_write(dir <> "/ical_cache.json", bit_array.from_string(json_str))
  Nil
}

fn encode_ical_feed_cache(
  last_fetched: Dict(String, Int),
  cached_events: Dict(String, List(Event)),
) -> json.Json {
  let lf_entries =
    dict.to_list(last_fetched)
    |> list.map(fn(pair) {
      let #(url, secs) = pair
      #(url, json.int(secs))
    })
  let ce_entries =
    dict.to_list(cached_events)
    |> list.map(fn(pair) {
      let #(url, events) = pair
      #(url, json.array(events, encode_event))
    })
  json.object([
    #("last_fetched", json.object(lf_entries)),
    #("cached_events", json.object(ce_entries)),
  ])
}

fn ical_feed_cache_decoder() -> decode.Decoder(IcalFeedCache) {
  use last_fetched <- decode.optional_field(
    "last_fetched",
    dict.new(),
    decode.dict(decode.string, decode.int),
  )
  use cached_events <- decode.optional_field(
    "cached_events",
    dict.new(),
    decode.dict(decode.string, decode.list(event_decoder())),
  )
  decode.success(IcalFeedCache(last_fetched:, cached_events:))
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
      let #(person, hue) = pair
      #(person, json.float(hue))
    })
  json.object([
    #("home_address", json.string(config.home_address)),
    #("people", json.array(config.people, json.string)),
    #("calendar_people", json.object(cal_people_entries)),
    #("people_colors", json.object(people_colors_entries)),
    #("calendars", json.object(cal_entries)),
    #("ical_urls", json.array(config.ical_urls, encode_ical_url)),
    #("latitude", json.float(config.latitude)),
    #("longitude", json.float(config.longitude)),
  ])
}

fn encode_ical_url(ical_url: IcalUrl) -> json.Json {
  json.object([
    #("name", json.string(ical_url.name)),
    #("url", json.string(ical_url.url)),
    #("refresh", json.string(ical_url.refresh)),
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
  // people_colors may be stored as Float (new) or String hex (legacy).
  // We try Float first; if that fails try String and extract the hue.
  use people_colors <- decode.optional_field(
    "people_colors",
    dict.new(),
    decode.one_of(decode.dict(decode.string, decode.float), [
      decode.dict(decode.string, decode.string)
      |> decode.map(fn(d) {
        dict.map_values(d, fn(_, hex) { hue_from_hex_string(hex) })
      }),
    ]),
  )
  use calendars <- decode.optional_field(
    "calendars",
    dict.new(),
    decode.dict(decode.string, calendar_config_decoder()),
  )
  use ical_urls <- decode.optional_field(
    "ical_urls",
    [],
    decode.list(ical_url_decoder()),
  )
  use latitude <- decode.optional_field("latitude", 0.0, decode.float)
  use longitude <- decode.optional_field("longitude", 0.0, decode.float)
  decode.success(Config(
    home_address:,
    people:,
    calendar_people:,
    people_colors:,
    calendars:,
    ical_urls:,
    latitude:,
    longitude:,
  ))
}

fn calendar_config_decoder() -> decode.Decoder(CalendarConfig) {
  use visible <- decode.field("visible", decode.bool)
  decode.success(CalendarConfig(visible:))
}

fn ical_url_decoder() -> decode.Decoder(IcalUrl) {
  use name <- decode.field("name", decode.string)
  use url <- decode.field("url", decode.string)
  use refresh <- decode.optional_field("refresh", "", decode.string)
  decode.success(IcalUrl(name:, url:, refresh:))
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

// COLOR MIGRATION -------------------------------------------------------------

/// Extract a hue angle (0–360°) from a hex color string like "#cb00e6".
/// Public so cal_server can call it when a user picks a new person color.
pub fn hue_from_hex(hex: String) -> Float {
  hue_from_hex_string(hex)
}

/// Extract a hue angle (0–360°) from a legacy hex color string like "#cb00e6".
/// Converts the hex to RGB, then to HSL, and returns the H component in degrees.
/// Falls back to 250.0 (blue) if the string can't be parsed.
fn hue_from_hex_string(hex: String) -> Float {
  let s = case string.starts_with(hex, "#") {
    True -> string.drop_start(hex, 1)
    False -> hex
  }
  case string.length(s) == 6 {
    False -> 250.0
    True -> {
      let r_str = string.slice(s, 0, 2)
      let g_str = string.slice(s, 2, 2)
      let b_str = string.slice(s, 4, 2)
      case
        int.base_parse(r_str, 16),
        int.base_parse(g_str, 16),
        int.base_parse(b_str, 16)
      {
        Ok(r), Ok(g), Ok(b) -> rgb_to_hue(r, g, b)
        _, _, _ -> 250.0
      }
    }
  }
}

/// Compute the HSL hue (0–360°) from 8-bit RGB values.
fn rgb_to_hue(r: Int, g: Int, b: Int) -> Float {
  let rf = int.to_float(r) /. 255.0
  let gf = int.to_float(g) /. 255.0
  let bf = int.to_float(b) /. 255.0
  let cmax = float.max(rf, float.max(gf, bf))
  let cmin = float.min(rf, float.min(gf, bf))
  let delta = cmax -. cmin
  case delta == 0.0 {
    True -> 0.0
    False -> {
      let raw = case cmax == rf, cmax == gf {
        True, _ ->
          { { gf -. bf } /. delta }
          +. case gf <. bf {
            True -> 6.0
            False -> 0.0
          }
        False, True -> { { bf -. rf } /. delta } +. 2.0
        False, False -> { { rf -. gf } /. delta } +. 4.0
      }
      raw *. 60.0
    }
  }
}

// FILE I/O FFI ----------------------------------------------------------------

@external(erlang, "file", "read_file")
fn file_read(path: String) -> Result(BitArray, FileError)

@external(erlang, "file", "write_file")
fn file_write(path: String, data: BitArray) -> Result(Nil, FileError)

@external(erlang, "filelib", "ensure_dir")
fn filelib_ensure_dir(path: String) -> Result(Nil, FileError)

type FileError
