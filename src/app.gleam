// IMPORTS ---------------------------------------------------------------------

import cal_dav
import cal_server
import envoy
import gleam/bytes_tree
import gleam/erlang/application
import gleam/erlang/process.{type Selector, type Subject}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import ha_client
import log
import lustre
import lustre/attribute
import lustre/element
import lustre/element/html.{html}
import lustre/server_component
import mist.{type Connection, type ResponseData}
import state
import tabs

// CONSTANTS -------------------------------------------------------------------

const default_port = 46_548

fn get_port() -> Int {
  envoy.get("PORT")
  |> result.try(int.parse)
  |> result.unwrap(default_port)
}

// MAIN ------------------------------------------------------------------------

/// Register an OS-level SIGTERM handler that calls init:stop(), giving the
/// BEAM VM time to shut down supervisors (and release the TCP port) before
/// the process exits. Without this, watchexec kills gleam-run-dev but
/// beam.smp keeps holding the port, causing EADDRINUSE on the next start.
@external(erlang, "signal_handler_ffi", "trap_sigterm")
fn trap_sigterm() -> Nil

/// Wraps mist.start with process trap_exit so supervisor EXIT signals
/// are caught as Error results rather than crashing the process.
@external(erlang, "signal_handler_ffi", "try_start")
fn try_start(
  start_fun: fn() -> Result(a, actor.StartError),
) -> Result(a, actor.StartError)

pub fn main() {
  trap_sigterm()

  // Set up file logging before anything else.
  let log_path = log.default_path()
  log.set_path(log_path)
  log.println("[app] starting")
  log.println("[app] log:        " <> log_path)
  log.println("[app] config_dir: " <> state.config_dir())
  log.println("[app] cache_dir:  " <> state.cache_dir())
  log.println("[app] state_dir:  " <> state.state_dir())

  // Load CalDAV credentials and start the shared calendar server.
  // Crash hard on misconfiguration rather than silently serving stale data.
  let assert Ok(config) = cal_dav.config_from_env()
  let assert Ok(cal_server) =
    cal_server.start(config, state.config_dir(), state.cache_dir())

  // Optionally start Home Assistant MQTT integration.
  let ha = case ha_client.config_from_env() {
    Ok(ha_config) -> {
      log.println("[app] HA integration enabled, connecting to MQTT...")
      case ha_client.start(ha_config) {
        Ok(client) -> {
          log.println("[app] HA client started successfully")
          Some(client)
        }
        Error(err) -> {
          log.println(
            "[app] HA client failed to start: " <> string.inspect(err),
          )
          None
        }
      }
    }
    Error(reason) -> {
      log.println("[app] HA integration disabled: " <> reason)
      None
    }
  }

  let handler = fn(request: Request(Connection)) -> Response(ResponseData) {
    case request.path_segments(request) {
      [] -> serve_html()
      ["app.css"] -> serve_static_file("priv/static/app.css", "text/css")
      ["lustre", "runtime.mjs"] -> serve_runtime()
      ["ws"] -> serve_tabs(request, cal_server, ha)
      _ -> response.set_body(response.new(404), mist.Bytes(bytes_tree.new()))
    }
  }

  let port = get_port()
  let assert Ok(_) = start_with_retry(handler, port, 20, 250)
  process.sleep_forever()
}

/// Retry binding the port up to `attempts` times with exponential backoff.
/// Needed because the previous BEAM's socket lingers briefly after SIGTERM
/// even after the process exits — init:stop() is async.
fn start_with_retry(
  handler: fn(Request(Connection)) -> Response(ResponseData),
  port: Int,
  attempts: Int,
  delay_ms: Int,
) -> Result(_, actor.StartError) {
  let result =
    try_start(fn() {
      mist.new(handler)
      |> mist.bind("0.0.0.0")
      |> mist.port(port)
      |> mist.start
    })
  case result {
    Ok(_) -> result
    Error(err) if attempts > 1 -> {
      log.println(
        "[app] port "
        <> int.to_string(port)
        <> " busy ("
        <> string.inspect(err)
        <> "), retrying in "
        <> int.to_string(delay_ms)
        <> "ms…",
      )
      process.sleep(delay_ms)
      start_with_retry(handler, port, attempts - 1, int.min(delay_ms * 2, 5000))
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
        html.link([
          attribute.rel("stylesheet"),
          attribute.href("/app.css"),
        ]),
        html.script(
          [],
          "(function(){
  var _WS = window.WebSocket;
  var startedAt = Date.now();
  var connected = false;
  window.WebSocket = function(url, proto) {
    var ws = proto ? new _WS(url, proto) : new _WS(url);
    var urlStr = (url && url.toString) ? url.toString() : String(url);
    if (urlStr.includes('/ws')) {
      ws.addEventListener('open', function() {
        if (connected && (Date.now() - startedAt) > 3000) {
          window.location.reload();
        }
        connected = true;
        document.body.removeAttribute('data-disconnected');
      });
      ws.addEventListener('close', function() {
        if (connected) {
          document.body.setAttribute('data-disconnected', '');
        }
      });
    }
    return ws;
  };
  window.WebSocket.prototype = _WS.prototype;
  window.WebSocket.CONNECTING = _WS.CONNECTING;
  window.WebSocket.OPEN       = _WS.OPEN;
  window.WebSocket.CLOSING    = _WS.CLOSING;
  window.WebSocket.CLOSED     = _WS.CLOSED;
})();",
        ),
        html.script(
          [attribute.type_("module"), attribute.src("/lustre/runtime.mjs")],
          "",
        ),
      ]),
      html.body([attribute.class("bg-bg text-text min-h-screen")], [
        server_component.element([server_component.route("/ws")], []),
        html.div(
          [
            attribute.id("disconnected-badge"),
            attribute.class(
              "fixed bottom-2 right-2 px-2 py-0.5 rounded text-xs font-medium select-none pointer-events-none",
            ),
            attribute.style("background-color", "oklch(0.4 0.05 0 / 70%)"),
            attribute.style("color", "oklch(0.75 0.05 0)"),
            attribute.style("display", "none"),
          ],
          [html.text("disconnected")],
        ),
        html.style(
          [],
          "body[data-disconnected] #disconnected-badge { display: block !important; }",
        ),
      ]),
    ])
    |> element.to_document_string_tree
    |> bytes_tree.from_string_tree

  response.new(200)
  |> response.set_body(mist.Bytes(html))
  |> response.set_header("content-type", "text/html")
}

// STATIC FILES ----------------------------------------------------------------

fn serve_static_file(
  path: String,
  content_type: String,
) -> Response(ResponseData) {
  case mist.send_file(path, offset: 0, limit: None) {
    Ok(file) ->
      response.new(200)
      |> response.prepend_header("content-type", content_type)
      |> response.set_body(file)
    Error(_) ->
      response.new(404)
      |> response.set_body(mist.Bytes(bytes_tree.new()))
  }
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
  ha: Option(ha_client.HaClient),
) -> Response(ResponseData) {
  mist.websocket(
    request:,
    on_init: fn(conn) { init_tabs_socket(conn, cal_server, ha) },
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
  ha: Option(ha_client.HaClient),
) -> TabsSocketInit {
  let assert Ok(component) =
    tabs.component()
    |> lustre.start_server_component(tabs.Flags(cal_server:, ha:))

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
