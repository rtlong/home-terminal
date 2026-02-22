// IMPORTS ---------------------------------------------------------------------

import cal
import lustre.{type App}
import lustre/element.{type Element}
import lustre/element/html

// COMPONENT -------------------------------------------------------------------

/// Per-connection server component. Owns tab selection state. Calendar data
/// itself lives in the shared calendar_server OTP actor; this component will
/// subscribe to it once that is wired up.
pub fn component() -> App(_, Model, Msg) {
  lustre.simple(init, update, view)
}

// MODEL -----------------------------------------------------------------------

pub type Tab {
  CalendarTab
}

pub type Model {
  Model(active_tab: Tab)
}

fn init(_) -> Model {
  Model(active_tab: CalendarTab)
}

// UPDATE ----------------------------------------------------------------------

pub opaque type Msg {
  UserSelectedTab(Tab)
}

fn update(model: Model, msg: Msg) -> Model {
  case msg {
    UserSelectedTab(tab) -> Model(..model, active_tab: tab)
  }
}

// VIEW ------------------------------------------------------------------------

fn view(model: Model) -> Element(Msg) {
  html.div([], [
    view_tab_bar(model.active_tab),
    view_active_tab(model.active_tab),
  ])
}

fn view_tab_bar(active: Tab) -> Element(Msg) {
  html.nav([], [
    view_tab_button("Calendar", CalendarTab, active),
  ])
}

fn view_tab_button(label: String, tab: Tab, active: Tab) -> Element(Msg) {
  let _ = tab
  let _ = active
  // TODO: wire up on_click and active styling
  html.button([], [html.text(label)])
}

fn view_active_tab(tab: Tab) -> Element(Msg) {
  case tab {
    CalendarTab -> cal.view_loading()
  }
}
