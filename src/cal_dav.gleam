// CalDAV client implementation.
//
// Implements the 4-step iCloud CalDAV discovery + fetch flow:
//   1. PROPFIND base_url  → current-user-principal href
//   2. PROPFIND principal  → calendar-home-set href
//   3. PROPFIND home (Depth:1) → list of calendar hrefs + display names
//   4. REPORT each calendar  → calendar-data iCal strings for next 7 days
//
// XML is parsed via the xmerl_ffi Erlang module; iCal text via ical.gleam.

// IMPORTS ---------------------------------------------------------------------

import cal.{type Event}
import envoy
import gleam/bit_array
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/list
import gleam/result
import gleam/string
import gleam/time/calendar
import gleam/time/duration
import gleam/time/timestamp
import ical

// CONFIGURATION ---------------------------------------------------------------

/// CalDAV credentials loaded from environment variables at startup.
/// CALDAV_URL      — e.g. "https://caldav.icloud.com"
/// CALDAV_USERNAME — Apple ID email address
/// CALDAV_PASSWORD — app-specific password from appleid.apple.com
pub type Config {
  Config(url: String, username: String, password: String)
}

// PUBLIC API ------------------------------------------------------------------

/// Fetch all events in the next 7 days from the CalDAV server.
/// Returns a list of Events or an error string suitable for display.
pub fn fetch_events(config: Config) -> Result(List(Event), String) {
  use calendar_infos <- result.try(discover_calendars(config))
  let now = timestamp.system_time()
  let seven_days_later =
    timestamp.add(now, gleam_time_duration_days(7))

  let events =
    list.flat_map(calendar_infos, fn(info) {
      let #(href, display_name) = info
      case fetch_calendar_events(config, href, display_name, now, seven_days_later) {
        Ok(evts) -> evts
        Error(_) -> []
      }
    })

  Ok(events)
}

/// Load credentials from environment variables.
/// Returns an error string if any required variable is missing.
pub fn config_from_env() -> Result(Config, String) {
  use url <- result.try(
    envoy.get("CALDAV_URL")
    |> result.map_error(fn(_) { "Missing env var: CALDAV_URL" }),
  )
  use username <- result.try(
    envoy.get("CALDAV_USERNAME")
    |> result.map_error(fn(_) { "Missing env var: CALDAV_USERNAME" }),
  )
  use password <- result.try(
    envoy.get("CALDAV_PASSWORD")
    |> result.map_error(fn(_) { "Missing env var: CALDAV_PASSWORD" }),
  )
  Ok(Config(url:, username:, password:))
}

// DISCOVERY -------------------------------------------------------------------

