// IMPORTS ---------------------------------------------------------------------

import cal_dav
import cal_server
import gleam/bytes_tree
import gleam/erlang/application
import gleam/erlang/process.{type Selector, type Subject}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/io
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import lustre
import lustre/attribute
import lustre/element
import lustre/element/html.{html}
import lustre/server_component
import mist.{type Connection, type ResponseData}
import state
import tabs

// CONSTANTS -------------------------------------------------------------------

const port = 46_548

/// How many times to retry binding before giving up.
const bind_max_attempts = 10

/// Milliseconds to wait between bind retries (doubles each attempt, capped).
const bind_retry_delay_ms = 500

// MAIN ------------------------------------------------------------------------

pub fn main() {
  // Load CalDAV credentials and start the shared calendar server.
  // Crash hard on misconfiguration rather than silently serving stale data.
  let assert Ok(config) = cal_dav.config_from_env()
  let data_dir = state.data_dir()
  let assert Ok(cal_server) = cal_server.start(config, data_dir)

  let handler = fn(request: Request(Connection)) -> Response(ResponseData) {
    case request.path_segments(request) {
      [] -> serve_html()
      ["lustre", "runtime.mjs"] -> serve_runtime()
      ["ws"] -> serve_tabs(request, cal_server)
      _ -> response.set_body(response.new(404), mist.Bytes(bytes_tree.new()))
    }
  }

  let assert Ok(_) =
    start_with_retry(handler, bind_max_attempts, bind_retry_delay_ms)

  process.sleep_forever()
}

/// Try to start the mist server, retrying on EADDRINUSE up to `attempts` times.
/// Delay between retries starts at `delay_ms` and doubles each attempt.
fn start_with_retry(
  handler: fn(Request(Connection)) -> Response(ResponseData),
  attempts: Int,
  delay_ms: Int,
) {
  let result =
    mist.new(handler)
    |> mist.bind("0.0.0.0")
    |> mist.port(port)
    |> mist.start

  case result {
    Ok(_) -> result
    Error(actor.InitFailed(msg)) if attempts > 1 -> {
      io.println(
        "[app] port "
        <> int.to_string(port)
        <> " in use ("
        <> msg
        <> "), retrying in "
        <> int.to_string(delay_ms)
        <> "ms ("
        <> int.to_string(attempts - 1)
        <> " attempts left)…",
      )
      process.sleep(delay_ms)
      let next_delay = int.min(delay_ms * 2, 5000)
      start_with_retry(handler, attempts - 1, next_delay)
    }
    Error(_) -> result
  }
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
        html.script([], "window.tailwind = { config: { darkMode: 'class' } }"),
        html.script([attribute.src("https://cdn.tailwindcss.com")], ""),
        html.script(
          [attribute.type_("module"), attribute.src("/lustre/runtime.mjs")],
          "",
        ),
      ]),
      html.body(
        [attribute.class("dark bg-gray-950 text-gray-100 min-h-screen")],
        [
          server_component.element([server_component.route("/ws")], []),
        ],
      ),
    ])
    |> element.to_document_string_tree
    |> bytes_tree.from_string_tree

  response.new(200)
  |> response.set_body(mist.Bytes(html))
  |> response.set_header("content-type", "text/html")
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
