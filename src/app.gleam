// IMPORTS ---------------------------------------------------------------------

import cal_dav
import cal_server
import gleam/bytes_tree
import gleam/erlang/application
import gleam/erlang/process.{type Selector, type Subject}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/json
import gleam/option.{type Option, None, Some}
import lustre
import lustre/attribute
import lustre/element
import lustre/element/html.{html}
import lustre/server_component
import mist.{type Connection, type ResponseData}
import tabs

// MAIN ------------------------------------------------------------------------

pub fn main() {
  // Load CalDAV credentials and start the shared calendar server.
  // Crash hard on misconfiguration rather than silently serving stale data.
  let assert Ok(config) = cal_dav.config_from_env()
  let assert Ok(cal_server) = cal_server.start(config)

  let assert Ok(_) =
    fn(request: Request(Connection)) -> Response(ResponseData) {
      case request.path_segments(request) {
        [] -> serve_html()
        ["lustre", "runtime.mjs"] -> serve_runtime()
        ["ws"] -> serve_tabs(request, cal_server)
        _ -> response.set_body(response.new(404), mist.Bytes(bytes_tree.new()))
      }
    }
    |> mist.new
    |> mist.bind("0.0.0.0")
    |> mist.port(46_548)
    |> mist.start

  process.sleep_forever()
}

// HTML ------------------------------------------------------------------------

fn serve_html() -> Response(ResponseData) {
  let html =
    html([attribute.lang("en")], [
      html.head([], [
        html.meta([attribute.charset("utf-8")]),
        html.meta([
          attribute.name("viewport"),
          attribute.content("width=device-width, initial-scale=1"),
        ]),
        html.title([], "Home Terminal"),
        html.style([], calendar_css()),
        html.script(
          [attribute.type_("module"), attribute.src("/lustre/runtime.mjs")],
          "",
        ),
      ]),
      html.body([], [
        server_component.element([server_component.route("/ws")], []),
      ]),
    ])
    |> element.to_document_string_tree
    |> bytes_tree.from_string_tree

  response.new(200)
  |> response.set_body(mist.Bytes(html))
  |> response.set_header("content-type", "text/html")
}

// CSS -------------------------------------------------------------------------

fn calendar_css() -> String {
  "
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: system-ui, sans-serif; font-size: 14px; background: #111; color: #eee; }
  .cal-seven-days { display: flex; flex-direction: column; gap: 0.5rem; padding: 1rem; }
  .cal-day { border: 1px solid #333; border-radius: 6px; overflow: hidden; }
  .cal-day-header { display: flex; align-items: baseline; gap: 0.5rem; padding: 0.4rem 0.75rem; background: #1e1e1e; border-bottom: 1px solid #333; }
  .cal-day-header.cal-today { background: #1a2a1a; border-bottom-color: #4a8; }
  .cal-weekday { font-weight: 600; font-size: 0.85rem; color: #aaa; text-transform: uppercase; letter-spacing: 0.05em; }
  .cal-today .cal-weekday { color: #4a8; }
  .cal-date { font-size: 0.85rem; color: #666; }
  .cal-today .cal-date { color: #4a8; }
  .cal-events { list-style: none; padding: 0.25rem 0; }
  .cal-empty { padding: 0.25rem 0.75rem; color: #444; font-style: italic; font-size: 0.8rem; }
  .cal-event { display: flex; gap: 0.5rem; padding: 0.2rem 0.75rem; }
  .cal-event:hover { background: #1e1e1e; }
  .cal-event-time { color: #888; min-width: 4.5rem; font-size: 0.8rem; padding-top: 0.05rem; }
  .cal-event-summary { color: #ddd; }
  "
}

// JAVASCRIPT ------------------------------------------------------------------

fn serve_runtime() -> Response(ResponseData) {
  let assert Ok(lustre_priv) = application.priv_directory("lustre")
  let file_path = lustre_priv <> "/static/lustre-server-component.mjs"

  case mist.send_file(file_path, offset: 0, limit: None) {
    Ok(file) ->
      response.new(200)
      |> response.prepend_header("content-type", "application/javascript")
      |> response.set_body(file)

    Error(_) ->
      response.new(404)
      |> response.set_body(mist.Bytes(bytes_tree.new()))
  }
}

// WEBSOCKET -------------------------------------------------------------------

fn serve_tabs(
  request: Request(Connection),
  cal_server: cal_server.Server,
) -> Response(ResponseData) {
  mist.websocket(
    request:,
    on_init: fn(conn) { init_tabs_socket(conn, cal_server) },
    handler: loop_tabs_socket,
    on_close: close_tabs_socket,
  )
}

type TabsSocket {
  TabsSocket(
    component: lustre.Runtime(tabs.Msg),
    self: Subject(server_component.ClientMessage(tabs.Msg)),
  )
}

type TabsSocketMessage =
  server_component.ClientMessage(tabs.Msg)

type TabsSocketInit =
  #(TabsSocket, Option(Selector(TabsSocketMessage)))

fn init_tabs_socket(
  _conn: mist.WebsocketConnection,
  cal_server: cal_server.Server,
) -> TabsSocketInit {
  let assert Ok(component) =
    tabs.component()
    |> lustre.start_server_component(cal_server)

  let self = process.new_subject()
  let selector =
    process.new_selector()
    |> process.select(self)

  server_component.register_subject(self)
  |> lustre.send(to: component)

  #(TabsSocket(component:, self:), Some(selector))
}

fn loop_tabs_socket(
  state: TabsSocket,
  message: mist.WebsocketMessage(TabsSocketMessage),
  connection: mist.WebsocketConnection,
) -> mist.Next(TabsSocket, TabsSocketMessage) {
  case message {
    mist.Text(json) -> {
      case json.parse(json, server_component.runtime_message_decoder()) {
        Ok(runtime_message) -> lustre.send(state.component, runtime_message)
        Error(_) -> Nil
      }
      mist.continue(state)
    }

    mist.Binary(_) -> mist.continue(state)

    mist.Custom(client_message) -> {
      let json = server_component.client_message_to_json(client_message)
      let assert Ok(_) = mist.send_text_frame(connection, json.to_string(json))
      mist.continue(state)
    }

    mist.Closed | mist.Shutdown -> mist.stop()
  }
}

fn close_tabs_socket(state: TabsSocket) -> Nil {
  lustre.shutdown()
  |> lustre.send(to: state.component)
}
