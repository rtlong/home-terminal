// IMPORTS ---------------------------------------------------------------------

import cal
import cal_server.{type Server}
import gleam/erlang/process
import lustre.{type App}
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import state

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
    calendar_data: cal_server.CalendarData,
    registration: cal_server.Registration,
  )
}

fn init(server: Server) -> #(Model, Effect(Msg)) {
  let effect =
    effect.select(fn(dispatch, _subject: process.Subject(Msg)) {
      let registration =
        cal_server.register(server, fn(data) { dispatch(CalendarUpdated(data)) })
      dispatch(GotRegistration(registration))
      process.new_selector()
    })

  let placeholder = cal_server.placeholder_registration()

  let model =
    Model(
      active_tab: CalendarTab,
      calendar_data: cal_server.CalendarData(
        events: Error("Loading…"),
        cal_config: state.empty_config(),
      ),
      registration: placeholder,
    )

  #(model, effect)
}

// UPDATE ----------------------------------------------------------------------

pub opaque type Msg {
  UserSelectedTab(Tab)
  CalendarUpdated(cal_server.CalendarData)
  GotRegistration(cal_server.Registration)
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    GotRegistration(registration) -> #(
      Model(..model, registration: registration),
      effect.none(),
    )

    UserSelectedTab(tab) -> #(Model(..model, active_tab: tab), effect.none())

    CalendarUpdated(data) -> #(
      Model(..model, calendar_data: data),
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
      case model.calendar_data.events {
        Error(reason) if reason == "Loading…" -> cal.view_loading()
        Error(reason) -> cal.view_error(reason)
        Ok(events) -> {
          let color_for = fn(cal_name: String) -> String {
            state.get_calendar_config(model.calendar_data.cal_config, cal_name).color
          }
          cal.view_seven_days(events, color_for)
        }
      }
  }
}
