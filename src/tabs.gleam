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
import palette
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
        leg_cache: dict.new(),
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
  UserToggledCalendarPerson(cal_name: String, person: String, assigned: Bool)
  UserChangedPersonColor(person: String, color: String)
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
      let new_cfg = state.CalendarConfig(visible: visible)
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

    UserChangedPersonColor(person:, color:) -> {
      cal_server.update_person_color(model.server, person, color)
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
          // Generate palette from person hues and calendar→people mapping.
          let pal =
            palette.generate(
              cfg.people_colors,
              cfg.people,
              cfg.calendar_people,
              model.calendar_data.calendar_names,
            )
          let color_for = fn(cal_name: String) -> String {
            dict.get(pal.calendar_colors, cal_name)
            |> result.unwrap("oklch(0.65 0.19 250)")
          }
          let visible_events =
            list.filter(events, fn(e) {
              state.get_calendar_config(cfg, e.calendar_name).visible
            })
          // Map each event to (BarPos, color). Color is always the calendar color.
          // Unassigned → BarCenter.
          // Assigned to one person → BarLeft (person 0) or BarRight (person 1).
          // Assigned to both people → BarCenter (one strip in the middle).
          let people = cfg.people
          let bars_for_event = fn(e: cal.Event) -> List(#(cal.BarPos, String)) {
            let assigned =
              dict.get(cfg.calendar_people, e.calendar_name)
              |> result.unwrap([])
            let color = color_for(e.calendar_name)
            case assigned, people {
              // Unassigned
              [], _ -> [#(cal.BarCenter, color)]
              // Assigned to both people → center strip
              [_, _, ..], [_, _, ..] -> [#(cal.BarCenter, color)]
              // Assigned to one person → their bar
              [person, ..], _ -> {
                let bar = case people {
                  [p0, ..] if person == p0 -> cal.BarLeft
                  [_, p1, ..] if person == p1 -> cal.BarRight
                  _ -> cal.BarCenter
                }
                [#(bar, color)]
              }
            }
          }
          html.div(
            [attribute.class("flex flex-col flex-1 min-h-0 overflow-hidden")],
            [
              // Inject palette-derived theme CSS variables.
              html.style([], pal.theme_vars),
              view_fetch_stamp(model.calendar_data.fetched_at),
              cal.view_gantt(
                visible_events,
                color_for,
                model.calendar_data.travel_cache,
                model.calendar_data.leg_cache,
                model.calendar_data.cal_config.home_address,
                bars_for_event,
                cfg.people,
                model.calendar_data.cal_config.latitude,
                model.calendar_data.cal_config.longitude,
              ),
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
  let cfg = model.calendar_data.cal_config
  let people = cfg.people

  // Use the full list of discovered calendar names from the server.
  let cal_names = case model.calendar_data.calendar_names {
    [] ->
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

  // Generate palette so we can show generated color swatches in calendar rows.
  let pal =
    palette.generate(
      cfg.people_colors,
      cfg.people,
      cfg.calendar_people,
      model.calendar_data.calendar_names,
    )
  let color_for = fn(cal_name: String) -> String {
    dict.get(pal.calendar_colors, cal_name)
    |> result.unwrap("oklch(0.65 0.19 250)")
  }

  html.div([attribute.class("p-6 overflow-y-auto h-full flex flex-col gap-8")], [
    view_color_wheel(cfg, pal),
    view_people_settings(cfg),
    html.div([], [
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
        list.map(cal_names, fn(name) {
          view_calendar_row(name, cfg, people, color_for(name))
        }),
      ),
    ]),
  ])
}

fn view_people_settings(cfg: state.Config) -> Element(Msg) {
  let people = cfg.people

  html.div([], [
    html.h2(
      [
        attribute.class(
          "text-sm font-semibold uppercase tracking-wide text-text-muted mb-4",
        ),
      ],
      [html.text("People")],
    ),
    case people {
      [] ->
        html.p([attribute.class("text-xs text-text-muted italic")], [
          html.text("Add people to config.json to assign colors."),
        ])
      _ ->
        html.div(
          [attribute.class("flex flex-col gap-2")],
          list.map(people, fn(person) {
            // hue is a Float angle (0–360). Show a swatch using oklch and an
            // <input type="color"> for picking (browser will extract the hue).
            let hue =
              dict.get(cfg.people_colors, person)
              |> result.unwrap(250.0)
            let swatch_color = "oklch(0.65 0.19 " <> float_to_str(hue) <> ")"
            html.div([attribute.class("flex items-center gap-3")], [
              // Layered swatch: the real <input type="color"> fills the area
              // nearly invisible (opacity ~0) so clicks open the picker.
              // A pointer-events-none div above shows the true oklch color.
              html.div([attribute.class("relative w-7 h-7 shrink-0")], [
                html.input([
                  attribute.type_("color"),
                  attribute.class(
                    "absolute inset-0 w-full h-full rounded cursor-pointer border-0 p-0",
                  ),
                  attribute.style("opacity", "0.001"),
                  on_person_color_change(person),
                ]),
                html.div(
                  [
                    attribute.class(
                      "absolute inset-0 rounded border border-border-dim pointer-events-none",
                    ),
                    attribute.style("background-color", swatch_color),
                  ],
                  [],
                ),
              ]),
              html.span([attribute.class("text-sm text-text")], [
                html.text(person),
              ]),
            ])
          }),
        )
    },
  ])
}

fn view_calendar_row(
  name: String,
  cfg: state.Config,
  people: List(String),
  generated_color: String,
) -> Element(Msg) {
  let cal_cfg = state.get_calendar_config(cfg, name)
  let assigned_people = dict.get(cfg.calendar_people, name) |> result.unwrap([])

  // Generated color swatch (read-only) — shows what color was assigned.
  let color_swatch =
    html.div(
      [
        attribute.class("w-7 h-7 rounded shrink-0"),
        attribute.style("background-color", generated_color),
      ],
      [],
    )

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
        color_swatch,
        html.span([attribute.class("flex-1 text-sm text-text")], [
          html.text(name),
        ]),
        toggle,
      ]),
      person_chips,
    ],
  )
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

/// Decode an input[type=color] change event → UserChangedPersonColor.
fn on_person_color_change(person: String) -> attribute.Attribute(Msg) {
  event.on("change", {
    use color <- decode.subfield(["target", "value"], decode.string)
    decode.success(UserChangedPersonColor(person:, color:))
  })
}

// COLOR WHEEL VISUALIZER ------------------------------------------------------

/// Render a circular hue-wheel showing person hue markers and calendar dots.
///
/// Layout (all px, centered at cx=cy=100 in a 200×200 container):
///   outer_r = 90  — outer edge of the gradient ring
///   ring_w  = 18  — thickness of the gradient ring
///   inner_r = 72  — inner edge of the ring (= outer_r - ring_w)
///   person_r = 81 — radius at which person dots sit (mid-ring)
///   cal_r    = 63 — radius just inside the ring for calendar dots
fn view_color_wheel(cfg: state.Config, pal: palette.Palette) -> Element(Msg) {
  let size = 200
  let cx = 100.0
  let cy = 100.0
  let outer_r = 90.0
  let ring_w = 18.0
  let inner_r = outer_r -. ring_w
  let person_r = inner_r +. ring_w /. 2.0
  let cal_r = inner_r -. 10.0
  let dot_size_person = 14
  let dot_size_cal = 8

  // Place a dot at (cx + r*cos(θ), cy + r*sin(θ)) where θ = hue-90° in radians
  // (subtract 90° so hue=0 (red) sits at 12-o'clock, matching colour-wheel convention).
  let dot_pos = fn(hue: Float, r: Float) -> #(Float, Float) {
    let theta = { hue -. 90.0 } *. 0.017453292519943295
    #(cx +. r *. math_cos(theta), cy +. r *. math_sin(theta))
  }

  // Person dots + labels
  let person_els =
    list.flat_map(cfg.people, fn(person) {
      case dict.get(cfg.people_colors, person) {
        Error(_) -> []
        Ok(hue) -> {
          let #(px, py) = dot_pos(hue, person_r)
          let color = "oklch(0.65 0.19 " <> float_to_str(hue) <> ")"
          let half = int.to_float(dot_size_person) /. 2.0
          // Label: nudge outward from center
          let lx = cx +. { px -. cx } *. 1.55
          let ly = cy +. { py -. cy } *. 1.55
          let anchor = case px >=. cx {
            True -> "start"
            False -> "end"
          }
          [
            // Dot
            html.div(
              [
                attribute.style("position", "absolute"),
                attribute.style("left", float_px(px -. half)),
                attribute.style("top", float_px(py -. half)),
                attribute.style("width", int.to_string(dot_size_person) <> "px"),
                attribute.style(
                  "height",
                  int.to_string(dot_size_person) <> "px",
                ),
                attribute.style("border-radius", "50%"),
                attribute.style("background-color", color),
                attribute.style("border", "2px solid oklch(1 0 0 / 60%)"),
                attribute.style("box-sizing", "border-box"),
              ],
              [],
            ),
            // Label
            html.span(
              [
                attribute.style("position", "absolute"),
                attribute.style("left", float_px(lx)),
                attribute.style("top", float_px(ly -. 5.0)),
                attribute.style("font-size", "9px"),
                attribute.style("font-weight", "600"),
                attribute.style("color", color),
                attribute.style("white-space", "nowrap"),
                attribute.style("transform", "translate(-50%, -50%)"),
                attribute.style("text-align", anchor),
                attribute.style("pointer-events", "none"),
                attribute.style("user-select", "none"),
              ],
              [html.text(person)],
            ),
          ]
        }
      }
    })

  // Calendar dots
  let cal_els =
    list.flat_map(dict.to_list(pal.calendar_colors), fn(pair) {
      let #(cal_name, color_css) = pair
      case palette.parse_hue(color_css) {
        Error(_) -> []
        Ok(hue) -> {
          let #(px, py) = dot_pos(hue, cal_r)
          let half = int.to_float(dot_size_cal) /. 2.0
          [
            html.div(
              [
                attribute.style("position", "absolute"),
                attribute.style("left", float_px(px -. half)),
                attribute.style("top", float_px(py -. half)),
                attribute.style("width", int.to_string(dot_size_cal) <> "px"),
                attribute.style("height", int.to_string(dot_size_cal) <> "px"),
                attribute.style("border-radius", "50%"),
                attribute.style("background-color", color_css),
                attribute.style("title", cal_name),
                attribute.style("border", "1px solid oklch(1 0 0 / 30%)"),
                attribute.style("box-sizing", "border-box"),
              ],
              [],
            ),
          ]
        }
      }
    })

  // Build the conic-gradient stop list: one stop per 10° for a smooth wheel.
  let stops =
    list.map(int_range(0, 36), fn(i) {
      let deg = i * 10
      "oklch(0.65 0.19 "
      <> int.to_string(deg)
      <> "deg) "
      <> int.to_string(deg)
      <> "deg"
    })
    |> string.join(", ")
  let conic = "conic-gradient(" <> stops <> ")"

  let size_px = int.to_string(size) <> "px"

  html.div(
    [
      attribute.style("position", "relative"),
      attribute.style("width", size_px),
      attribute.style("height", size_px),
      attribute.style("flex-shrink", "0"),
    ],
    list.flatten([
      // Gradient ring
      [
        html.div(
          [
            attribute.style("position", "absolute"),
            attribute.style("inset", "0"),
            attribute.style("border-radius", "50%"),
            attribute.style("background", conic),
          ],
          [],
        ),
      ],
      // Inner cutout (donut hole)
      [
        html.div(
          [
            attribute.style("position", "absolute"),
            attribute.style("left", float_px(cx -. inner_r)),
            attribute.style("top", float_px(cy -. inner_r)),
            attribute.style("width", float_px(inner_r *. 2.0)),
            attribute.style("height", float_px(inner_r *. 2.0)),
            attribute.style("border-radius", "50%"),
            attribute.style("background-color", "var(--color-bg)"),
          ],
          [],
        ),
      ],
      cal_els,
      person_els,
    ]),
  )
}

fn int_range(from: Int, to: Int) -> List(Int) {
  int.range(from: from, to: to + 1, with: [], run: fn(acc, i) { [i, ..acc] })
  |> list.reverse
}

// Math FFI (same as palette.gleam — duplicated to avoid cross-module FFI sharing)
@external(erlang, "math", "cos")
fn math_cos(x: Float) -> Float

@external(erlang, "math", "sin")
fn math_sin(x: Float) -> Float

fn float_px(f: Float) -> String {
  float_to_str(f) <> "px"
}

// HELPERS ---------------------------------------------------------------------

/// Format a Float hue angle as a short decimal string for CSS.
fn float_to_str(f: Float) -> String {
  // Use gleam's string representation and trim excess decimals.
  // float.to_string gives e.g. "187.0" which is valid in oklch().
  string.inspect(f)
}
