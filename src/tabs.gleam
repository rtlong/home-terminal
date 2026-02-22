// IMPORTS ---------------------------------------------------------------------

import cal.{type Event}
import cal_server.{type Server}
import gleam/erlang/process
import lustre.{type App}
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html

// COMPONENT -------------------------------------------------------------------

/// Per-connection server component. Owns tab selection state and the calendar
/// event cache for this connection. Calendar data is pushed in by cal_server
/// via a registered callback.
///
/// Takes a cal_server.Server as its start argument so it knows where to
/// subscribe for updates.
pub fn component() -> App(Server, Model, Msg) {
  lustre.application(init, update, view)
}

// MODEL -----------------------------------------------------------------------

pub type Tab {
  CalendarTab
}

pub type Model {
  Model(
    active_tab: Tab,
    events: Result(List(Event), String),
    registration: cal_server.Registration,
  )
}

fn init(server: Server) -> #(Model, Effect(Msg)) {
  // Register a callback with cal_server. The callback runs in the cal_server
  // actor process, so it must be a quick non-blocking operation: we just send
  // a message to this component's runtime via a Subject.
  //
  // We use server_component.select (via effect.select) to obtain a
  // Subject(Msg) from the Lustre runtime, then register a closure that sends
  // CalendarUpdated to that subject whenever cal_server has new data.
  let effect =
    effect.select(fn(dispatch, _subject: process.Subject(Msg)) {
      // dispatch is fn(Msg) -> Nil — calling it routes a message into update/2
      let registration =
        cal_server.register(server, fn(data) {
          dispatch(CalendarUpdated(data))
        })
      dispatch(GotRegistration(registration))
      process.new_selector()
    })

  // Placeholder registration — replaced immediately when the effect fires.
  let placeholder = cal_server.placeholder_registration()

  let model =
    Model(
      active_tab: CalendarTab,
      events: Error("Loading…"),
      registration: placeholder,
    )

  #(model, effect)
}

// UPDATE ----------------------------------------------------------------------

pub opaque type Msg {
  UserSelectedTab(Tab)
  CalendarUpdated(Result(List(Event), String))
  GotRegistration(cal_server.Registration)
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    GotRegistration(registration) -> #(
      Model(..model, registration: registration),
      effect.none(),
    )

    UserSelectedTab(tab) -> #(
      Model(..model, active_tab: tab),
      effect.none(),
    )

    CalendarUpdated(result) -> #(
      Model(..model, events: result),
      effect.none(),
    )
  }
}

// VIEW ------------------------------------------------------------------------

fn view(model: Model) -> Element(Msg) {
  html.div([], [
    view_tab_bar(model.active_tab),
    view_active_tab(model),
  ])
}

fn view_tab_bar(active: Tab) -> Element(Msg) {
  html.nav([], [
    view_tab_button("Calendar", CalendarTab, active),
  ])
}

fn view_tab_button(label: String, tab: Tab, active: Tab) -> Element(Msg) {
  let _is_active = tab == active
  // TODO: wire up on_click and active styling
  html.button([], [html.text(label)])
}

fn view_active_tab(model: Model) -> Element(Msg) {
  case model.active_tab {
    CalendarTab ->
      case model.events {
        Error(reason) if reason == "Loading…" -> cal.view_loading()
        Error(reason) -> cal.view_error(reason)
        Ok(events) -> cal.view_seven_days(events)
      }
  }
}
