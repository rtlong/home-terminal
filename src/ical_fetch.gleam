// External iCal feed fetcher.
//
// Fetches .ics URLs via HTTP GET and parses the response bodies using
// ical.parse_events. Used alongside the CalDAV client to pull in
// arbitrary external calendar feeds (e.g. shared Google Calendar URLs).
//
// Each feed has a configurable refresh interval. Feeds that were fetched
// recently enough are skipped, and their previously-cached events are
// reused by the caller.

import cal.{type Event}
import gleam/bit_array
import gleam/bytes_tree
import gleam/dict.{type Dict}
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

/// Result of fetching all ICS feeds for one poll cycle.
/// Contains the merged events and updated tracking dicts.
pub type FetchResult {
  FetchResult(
    /// All calendar names from configured ICS feeds.
    names: List(String),
    /// All events (freshly fetched + cached from previous cycles).
    events: List(Event),
    /// Updated last-fetched timestamps (url → unix seconds).
    last_fetched: Dict(String, Int),
    /// Updated per-feed event cache (url → events).
    cached_events: Dict(String, List(Event)),
  )
}

/// Fetch events from external iCal feeds, respecting per-feed refresh intervals.
///
/// Feeds whose refresh interval hasn't elapsed since their last fetch are
/// skipped — their previously-cached events are reused instead.
///
/// `now_secs` is the current unix timestamp in seconds.
/// `last_fetched` maps feed URL → last fetch unix seconds.
/// `cached_events` maps feed URL → previously-fetched events.
pub fn fetch_all(
  urls: List(IcalUrl),
  now_secs: Int,
  last_fetched: Dict(String, Int),
  cached_events: Dict(String, List(Event)),
) -> FetchResult {
  let names = list.map(urls, fn(u) { u.name })

  let #(new_last_fetched, new_cached, all_events) =
    list.fold(urls, #(last_fetched, cached_events, []), fn(acc, feed) {
      let #(lf, ce, evts) = acc
      case is_due(feed, now_secs, lf) {
        True -> {
          let result = fetch_one(feed)
          let feed_events = result.unwrap(result, [])
          #(
            dict.insert(lf, feed.url, now_secs),
            dict.insert(ce, feed.url, feed_events),
            list.append(evts, feed_events),
          )
        }
        False -> {
          // Not due — reuse cached events.
          let feed_events =
            dict.get(ce, feed.url) |> result.unwrap([])
          log.println(
            "[ical_fetch] skipping " <> feed.name <> " (not due for refresh)",
          )
          #(lf, ce, list.append(evts, feed_events))
        }
      }
    })

  FetchResult(
    names:,
    events: all_events,
    last_fetched: new_last_fetched,
    cached_events: new_cached,
  )
}

/// Check whether a feed is due for a refresh.
fn is_due(
  feed: IcalUrl,
  now_secs: Int,
  last_fetched: Dict(String, Int),
) -> Bool {
  let interval_secs = state.parse_refresh_interval(feed.refresh)
  case interval_secs, dict.get(last_fetched, feed.url) {
    // No interval or unrecognised → always fetch.
    0, _ -> True
    // Never fetched before → fetch now.
    _, Error(_) -> True
    // Check if enough time has elapsed.
    interval, Ok(last) -> now_secs - last >= interval
  }
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
