// IMPORTS ---------------------------------------------------------------------

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
  // TODO: start calendar_server supervised singleton here before accepting
  // connections, and pass its Subject into the WebSocket handler.

  let assert Ok(_) =
    fn(request: Request(Connection)) -> Response(ResponseData) {
      case request.path_segments(request) {
        [] -> serve_html()
        ["lustre", "runtime.mjs"] -> serve_runtime()
        ["ws"] -> serve_tabs(request)
        _ -> response.set_body(response.new(404), mist.Bytes(bytes_tree.new()))
      }
    }
    |> mist.new
    |> mist.bind("localhost")
    |> mist.port(46548)
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
        html.script(
          [attribute.type_("module"), attribute.src("/lustre/runtime.mjs")],
          "",
        ),
      ]),
      html.body(
        [attribute.styles([#("max-width", "32rem"), #("margin", "3rem auto")])],
        [server_component.element([server_component.route("/ws")], [])],
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

fn serve_tabs(request: Request(Connection)) -> Response(ResponseData) {
  mist.websocket(
    request:,
    on_init: init_tabs_socket,
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

fn init_tabs_socket(_) -> TabsSocketInit {
  let assert Ok(component) =
    tabs.component()
    |> lustre.start_server_component(Nil)

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