/// Returns a list of (href, display_name) pairs for all calendars.
fn discover_calendars(config: Config) -> Result(List(#(String, String)), String) {
  use principal_href <- result.try(discover_principal(config))
  use home_href <- result.try(discover_calendar_home(config, principal_href))
  list_calendars(config, home_href)
}

/// Step 1: PROPFIND base URL to get current-user-principal href.
fn discover_principal(config: Config) -> Result(String, String) {
  let body =
    "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
    <> "<D:propfind xmlns:D=\"DAV:\">"
    <> "<D:prop><D:current-user-principal/></D:prop>"
    <> "</D:propfind>"

  use resp <- result.try(propfind(config, config.url, body, "0"))
  use root <- result.try(parse_xml_response(resp))

  let hrefs =
    xmerl_find_text(root, "DAV:", "href")
  case hrefs {
    [href, ..] -> Ok(ensure_absolute(href, config.url))
    [] -> Error("current-user-principal not found in PROPFIND response")
  }
}

/// Step 2: PROPFIND principal URL to get calendar-home-set href.
fn discover_calendar_home(
  config: Config,
  principal_href: String,
) -> Result(String, String) {
  let body =
    "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
    <> "<D:propfind xmlns:D=\"DAV:\" xmlns:C=\"urn:ietf:params:xml:ns:caldav\">"
    <> "<D:prop><C:calendar-home-set/></D:prop>"
    <> "</D:propfind>"

  use resp <- result.try(propfind(config, principal_href, body, "0"))
  use root <- result.try(parse_xml_response(resp))

  let hrefs =
    xmerl_find_text(root, "DAV:", "href")
  case hrefs {
    [href, ..] -> Ok(ensure_absolute(href, config.url))
    [] -> Error("calendar-home-set not found in PROPFIND response")
  }
}

/// Step 3: PROPFIND calendar home with Depth:1 to list all calendars.
/// Returns a list of (href, display_name) for each calendar collection.
fn list_calendars(
  config: Config,
  home_href: String,
) -> Result(List(#(String, String)), String) {
  let body =
    "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
    <> "<D:propfind xmlns:D=\"DAV:\" xmlns:C=\"urn:ietf:params:xml:ns:caldav\">"
    <> "<D:prop>"
    <> "<D:displayname/>"
    <> "<D:resourcetype/>"
    <> "</D:prop>"
    <> "</D:propfind>"

  use resp <- result.try(propfind(config, home_href, body, "1"))
  use root <- result.try(parse_xml_response(resp))

  // Extract all <D:response> blocks and filter for calendar collections
  let response_hrefs = xmerl_find_text(root, "DAV:", "href")
  let display_names = xmerl_find_text(root, "DAV:", "displayname")
  let calendar_markers = xmerl_find_text(root, "urn:ietf:params:xml:ns:caldav", "calendar")

  // Pair hrefs with display names — both lists should align response by response
  // We use presence of a calendar marker as a proxy for "is a calendar collection"
  let n_calendars = list.length(calendar_markers)
  let pairs =
    list.zip(response_hrefs, display_names)
    |> list.take(n_calendars)
    |> list.map(fn(pair) {
      let #(href, name) = pair
      #(ensure_absolute(href, config.url), name)
    })

  Ok(pairs)
}

// EVENT FETCH -----------------------------------------------------------------

/// Step 4: REPORT a calendar to fetch events in a time range.
fn fetch_calendar_events(
  config: Config,
  calendar_href: String,
  calendar_name: String,
  start_ts: timestamp.Timestamp,
  end_ts: timestamp.Timestamp,
) -> Result(List(Event), String) {
  let start_str = format_ical_datetime(start_ts)
  let end_str = format_ical_datetime(end_ts)

  let body =
    "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
    <> "<C:calendar-query xmlns:D=\"DAV:\" xmlns:C=\"urn:ietf:params:xml:ns:caldav\">"
    <> "<D:prop><C:calendar-data/></D:prop>"
    <> "<C:filter>"
    <> "<C:comp-filter name=\"VCALENDAR\">"
    <> "<C:comp-filter name=\"VEVENT\">"
    <> "<C:time-range start=\""
    <> start_str
    <> "\" end=\""
    <> end_str
    <> "\"/>"
    <> "</C:comp-filter>"
    <> "</C:comp-filter>"
    <> "</C:filter>"
    <> "</C:calendar-query>"

  use resp <- result.try(caldav_report(config, calendar_href, body))
  use root <- result.try(parse_xml_response(resp))

  let cal_data_texts =
    xmerl_find_text(root, "urn:ietf:params:xml:ns:caldav", "calendar-data")
  let events =
    list.flat_map(cal_data_texts, fn(ical_text) {
      ical.parse_events(ical_text, calendar_name)
    })
  Ok(events)
}

// HTTP HELPERS ----------------------------------------------------------------

fn propfind(
  config: Config,
  url: String,
  body: String,
  depth: String,
) -> Result(String, String) {
  let headers = [
    #("depth", depth),
    #("content-type", "application/xml; charset=utf-8"),
    #("authorization", basic_auth(config)),
  ]
  send_request(config, url, http.Other("PROPFIND"), body, headers)
}

fn caldav_report(
  config: Config,
  url: String,
  body: String,
) -> Result(String, String) {
  let headers = [
    #("depth", "1"),
    #("content-type", "application/xml; charset=utf-8"),
    #("authorization", basic_auth(config)),
  ]
  send_request(config, url, http.Other("REPORT"), body, headers)
}

fn send_request(
  _config: Config,
  url: String,
  method: http.Method,
  body: String,
  extra_headers: List(#(String, String)),
) -> Result(String, String) {
  use req <- result.try(
    request.to(url)
    |> result.map_error(fn(_) { "Invalid URL: " <> url }),
  )

  let req =
    request.Request(
      ..req,
      method: method,
      body: body,
      headers: list.append(req.headers, extra_headers),
    )

  httpc.send(req)
  |> result.map(fn(resp) { resp.body })
  |> result.map_error(fn(err) { "HTTP request failed: " <> string.inspect(err) })
}

fn basic_auth(config: Config) -> String {
  let credentials = config.username <> ":" <> config.password
  let encoded =
    credentials
    |> bit_array.from_string
    |> bit_array.base64_encode(True)
  "Basic " <> encoded
}

// XML HELPERS -----------------------------------------------------------------

type XmlRoot

@external(erlang, "xmerl_ffi", "parse_xml")
fn xmerl_parse_xml(xml_bin: BitArray) -> Result(XmlRoot, BitArray)

@external(erlang, "xmerl_ffi", "find_text_content")
fn xmerl_find_text_ffi(
  root: XmlRoot,
  ns_uri: String,
  local_name: String,
) -> List(String)

fn parse_xml_response(xml_str: String) -> Result(XmlRoot, String) {
  let xml_bin = bit_array.from_string(xml_str)
  xmerl_parse_xml(xml_bin)
  |> result.map_error(fn(err) {
    "XML parse error: " <> result.unwrap(bit_array.to_string(err), "unknown")
  })
}

fn xmerl_find_text(root: XmlRoot, ns: String, local: String) -> List(String) {
  xmerl_find_text_ffi(root, ns, local)
}

// DATETIME FORMATTING ---------------------------------------------------------

/// Format a Timestamp as an iCalendar UTC datetime string: YYYYMMDDTHHMMSSZ
fn format_ical_datetime(ts: timestamp.Timestamp) -> String {
  let #(date, time) = timestamp.to_calendar(ts, calendar.utc_offset)
  let y = pad4(date.year)
  let mo = pad2(calendar.month_to_int(date.month))
  let d = pad2(date.day)
  let h = pad2(time.hours)
  let mi = pad2(time.minutes)
  let s = pad2(time.seconds)
  y <> mo <> d <> "T" <> h <> mi <> s <> "Z"
}

fn pad2(n: Int) -> String {
  string.pad_start(string.inspect(n), 2, "0")
}

fn pad4(n: Int) -> String {
  string.pad_start(string.inspect(n), 4, "0")
}

// URL HELPERS -----------------------------------------------------------------

/// If href is already absolute (starts with http), return as-is.
/// Otherwise prepend the base URL origin.
fn ensure_absolute(href: String, base_url: String) -> String {
  case string.starts_with(href, "http") {
    True -> href
    False -> {
      // Extract scheme+host from base_url
      let origin = case string.split_once(base_url, "://") {
        Ok(#(scheme, rest)) -> {
          let host = case string.split_once(rest, "/") {
            Ok(#(h, _)) -> h
            Error(Nil) -> rest
          }
          scheme <> "://" <> host
        }
        Error(Nil) -> base_url
      }
      origin <> href
    }
  }
}

// GLEAM_TIME DURATION HELPER --------------------------------------------------

// gleam_time doesn't expose a days() constructor directly; compose from seconds.
fn gleam_time_duration_days(n: Int) -> duration.Duration {
  duration.seconds(n * 86_400)
}
