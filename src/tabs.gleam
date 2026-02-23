// IMPORTS ---------------------------------------------------------------------

import cal
import cal_server.{type Server}
import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import gleam/time/calendar
import gleam/time/timestamp
import lustre.{type App}
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
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
  SettingsTab
}

pub type Model {
  Model(
    active_tab: Tab,
    calendar_data: cal_server.CalendarData,
    registration: cal_server.Registration,
    server: Server,
  )
}

fn tick_effect() -> Effect(Msg) {
  effect.from(fn(dispatch) {
    process.spawn(fn() {
      process.sleep(tick_interval_ms)
      dispatch(Tick)
    })
    Nil
  })
}

fn init(server: Server) -> #(Model, Effect(Msg)) {
  let cal_effect =
    effect.select(fn(dispatch, _subject: process.Subject(Msg)) {
      let registration =
        cal_server.register(server, fn(data) { dispatch(CalendarUpdated(data)) })
      dispatch(GotRegistration(registration))
      process.new_selector()
    })
  let effect = effect.batch([cal_effect, tick_effect()])

  let placeholder = cal_server.placeholder_registration()

  let model =
    Model(
      active_tab: CalendarTab,
      calendar_data: cal_server.CalendarData(
        events: Error("Loading…"),
        calendar_names: [],
        cal_config: state.empty_config(),
        fetched_at: 0,
        travel_cache: dict.new(),
      ),
      registration: placeholder,
      server: server,
    )

  #(model, effect)
}

// UPDATE ----------------------------------------------------------------------

pub opaque type Msg {
  UserSelectedTab(Tab)
  CalendarUpdated(cal_server.CalendarData)
  GotRegistration(cal_server.Registration)
  UserToggledCalendar(name: String, visible: Bool)
  UserChangedColor(name: String, color: String)
  UserToggledCalendarPerson(cal_name: String, person: String, assigned: Bool)
  Tick
}

const tick_interval_ms = 30_000

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

    UserToggledCalendar(name:, visible:) -> {
      let current =
        state.get_calendar_config(model.calendar_data.cal_config, name)
      let new_cfg = state.CalendarConfig(..current, visible: visible)
      cal_server.update_calendar_config(model.server, name, new_cfg)
      #(model, effect.none())
    }

    UserChangedColor(name:, color:) -> {
      let current =
        state.get_calendar_config(model.calendar_data.cal_config, name)
      let new_cfg = state.CalendarConfig(..current, color: color)
      cal_server.update_calendar_config(model.server, name, new_cfg)
      #(model, effect.none())
    }

    UserToggledCalendarPerson(cal_name:, person:, assigned:) -> {
      let current_people =
        model.calendar_data.cal_config.calendar_people
        |> dict.get(cal_name)
        |> result.unwrap([])
      let new_people = case assigned {
        True ->
          case list.contains(current_people, person) {
            True -> current_people
            False -> [person, ..current_people]
          }
        False -> list.filter(current_people, fn(p) { p != person })
      }
      cal_server.update_calendar_people(model.server, cal_name, new_people)
      #(model, effect.none())
    }

    Tick -> #(model, tick_effect())
  }
}

// VIEW ------------------------------------------------------------------------

fn view(model: Model) -> Element(Msg) {
  html.div([attribute.class("flex flex-col h-screen")], [
    view_tab_bar(model.active_tab),
    html.div([attribute.class("flex-1 flex flex-col min-h-0 overflow-hidden")], [
      view_active_tab(model),
    ]),
  ])
}

fn view_tab_bar(active: Tab) -> Element(Msg) {
  html.nav(
    [
      attribute.class(
        "flex items-center gap-1 px-3 py-2 border-b border-border shrink-0",
      ),
    ],
    [
      view_tab_button("Calendar", CalendarTab, active),
      view_tab_button("Settings", SettingsTab, active),
      html.div([attribute.class("flex-1 flex justify-end")], [view_clock()]),
    ],
  )
}

