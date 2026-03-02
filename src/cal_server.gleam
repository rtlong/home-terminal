// Calendar server OTP actor.
//
// A singleton actor that:
//   - On start, immediately loads the event cache and calendar config from disk.
//   - Schedules a periodic CalDAV re-fetch every POLL_INTERVAL_MS milliseconds.
//   - Keeps the latest events + config in its state.
//   - Allows per-connection clients to register a callback for updates.
//
// Clients register a fn(CalendarData) -> Nil callback. This keeps cal_server
// free of any dependency on tabs.gleam (no import cycle).

// IMPORTS ---------------------------------------------------------------------

import cal.{type Event}
import cal_dav
import demo_data
import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/otp/actor
import gleam/string
import gleam/time/calendar
import gleam/time/timestamp
import ical_fetch
import log
import state
import travel

// CONSTANTS -------------------------------------------------------------------

/// How often to re-fetch from CalDAV, in milliseconds (5 minutes).
const poll_interval_ms = 300_000

// TYPES -----------------------------------------------------------------------

/// The calendar payload pushed to registered clients on every update.
pub type CalendarData {
  CalendarData(
    events: Result(List(Event), String),
    calendar_names: List(String),
    cal_config: state.Config,
    fetched_at: Int,
    /// Home→location info cache, keyed by location string.
    travel_cache: dict.Dict(String, cal.TravelInfo),
    /// Point-to-point leg durations in seconds, keyed by leg_cache_key/2.
    leg_cache: cal.LegCache,
  )
}

/// A client callback that receives CalendarData updates.
pub type ClientCallback =
  fn(CalendarData) -> Nil

