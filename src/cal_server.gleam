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
import envoy
import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/order
import gleam/otp/actor
import gleam/string
import gleam/time/calendar
import gleam/time/timestamp
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
  CalDavFetched(Result(#(List(String), List(Event)), String))
  PollTimerFired
  UpdateCalendarConfig(name: String, config: state.CalendarConfig)
  UpdateCalendarPeople(cal_name: String, people: List(String))
}

type Client {
  Client(id: Int, callback: ClientCallback)
}

/// State held by the actor.
type State {
  State(
    self: Subject(Msg),
    dav_config: cal_dav.Config,
    data_dir: String,
    clients: List(Client),
    events: Result(List(Event), String),
    calendar_names: List(String),
    cal_config: state.Config,
    fetched_at: Int,
    /// Home→location info cache keyed by location string.
    travel_cache: dict.Dict(String, cal.TravelInfo),
    /// Point-to-point leg durations in seconds, keyed by leg_cache_key.
    leg_cache: cal.LegCache,
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
  data_dir: String,
) -> Result(Server, actor.StartError) {
  let result =
    actor.new_with_initialiser(5000, fn(self_subject) {
      process.send(self_subject, PollTimerFired)
      // Load cached events so clients get data immediately, before the first fetch.
      let cached = state.read_cache(data_dir)
      let initial_events = case cached {
        [] -> Error("Loading…")
        events -> Ok(events)
      }
      log.println(
        "[cal_server] loaded "
        <> string.inspect(list.length(cached))
        <> " events from cache",
      )
      let cal_config = state.read_config(data_dir)
      let actor_state =
        State(
          self: self_subject,
          dav_config: dav_config,
          data_dir: data_dir,
          clients: [],
          events: initial_events,
          calendar_names: [],
          cal_config: cal_config,
          fetched_at: 0,
          travel_cache: dict.new(),
          leg_cache: dict.new(),
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
      log.println("[cal_server] fetching events...")
      // Spawn the fetch so the actor mailbox stays unblocked.
      // ClientConnected messages (and the cached-data immediate reply) are
      // processed while the fetch is in flight.
      let self = state.self
      let dav_config = state.dav_config
      process.spawn(fn() {
        let result = cal_dav.fetch_events(dav_config)
        process.send(self, CalDavFetched(result))
      })
      process.send_after(state.self, poll_interval_ms, PollTimerFired)
      |> ignore_timer
      actor.continue(state)
    }

    CalDavFetched(result) -> {
      let new_state = case result {
        Ok(#(cal_names, events)) -> {
          let now_secs = unix_seconds_now()
          log.println(
            "[cal_server] fetched "
            <> string.inspect(list.length(events))
            <> " events from "
            <> string.inspect(list.length(cal_names))
            <> " calendars",
          )
          state.write_cache(state.data_dir, events)

          let #(new_travel_cache, new_leg_cache) = case
            envoy.get("GOOGLE_MAPS_API_KEY"),
            state.cal_config.home_address
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
                  !dict.has_key(state.leg_cache, travel.leg_cache_key(o, d))
                })

              let updated_leg_cache =
                list.fold(all_required_legs, state.leg_cache, fn(cache, pair) {
                  let #(o, d) = pair
                  case travel.get_leg(o, d, api_key) {
                    Ok(leg) ->
                      dict.insert(
                        cache,
                        travel.leg_cache_key(o, d),
                        leg.duration_secs,
                      )
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
                })

              #(updated_travel_cache, updated_leg_cache)
            }
            _, _ -> #(state.travel_cache, state.leg_cache)
          }

          State(
            ..state,
            events: Ok(events),
            calendar_names: cal_names,
            fetched_at: now_secs,
            travel_cache: new_travel_cache,
            leg_cache: new_leg_cache,
          )
        }
        Error(err) -> {
          log.println("[cal_server] fetch error: " <> err)
          State(..state, events: Error(err))
        }
      }
      broadcast(new_state)
      actor.continue(new_state)
    }

    UpdateCalendarConfig(name:, config:) -> {
      let new_calendars = dict.insert(state.cal_config.calendars, name, config)
      let new_cal_config =
        state.Config(..state.cal_config, calendars: new_calendars)
      state.write_config(state.data_dir, new_cal_config)
      let new_state = State(..state, cal_config: new_cal_config)
      broadcast(new_state)
      actor.continue(new_state)
    }

    UpdateCalendarPeople(cal_name:, people:) -> {
      let new_cal_people =
        dict.insert(state.cal_config.calendar_people, cal_name, people)
      let new_cal_config =
        state.Config(..state.cal_config, calendar_people: new_cal_people)
      state.write_config(state.data_dir, new_cal_config)
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
