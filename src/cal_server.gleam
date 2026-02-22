// IMPORTS ---------------------------------------------------------------------

import cal.{type Event}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor
import lustre/server_component

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
    // All currently connected client subjects.
    // TODO: replace TabsMsg with tabs.Msg once wired up.
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
pub fn start() -> Result(Server, actor.StartError) {
  // TODO: implement actor.start with poll timer setup
  todo as "calendar_server.start not yet implemented"
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
      // TODO: call caldav.fetch_events() and send CalDavFetched back to self
      actor.continue(state)
    }

    CalDavFetched(result) -> {
      let new_state = State(..state, events: result)
      // TODO: broadcast updated view patches to all registered clients via
      // lustre.send(client, server_component.register_subject(...))
      actor.continue(new_state)
    }
  }
}