/// Messages this actor handles.
pub opaque type Msg {
  ClientConnected(id: Int, callback: ClientCallback)
  ClientDisconnected(id: Int)
  FetchCompleted(
    dav_result: Result(#(List(String), List(Event)), String),
    ics_result: ical_fetch.FetchResult,
  )
  PollTimerFired
  UpdateCalendarConfig(name: String, config: state.CalendarConfig)
  UpdateCalendarPeople(cal_name: String, people: List(String))
  UpdatePersonColor(person: String, color: String)
}

type Client {
  Client(id: Int, callback: ClientCallback)
}

/// State held by the actor.
type State {
  State(
    self: Subject(Msg),
    dav_config: cal_dav.Config,
    /// XDG_CONFIG_HOME/home-terminal — for config.json.
    config_dir: String,
    /// XDG_CACHE_HOME/home-terminal — for cache.json, travel_cache.json, ical_cache.json.
    cache_dir: String,
    clients: List(Client),
    events: Result(List(Event), String),
    calendar_names: List(String),
    cal_config: state.Config,
    fetched_at: Int,
    /// Home→location info cache keyed by location string.
    travel_cache: dict.Dict(String, cal.TravelInfo),
    /// Point-to-point leg durations in seconds, keyed by leg_cache_key.
    leg_cache: cal.LegCache,
    /// Per-iCal-feed last-fetched timestamp (URL → unix seconds).
    ical_last_fetched: dict.Dict(String, Int),
    /// Per-iCal-feed cached events (URL → events from last fetch).
    ical_cached_events: dict.Dict(String, List(Event)),
    /// When set, the server is in demo mode: no CalDAV fetches are performed;
    /// events are generated deterministically from this config on each poll.
    demo_cfg: Option(demo_data.DemoConfig),
  )
}

// PUBLIC API ------------------------------------------------------------------

pub type Server =
  Subject(Msg)

/// A token returned when registering a client, used to deregister later.
pub opaque type Registration {
  Registration(server: Server, id: Int)
}

/// Start the calendar server.
pub fn start(
  dav_config: cal_dav.Config,
  config_dir: String,
  cache_dir: String,
) -> Result(Server, actor.StartError) {
  let result =
    actor.new_with_initialiser(5000, fn(self_subject) {
      process.send(self_subject, PollTimerFired)

      log.println("[cal_server] config_dir: " <> config_dir)
      log.println("[cal_server] cache_dir:  " <> cache_dir)

      // Load cached events so clients get data immediately, before the first fetch.
      let cache_path = cache_dir <> "/cache.json"
      let cached = state.read_cache(cache_dir)
      let initial_events = case cached {
        [] -> {
          log.println("[cal_server] " <> cache_path <> " — not found or empty")
          Error("Loading…")
        }
        events -> {
          log.println(
            "[cal_server] " <> cache_path <> " — loaded "
            <> string.inspect(list.length(events))
            <> " events",
          )
          Ok(events)
        }
      }

      let config_path = config_dir <> "/config.json"
      let cal_config = state.read_config(config_dir)
      log.println(
        "[cal_server] " <> config_path <> " — loaded ("
        <> string.inspect(list.length(cal_config.people))
        <> " people, "
        <> string.inspect(list.length(cal_config.ical_urls))
        <> " ical urls)",
      )

      let travel_path = cache_dir <> "/travel_cache.json"
      let travel_caches = state.read_travel_caches(cache_dir)
      log.println(
        "[cal_server] " <> travel_path <> " — loaded "
        <> string.inspect(dict.size(travel_caches.travel_cache))
        <> " travel entries, "
        <> string.inspect(dict.size(travel_caches.leg_cache))
        <> " leg entries",
      )

      let ical_path = cache_dir <> "/ical_cache.json"
      let ical_cache = state.read_ical_cache(cache_dir)
      log.println(
        "[cal_server] " <> ical_path <> " — loaded "
        <> string.inspect(dict.size(ical_cache.last_fetched))
        <> " feed caches",
      )
      // Derive calendar names from cached events so the palette can assign
      // colors immediately on startup, before the first live CalDAV fetch.
      let initial_calendar_names =
        cached
        |> list.map(fn(e) { e.calendar_name })
        |> list.unique
        |> list.sort(string.compare)
      let actor_state =
        State(
          self: self_subject,
          dav_config: dav_config,
          config_dir: config_dir,
          cache_dir: cache_dir,
          clients: [],
          events: initial_events,
          calendar_names: initial_calendar_names,
          cal_config: cal_config,
          fetched_at: 0,
          travel_cache: travel_caches.travel_cache,
          leg_cache: travel_caches.leg_cache,
          ical_last_fetched: ical_cache.last_fetched,
          ical_cached_events: ical_cache.cached_events,
          demo_cfg: None,
        )
      actor.initialised(actor_state) |> actor.returning(self_subject) |> Ok
    })
    |> actor.on_message(handle_message)
    |> actor.start

  case result {
    Ok(started) -> Ok(started.data)
    Error(err) -> Error(err)
  }
}

/// Start the calendar server in demo mode.
/// No CalDAV credentials are required.  Events are generated from a seed that
/// is randomised on each boot (or taken from DEMO_SEED for reproduction).
pub fn start_demo() -> Result(Server, actor.StartError) {
  let seed = demo_data.make_seed()
  let demo_cfg = demo_data.generate_config(seed)

  log.println(
    "[cal_server] demo mode — seed "
    <> string.inspect(seed)
    <> "  (set DEMO_SEED="
    <> string.inspect(seed)
    <> " to reproduce)",
  )

  let result =
    actor.new_with_initialiser(5000, fn(self_subject) {
      process.send(self_subject, PollTimerFired)
      let actor_state =
        State(
          self: self_subject,
          dav_config: cal_dav.empty_config(),
          config_dir: "",
          cache_dir: "",
          clients: [],
          events: Error("Loading…"),
          calendar_names: [],
          cal_config: demo_cfg.config,
          fetched_at: 0,
          travel_cache: demo_cfg.travel_cache,
          leg_cache: demo_cfg.leg_cache,
          ical_last_fetched: dict.new(),
          ical_cached_events: dict.new(),
          demo_cfg: Some(demo_cfg),
        )
      actor.initialised(actor_state) |> actor.returning(self_subject) |> Ok
    })
    |> actor.on_message(handle_message)
    |> actor.start

  case result {
    Ok(started) -> Ok(started.data)
    Error(err) -> Error(err)
  }
}

/// Register a callback to be called with CalendarData whenever it updates.
/// Returns a Registration token that can be passed to deregister/2.
/// The callback is also called immediately with the current data.
pub fn register(server: Server, callback: ClientCallback) -> Registration {
  let id = unique_integer()
  process.send(server, ClientConnected(id:, callback:))
  Registration(server:, id:)
}

/// Deregister a previously registered callback.
pub fn deregister(registration: Registration) -> Nil {
  process.send(registration.server, ClientDisconnected(registration.id))
}

/// Update the config for a single calendar by name, persist it, and broadcast
/// the new CalendarData to all registered clients.
pub fn update_calendar_config(
  server: Server,
  name: String,
  config: state.CalendarConfig,
) -> Nil {
  process.send(server, UpdateCalendarConfig(name:, config:))
}

/// Update which people are assigned to a calendar, persist, and broadcast.
pub fn update_calendar_people(
  server: Server,
  cal_name: String,
  people: List(String),
) -> Nil {
  process.send(server, UpdateCalendarPeople(cal_name:, people:))
}

/// Update the color for a single person, persist, and broadcast.
pub fn update_person_color(server: Server, person: String, color: String) -> Nil {
  process.send(server, UpdatePersonColor(person:, color:))
}

/// A placeholder Registration for use before the real one arrives.
/// The server field points nowhere useful; this must be replaced before
/// any deregister call. Tabs replaces it immediately via GotRegistration.
pub fn placeholder_registration() -> Registration {
  let subject = process.new_subject()
  Registration(server: subject, id: -1)
}

// INTERNAL --------------------------------------------------------------------

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int

fn broadcast(state: State) -> Nil {
  let data =
    CalendarData(
      events: state.events,
      calendar_names: state.calendar_names,
      cal_config: state.cal_config,
      fetched_at: state.fetched_at,
      travel_cache: state.travel_cache,
      leg_cache: state.leg_cache,
    )
  list.each(state.clients, fn(c) { c.callback(data) })
}

fn handle_message(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    ClientConnected(id:, callback:) -> {
      // Send current data immediately so new client doesn't wait for next poll.
      callback(CalendarData(
        events: state.events,
        calendar_names: state.calendar_names,
        cal_config: state.cal_config,
        fetched_at: state.fetched_at,
        travel_cache: state.travel_cache,
        leg_cache: state.leg_cache,
      ))
      actor.continue(
        State(..state, clients: [Client(id:, callback:), ..state.clients]),
      )
    }

    ClientDisconnected(id:) ->
      actor.continue(
        State(
          ..state,
          clients: list.filter(state.clients, fn(c) { c.id != id }),
        ),
      )

    PollTimerFired -> {
      process.send_after(state.self, poll_interval_ms, PollTimerFired)
      |> ignore_timer
      case state.demo_cfg {
        // ── Demo mode: generate events deterministically, no network I/O ──
        Some(demo_cfg) -> {
          let now = timestamp.system_time()
          let today = timestamp.to_calendar(now, calendar.local_offset()).0
          let #(events, cal_names) = demo_data.generate_events(demo_cfg, today)
          log.println(
            "[cal_server] demo — generated "
            <> string.inspect(list.length(events))
            <> " events",
          )
          let new_state =
            State(
              ..state,
              events: Ok(events),
              calendar_names: cal_names,
              fetched_at: unix_seconds_now(),
            )
          broadcast(new_state)
          actor.continue(new_state)
        }
        // ── Normal mode: spawn a fetch process ────────────────────────────
        None -> {
          log.println("[cal_server] fetching events...")
          let self = state.self
          let dav_config = state.dav_config
          let ical_urls = state.cal_config.ical_urls
          let ical_lf = state.ical_last_fetched
          let ical_ce = state.ical_cached_events
          process.spawn(fn() {
            let dav_result = cal_dav.fetch_events(dav_config)
            let now_secs = unix_seconds_now()
            let ics_result =
              ical_fetch.fetch_all(ical_urls, now_secs, ical_lf, ical_ce)
            process.send(self, FetchCompleted(dav_result:, ics_result:))
          })
          actor.continue(state)
        }
      }
    }

    FetchCompleted(dav_result:, ics_result:) -> {
      // Merge CalDAV and ICS results. ICS events are always present
      // (cached from previous cycles for feeds not yet due for refresh).
      let merged = case dav_result {
        Ok(#(dav_names, dav_events)) ->
          Ok(#(
            list.append(dav_names, ics_result.names),
            list.append(dav_events, ics_result.events),
          ))
        Error(err) ->
          case ics_result.events {
            // No iCal events either — fall back to whatever we already have
            // cached in state rather than clobbering the UI with an error.
            [] ->
              case state.events {
                Ok(cached) -> {
                  log.println(
                    "[cal_server] fetch error: "
                    <> err
                    <> " — keeping "
                    <> string.inspect(list.length(cached))
                    <> " cached events",
                  )
                  Ok(#(state.calendar_names, cached))
                }
                Error(_) -> Error(err)
              }
            _ -> Ok(#(ics_result.names, ics_result.events))
          }
      }
      let new_state = case merged {
        Ok(#(cal_names, events)) -> {
          let now_secs = unix_seconds_now()
          log.println(
            "[cal_server] fetched "
            <> string.inspect(list.length(events))
            <> " events from "
            <> string.inspect(list.length(cal_names))
            <> " calendars",
          )
          state.write_cache(state.cache_dir, events)

          // ── Geocode home address for sunrise/sunset if not yet cached ──────────
          let new_cal_config = case
            state.get_secret("google_maps_api_key", "GOOGLE_MAPS_API_KEY"),
            state.cal_config.home_address,
            state.cal_config.latitude == 0.0
            && state.cal_config.longitude == 0.0
          {
            Ok(api_key), home_address, True if home_address != "" -> {
              case travel.geocode_address(home_address, api_key) {
                Ok(loc) -> {
                  log.println(
                    "[cal_server] geocoded home address: lat="
                    <> string.inspect(loc.lat)
                    <> " lng="
                    <> string.inspect(loc.lng),
                  )
                  let updated =
                    state.Config(
                      ..state.cal_config,
                      latitude: loc.lat,
                      longitude: loc.lng,
                    )
                  state.write_config(state.config_dir, updated)
                  updated
                }
                Error(err) -> {
                  log.println("[cal_server] geocode failed: " <> err)
                  state.cal_config
                }
              }
            }
            _, _, _ -> state.cal_config
          }

          let #(new_travel_cache, new_leg_cache) = case
            state.get_secret("google_maps_api_key", "GOOGLE_MAPS_API_KEY"),
            new_cal_config.home_address
          {
            Ok(api_key), home_address if home_address != "" -> {
              // ── Phase A: home→loc for each new unique location ──────────────
              let new_locations =
                events
                |> list.filter_map(fn(e) {
                  case e.location {
                    "" -> Error(Nil)
                    loc ->
                      case dict.has_key(state.travel_cache, loc) {
                        True -> Error(Nil)
                        False -> Ok(loc)
                      }
                  }
                })
                |> list.unique

              let updated_travel_cache =
                list.fold(new_locations, state.travel_cache, fn(cache, loc) {
                  case travel.get_travel_info(home_address, loc, api_key) {
                    Ok(r) ->
                      dict.insert(
                        cache,
                        loc,
                        cal.TravelInfo(
                          city: r.city,
                          distance_text: r.distance_text,
                          duration_text: r.duration_text,
                          duration_secs: r.duration_secs,
                        ),
                      )
                    Error(err) -> {
                      log.println(
                        "[cal_server] home→loc failed for \""
                        <> loc
                        <> "\": "
                        <> err,
                      )
                      cache
                    }
                  }
                })

              // Seed leg cache with home→loc entries from travel cache
              // (these come free from get_travel_info, no extra API calls needed).
              let leg_cache_with_home_fwd =
                dict.fold(
                  updated_travel_cache,
                  state.leg_cache,
                  fn(cache, loc, info) {
                    let key = travel.leg_cache_key(home_address, loc)
                    case dict.has_key(cache, key) {
                      True -> cache
                      False -> dict.insert(cache, key, info.duration_secs)
                    }
                  },
                )

              // ── Phase B: point-to-point legs for routing ─────────────────────
              // We need: loc→home, and loc_a→loc_b for each consecutive
              // located-event pair on the same day.
              let all_locs =
                events
                |> list.filter_map(fn(e) {
                  case e.location {
                    "" -> Error(Nil)
                    loc -> Ok(loc)
                  }
                })
                |> list.unique

              // loc → home for each location.
              let reverse_legs =
                list.map(all_locs, fn(loc) { #(loc, home_address) })

              // Consecutive pairs of located events within the same day.
              let pair_legs = consecutive_located_pairs(events)

              // Merge all required legs, deduplicate, skip already cached.
              let all_required_legs =
                list.append(reverse_legs, pair_legs)
                |> list.unique
                |> list.filter(fn(pair) {
                  let #(o, d) = pair
                  !dict.has_key(
                    leg_cache_with_home_fwd,
                    travel.leg_cache_key(o, d),
                  )
                })

              log.println(
                "[cal_server] fetching "
                <> string.inspect(list.length(all_required_legs))
                <> " new legs",
              )

              let updated_leg_cache =
                list.fold(
                  all_required_legs,
                  leg_cache_with_home_fwd,
                  fn(cache, pair) {
                    let #(o, d) = pair
                    case travel.get_leg(o, d, api_key) {
                      Ok(leg) -> {
                        log.println(
                          "[cal_server] leg ok \""
                          <> o
                          <> "\"→\""
                          <> d
                          <> "\": "
                          <> string.inspect(leg.duration_secs)
                          <> "s",
                        )
                        dict.insert(
                          cache,
                          travel.leg_cache_key(o, d),
                          leg.duration_secs,
                        )
                      }
                      Error(err) -> {
                        log.println(
                          "[cal_server] leg failed \""
                          <> o
                          <> "\"→\""
                          <> d
                          <> "\": "
                          <> err,
                        )
                        cache
                      }
                    }
                  },
                )

              #(updated_travel_cache, updated_leg_cache)
            }
            _, _ -> #(state.travel_cache, state.leg_cache)
          }

          state.write_travel_caches(
            state.cache_dir,
            new_travel_cache,
            new_leg_cache,
          )
          state.write_ical_cache(
            state.cache_dir,
            ics_result.last_fetched,
            ics_result.cached_events,
          )

          State(
            ..state,
            events: Ok(events),
            calendar_names: cal_names,
            cal_config: new_cal_config,
            fetched_at: now_secs,
            travel_cache: new_travel_cache,
            leg_cache: new_leg_cache,
            ical_last_fetched: ics_result.last_fetched,
            ical_cached_events: ics_result.cached_events,
          )
        }
        Error(err) -> {
          log.println("[cal_server] fetch error: " <> err)
          state.write_ical_cache(
            state.cache_dir,
            ics_result.last_fetched,
            ics_result.cached_events,
          )
          State(
            ..state,
            events: Error(err),
            ical_last_fetched: ics_result.last_fetched,
            ical_cached_events: ics_result.cached_events,
          )
        }
      }
      broadcast(new_state)
      actor.continue(new_state)
    }

    UpdateCalendarConfig(name:, config:) -> {
      let new_calendars = dict.insert(state.cal_config.calendars, name, config)
      let new_cal_config =
        state.Config(..state.cal_config, calendars: new_calendars)
      state.write_config(state.config_dir, new_cal_config)
      let new_state = State(..state, cal_config: new_cal_config)
      broadcast(new_state)
      actor.continue(new_state)
    }

    UpdateCalendarPeople(cal_name:, people:) -> {
      let new_cal_people =
        dict.insert(state.cal_config.calendar_people, cal_name, people)
      let new_cal_config =
        state.Config(..state.cal_config, calendar_people: new_cal_people)
      state.write_config(state.config_dir, new_cal_config)
      let new_state = State(..state, cal_config: new_cal_config)
      broadcast(new_state)
      actor.continue(new_state)
    }

    UpdatePersonColor(person:, color:) -> {
      // color arrives as a hex string from <input type="color">; extract hue.
      let hue = state.hue_from_hex(color)
      let new_colors = dict.insert(state.cal_config.people_colors, person, hue)
      let new_cal_config =
        state.Config(..state.cal_config, people_colors: new_colors)
      state.write_config(state.config_dir, new_cal_config)
      let new_state = State(..state, cal_config: new_cal_config)
      broadcast(new_state)
      actor.continue(new_state)
    }
  }
}

fn ignore_timer(_timer: process.Timer) -> Nil {
  Nil
}

/// Return all consecutive (origin, destination) location pairs across
/// same-day timed events, for point-to-point leg prefetching.
/// Events without a location are skipped (they are "in-place").
fn consecutive_located_pairs(events: List(Event)) -> List(#(String, String)) {
  let local_offset = calendar.local_offset()
  // Group located timed events by calendar date.
  let located_timed =
    list.filter(events, fn(e) {
      case e.start {
        cal.AtTime(_) -> e.location != ""
        cal.AllDay(_) -> False
      }
    })

  // Sort by start time.
  let sorted =
    list.sort(located_timed, fn(a, b) {
      case a.start, b.start {
        cal.AtTime(ta), cal.AtTime(tb) -> timestamp.compare(ta, tb)
        _, _ -> order.Eq
      }
    })

  // Group into days and take consecutive pairs within each day.
  let by_day =
    list.group(sorted, fn(e) {
      case e.start {
        cal.AtTime(ts) -> timestamp.to_calendar(ts, local_offset).0
        cal.AllDay(d) -> d
      }
    })

  dict.values(by_day)
  |> list.flat_map(fn(day_events) {
    case day_events {
      [] | [_] -> []
      _ ->
        list.zip(
          list.take(day_events, list.length(day_events) - 1),
          list.drop(day_events, 1),
        )
        |> list.map(fn(pair) {
          let #(a, b) = pair
          #(a.location, b.location)
        })
    }
  })
}

fn unix_seconds_now() -> Int {
  erlang_system_time_seconds()
}

@external(erlang, "log_ffi", "system_time_seconds")
fn erlang_system_time_seconds() -> Int
