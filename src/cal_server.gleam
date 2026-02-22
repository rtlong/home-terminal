// Calendar server OTP actor.
//
// A singleton actor that:
//   - On start, immediately fetches events from CalDAV.
//   - Schedules a periodic re-fetch every POLL_INTERVAL_MS milliseconds.
//   - Keeps the latest Result(List(Event), String) in its state.
//   - Allows per-connection tabs processes to register/deregister for updates.
//
// When new calendar data arrives, cal_server broadcasts updated DOM patches to
// every registered client subject by calling lustre's runtime patch mechanism.

// IMPORTS ---------------------------------------------------------------------

import cal.{type Event}
import cal_dav
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor
import lustre/server_component

// CONSTANTS -------------------------------------------------------------------

/// How often to re-fetch from CalDAV, in milliseconds (5 minutes).
const poll_interval_ms = 300_000

// TYPES -----------------------------------------------------------------------

/// Messages this actor handles.
pub opaque type Msg {
  /// A connected client (tabs server component) registers to receive updates.
  ClientConnected(subject: Subject(server_component.ClientMessage(TabsMsg)))
  /// A connected client deregisters (its WebSocket closed).
  ClientDisconnected(subject: Subject(server_component.ClientMessage(TabsMsg)))
  /// The periodic CalDAV poll has completed.
  CalDavFetched(Result(List(Event), String))
  /// Internal: the poll timer fired.
  PollTimerFired
}

// Placeholder for tabs.Msg — will be replaced once tabs.gleam is wired up.
type TabsMsg =
  Nil

/// State held by the actor.
type State {
  State(
    // The actor's own subject, used to schedule self-messages for the poll timer.
    self: Subject(Msg),
    // CalDAV configuration.
    config: cal_dav.Config,
    // All currently connected client subjects.
    clients: List(Subject(server_component.ClientMessage(TabsMsg))),
    // Latest successfully fetched events, or an error string.
    events: Result(List(Event), String),
  )
}

// PUBLIC API ------------------------------------------------------------------

pub type Server =
  Subject(Msg)

/// Start the calendar server as a supervised singleton.
/// Returns the Subject used to send it messages.
pub fn start(config: cal_dav.Config) -> Result(Server, actor.StartError) {
  let result =
    actor.new_with_initialiser(5000, fn(self_subject) {
      // Kick off the first poll immediately by sending ourselves a timer message.
      process.send(self_subject, PollTimerFired)

      let state =
        State(
          self: self_subject,
          config: config,
          clients: [],
          events: Error("Loading…"),
        )

      actor.initialised(state)
      |> actor.returning(self_subject)
      |> Ok
    })
    |> actor.on_message(handle_message)
    |> actor.start

  case result {
    Ok(started) -> Ok(started.data)
    Error(err) -> Error(err)
  }
}

/// Register a client subject to receive DOM patch messages when events update.
pub fn register_client(
  server: Server,
  client: Subject(server_component.ClientMessage(TabsMsg)),
) -> Nil {
  process.send(server, ClientConnected(client))
}

/// Deregister a client subject when its connection closes.
pub fn deregister_client(
  server: Server,
  client: Subject(server_component.ClientMessage(TabsMsg)),
) -> Nil {
  process.send(server, ClientDisconnected(client))
}

// INTERNAL --------------------------------------------------------------------

fn handle_message(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    ClientConnected(subject) ->
      actor.continue(State(..state, clients: [subject, ..state.clients]))

    ClientDisconnected(subject) ->
      actor.continue(
        State(
          ..state,
          clients: list.filter(state.clients, fn(s) { s != subject }),
        ),
      )

    PollTimerFired -> {
      // Perform the fetch synchronously in this actor process.
      // For a long-running fetch this could stall message handling; a future
      // improvement would be to spawn a task and send CalDavFetched when done.
      let result = cal_dav.fetch_events(state.config)
      process.send(state.self, CalDavFetched(result))
      // Schedule next poll
      process.send_after(state.self, poll_interval_ms, PollTimerFired)
      |> ignore_timer
      actor.continue(state)
    }

    CalDavFetched(result) -> {
      let new_state = State(..state, events: result)
      // TODO: broadcast updated view patches to all registered clients
      // This requires wiring tabs.Msg properly so we can send lustre patches.
      actor.continue(new_state)
    }
  }
}

fn ignore_timer(_timer: process.Timer) -> Nil {
  Nil
}
