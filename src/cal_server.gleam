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
import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor
import gleam/string
import log
import state

// CONSTANTS -------------------------------------------------------------------

/// How often to re-fetch from CalDAV, in milliseconds (5 minutes).
const poll_interval_ms = 300_000

// TYPES -----------------------------------------------------------------------

/// The calendar payload pushed to registered clients on every update.
/// Carries the event list result, the full list of discovered calendar names
/// (even those with zero events in the window), the display config, and the
/// Unix timestamp of the last successful CalDAV fetch (0 = not yet fetched).
pub type CalendarData {
  CalendarData(
    events: Result(List(Event), String),
    calendar_names: List(String),
    cal_config: state.Config,
    fetched_at: Int,
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
          State(
            ..state,
            events: Ok(events),
            calendar_names: cal_names,
            fetched_at: now_secs,
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
  }
}

fn ignore_timer(_timer: process.Timer) -> Nil {
  Nil
}

fn unix_seconds_now() -> Int {
  erlang_system_time_seconds()
}

@external(erlang, "log_ffi", "system_time_seconds")
fn erlang_system_time_seconds() -> Int