fn view_clock() -> Element(Msg) {
  let now = timestamp.system_time()
  let local_offset = calendar.local_offset()
  let #(date, time) = timestamp.to_calendar(now, local_offset)

  let hour = time.hours
  let minute = time.minutes
  let is_pm = hour >= 12
  let display_hour = case hour % 12 {
    0 -> 12
    h -> h
  }
  let ampm = case is_pm {
    True -> "PM"
    False -> "AM"
  }
  let time_str =
    int.to_string(display_hour)
    <> ":"
    <> string.pad_start(int.to_string(minute), 2, "0")
    <> " "
    <> ampm

  let month_str = case date.month {
    calendar.January -> "Jan"
    calendar.February -> "Feb"
    calendar.March -> "Mar"
    calendar.April -> "Apr"
    calendar.May -> "May"
    calendar.June -> "Jun"
    calendar.July -> "Jul"
    calendar.August -> "Aug"
    calendar.September -> "Sep"
    calendar.October -> "Oct"
    calendar.November -> "Nov"
    calendar.December -> "Dec"
  }
  // Compute day-of-week from Unix epoch: Jan 1 1970 was a Thursday (index 3).
  // Days since epoch / 7 remainder gives 0=Thu,1=Fri,2=Sat,3=Sun,4=Mon,5=Tue,6=Wed.
  let days_since_epoch =
    timestamp.to_unix_seconds_and_nanoseconds(now).0 / 86_400
  let weekday_str = case { days_since_epoch % 7 + 7 } % 7 {
    0 -> "Thu"
    1 -> "Fri"
    2 -> "Sat"
    3 -> "Sun"
    4 -> "Mon"
    5 -> "Tue"
    _ -> "Wed"
  }
  let date_str =
    weekday_str <> " " <> month_str <> " " <> int.to_string(date.day)

  html.div([attribute.class("flex items-baseline gap-3 select-none")], [
    html.span(
      [
        attribute.class(
          "text-5xl font-bold tabular-nums text-text leading-none",
        ),
      ],
      [html.text(time_str)],
    ),
    html.span([attribute.class("text-lg font-medium text-text-muted")], [
      html.text(date_str),
    ]),
  ])
}

fn view_tab_button(label: String, tab: Tab, active: Tab) -> Element(Msg) {
  let is_active = tab == active
  let classes = case is_active {
    True -> "px-3 py-1 text-sm rounded bg-surface-2 text-text font-medium"
    False ->
      "px-3 py-1 text-sm rounded text-text-muted hover:text-text hover:bg-surface-2/50"
  }
  html.button([attribute.class(classes), event.on_click(UserSelectedTab(tab))], [
    html.text(label),
  ])
}

fn view_active_tab(model: Model) -> Element(Msg) {
  case model.active_tab {
    CalendarTab ->
      case model.calendar_data.events {
        Error(reason) if reason == "Loading…" -> cal.view_loading()
        Error(reason) -> cal.view_error(reason)
        Ok(events) -> {
          let cfg = model.calendar_data.cal_config
          let color_for = fn(cal_name: String) -> String {
            state.get_calendar_config(cfg, cal_name).color
          }
          let visible_events =
            list.filter(events, fn(e) {
              state.get_calendar_config(cfg, e.calendar_name).visible
            })
          html.div(
            [attribute.class("flex flex-col flex-1 min-h-0 overflow-hidden")],
            [
              view_fetch_stamp(model.calendar_data.fetched_at),
              cal.view_seven_days(visible_events, color_for),
            ],
          )
        }
      }

    SettingsTab -> view_settings(model)
  }
}

fn view_fetch_stamp(fetched_at: Int) -> Element(Msg) {
  let label = case fetched_at {
    0 -> "not yet fetched"
    secs -> {
      let now_secs =
        timestamp.to_unix_seconds_and_nanoseconds(timestamp.system_time()).0
      let age_secs = now_secs - secs
      case age_secs {
        s if s < 60 -> "updated just now"
        s if s < 3600 -> "updated " <> int.to_string(s / 60) <> " min ago"
        s -> "updated " <> int.to_string(s / 3600) <> " hr ago"
      }
    }
  }
  html.div(
    [
      attribute.class(
        "shrink-0 px-3 py-0.5 text-right text-text-faint select-none",
      ),
      attribute.style("font-size", "9px"),
    ],
    [html.text(label)],
  )
}

// SETTINGS VIEW ---------------------------------------------------------------

