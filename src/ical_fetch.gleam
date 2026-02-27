// External iCal feed fetcher.
//
// Fetches a .ics URL via HTTP GET and parses the response body using
// ical.parse_events. Used alongside the CalDAV client to pull in
// arbitrary external calendar feeds (e.g. shared Google Calendar URLs).

import cal.{type Event}
import gleam/bit_array
import gleam/bytes_tree
import gleam/hackney
import gleam/http
import gleam/http/request
import gleam/list
import gleam/result
import gleam/string
import gleam/time/duration
import gleam/time/timestamp
import ical
import log
import state.{type IcalUrl}

/// Fetch events from a list of external iCal feed URLs.
/// Returns (calendar_names, events). Failures for individual feeds are
/// logged and skipped — one broken URL won't block the others.
pub fn fetch_all(
  urls: List(IcalUrl),
) -> #(List(String), List(Event)) {
  let results = list.map(urls, fetch_one)
  let names = list.map(urls, fn(u) { u.name })
  let events = list.flat_map(results, fn(r) { result.unwrap(r, []) })
  #(names, events)
}

/// Fetch and parse events from a single iCal feed URL.
fn fetch_one(ical_url: IcalUrl) -> Result(List(Event), String) {
  log.println("[ical_fetch] fetching " <> ical_url.name <> ": " <> ical_url.url)

  use base_req <- result.try(
    request.to(ical_url.url)
    |> result.map_error(fn(_) { "Invalid URL: " <> ical_url.url }),
  )

  let req =
    base_req
    |> request.set_method(http.Get)
    |> request.set_body(bytes_tree.new())

  use resp <- result.try(
    hackney.send_bits(req)
    |> result.map_error(fn(err) {
      let msg =
        "[ical_fetch] HTTP request failed for "
        <> ical_url.name
        <> ": "
        <> string.inspect(err)
      log.println(msg)
      msg
    }),
  )

  case resp.status >= 200 && resp.status < 300 {
    False -> {
      let msg =
        "[ical_fetch] HTTP "
        <> string.inspect(resp.status)
        <> " from "
        <> ical_url.name
      log.println(msg)
      Error(msg)
    }
    True -> {
      let body_str =
        bit_array.to_string(resp.body)
        |> result.unwrap("")

      let now = timestamp.system_time()
      let window_start = timestamp.add(now, duration.seconds(-2 * 86_400))
      let window_end = timestamp.add(now, duration.seconds(7 * 86_400))

      let events =
        ical.parse_events(body_str, ical_url.name, window_start, window_end)

      log.println(
        "[ical_fetch] parsed "
        <> string.inspect(list.length(events))
        <> " events from "
        <> ical_url.name,
      )

      Ok(events)
    }
  }
}