fn view_settings(model: Model) -> Element(Msg) {
  // Use the full list of discovered calendar names from the server.
  // Falls back to names inferred from events if the fetch hasn't run yet.
  let cal_names = case model.calendar_data.calendar_names {
    [] ->
      // Pre-fetch: derive names from any cached events we have
      case model.calendar_data.events {
        Error(_) -> []
        Ok(events) ->
          events
          |> list.map(fn(e) { e.calendar_name })
          |> list.unique
          |> list.sort(string.compare)
      }
    names -> list.sort(names, string.compare)
  }

  let cfg = model.calendar_data.cal_config
  let people = cfg.people

  html.div([attribute.class("p-6 overflow-y-auto h-full")], [
    html.h2(
      [
        attribute.class(
          "text-sm font-semibold uppercase tracking-wide text-text-muted mb-4",
        ),
      ],
      [html.text("Calendars")],
    ),
    html.ul(
      [attribute.class("flex flex-col gap-2")],
      list.map(cal_names, fn(name) { view_calendar_row(name, cfg, people) }),
    ),
  ])
}

fn view_calendar_row(
  name: String,
  cfg: state.Config,
  people: List(String),
) -> Element(Msg) {
  let cal_cfg = state.get_calendar_config(cfg, name)
  let assigned_people = dict.get(cfg.calendar_people, name) |> result.unwrap([])

  // Color picker: native <input type="color"> styled as a small swatch.
  // The `change` event fires with { target: { value: "#rrggbb" } }.
  let color_input =
    html.input([
      attribute.type_("color"),
      attribute.value(cal_cfg.color),
      attribute.class(
        "w-7 h-7 rounded cursor-pointer border-0 bg-transparent p-0",
      ),
      on_color_change(name),
    ])

  // Visibility toggle checkbox.
  // The `change` event fires with { target: { checked: Bool } }.
  let toggle =
    html.input([
      attribute.type_("checkbox"),
      attribute.class("w-4 h-4 rounded accent-emerald-500 cursor-pointer"),
      attribute.checked(cal_cfg.visible),
      on_toggle_change(name),
    ])

  // Per-person assignment checkboxes — only shown when people list is non-empty.
  let person_chips = case people {
    [] -> element.none()
    _ ->
      html.div(
        [attribute.class("flex flex-wrap gap-2 mt-1")],
        list.map(people, fn(person) {
          let is_assigned = list.contains(assigned_people, person)
          html.label(
            [
              attribute.class(
                "flex items-center gap-1 cursor-pointer select-none",
              ),
            ],
            [
              html.input([
                attribute.type_("checkbox"),
                attribute.class(
                  "w-3.5 h-3.5 rounded accent-accent cursor-pointer",
                ),
                attribute.checked(is_assigned),
                on_person_toggle_change(name, person),
              ]),
              html.span([attribute.class("text-xs text-text-muted")], [
                html.text(person),
              ]),
            ],
          )
        }),
      )
  }

  html.li(
    [
      attribute.class(
        "flex flex-col gap-1 px-3 py-2 rounded-lg bg-surface border border-border",
      ),
    ],
    [
      html.div([attribute.class("flex items-center gap-3")], [
        color_input,
        html.span([attribute.class("flex-1 text-sm text-text")], [
          html.text(name),
        ]),
        toggle,
      ]),
      person_chips,
    ],
  )
}

/// Decode an `input[type=color]` change event → UserChangedColor.
/// The browser fires: Event { target: { value: "#rrggbb" } }
fn on_color_change(name: String) -> attribute.Attribute(Msg) {
  event.on("change", {
    use value <- decode.subfield(["target", "value"], decode.string)
    decode.success(UserChangedColor(name:, color: value))
  })
}

/// Decode a checkbox change event → UserToggledCalendar.
/// The browser fires: Event { target: { checked: Bool } }
fn on_toggle_change(name: String) -> attribute.Attribute(Msg) {
  event.on("change", {
    use checked <- decode.subfield(["target", "checked"], decode.bool)
    decode.success(UserToggledCalendar(name:, visible: checked))
  })
}

/// Decode a checkbox change event → UserToggledCalendarPerson.
fn on_person_toggle_change(
  cal_name: String,
  person: String,
) -> attribute.Attribute(Msg) {
  event.on("change", {
    use assigned <- decode.subfield(["target", "checked"], decode.bool)
    decode.success(UserToggledCalendarPerson(cal_name:, person:, assigned:))
  })
}
