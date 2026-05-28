// ha_client.gleam — Home Assistant integration via MQTT discovery.
//
// Connects to an MQTT broker, registers a HA device with two switch entities
// (display_power and dark_mode), and listens for commands from HA automations.
//
// Env vars:
//   MQTT_HOST, MQTT_PORT (default 1883), MQTT_USERNAME, MQTT_PASSWORD
//   HA_DEVICE_PREFIX (default: system hostname with hyphens replaced by underscores)
//   DISPLAY_OUTPUT, DISPLAY_CONTROL_SCHEME — both must be set for display control
//     Supported schemes:
//       "swaymsg" — preferred for sway compositor; uses sway IPC to set
//                   output power.  Works even when the output is powered off
//                   (wlopm cannot turn an output back on once it disappears
//                   from the compositor's output list).
//       "wlopm"   — uses zwlr_output_power_manager_v1 (DPMS).  Broken for
//                   power-on: output disappears when powered off so wlopm
//                   cannot find it to re-enable it.  Kept for reference.
//       "wlr-randr" — legacy; cage fights back.  Do not use.

import envoy
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import log
import shellout
import state
import spoke/mqtt
import spoke/mqtt_actor
import spoke/tcp

// PUBLIC TYPES ----------------------------------------------------------------

/// State pushed to registered UI clients.
pub type HaState {
  HaState(display_power: Bool, dark_mode: Bool)
}

/// Configuration parsed from env vars.
pub type Config {
  Config(
    mqtt_host: String,
    mqtt_port: Int,
    mqtt_username: String,
    mqtt_password: String,
    device_prefix: String,
    display_output: Option(String),
    display_control_scheme: Option(String),
  )
}

/// Opaque handle for communicating with the HA client actor.
pub opaque type HaClient {
  HaClient(subject: Subject(Msg))
}

pub type ClientCallback =
  fn(HaState) -> Nil

// PUBLIC API ------------------------------------------------------------------

/// Try to load MQTT configuration from env vars.
/// Returns Error if MQTT_HOST is not set (integration disabled).
pub fn config_from_env() -> Result(Config, String) {
  use mqtt_host <- result.try(
    envoy.get("MQTT_HOST")
    |> result.replace_error("MQTT_HOST not set"),
  )
  use mqtt_username <- result.try(
    envoy.get("MQTT_USERNAME")
    |> result.replace_error("MQTT_USERNAME not set"),
  )
  use mqtt_password <- result.try(
    state.get_secret("mqtt_password", "MQTT_PASSWORD"),
  )
  let mqtt_port =
    envoy.get("MQTT_PORT")
    |> result.try(int.parse)
    |> result.unwrap(1883)
  let device_prefix =
    envoy.get("HA_DEVICE_PREFIX")
    |> result.unwrap(default_device_prefix())
  let display_output =
    envoy.get("DISPLAY_OUTPUT")
    |> option.from_result
  let display_control_scheme =
    envoy.get("DISPLAY_CONTROL_SCHEME")
    |> option.from_result

  Ok(Config(
    mqtt_host:,
    mqtt_port:,
    mqtt_username:,
    mqtt_password:,
    device_prefix:,
    display_output:,
    display_control_scheme:,
  ))
}

/// Start the HA client actor. Returns an HaClient handle.
pub fn start(config: Config) -> Result(HaClient, actor.StartError) {
  let result =
    actor.new_with_initialiser(15_000, fn(self) {
      case init_mqtt(self, config) {
        Ok(#(state, updates_subject)) -> {
          // Build a selector that includes BOTH:
          // 1. The actor's own subject (for RegisterClient, Reconnect, etc.)
          // 2. The MQTT updates subject (mapped into Msg)
          // actor.selecting REPLACES the default selector, so we must
          // include the actor's subject explicitly.
          let selector =
            process.new_selector()
            |> process.select(self)
            |> process.select_map(updates_subject, fn(update) {
              case update {
                mqtt.ReceivedMessage(topic:, payload:, ..) ->
                  MqttMessage(topic:, payload:)
                mqtt.ConnectionStateChanged(conn_state) ->
                  MqttConnectionChanged(conn_state)
              }
            })
          actor.initialised(state)
          |> actor.selecting(selector)
          |> actor.returning(self)
          |> Ok
        }
        Error(reason) -> Error(reason)
      }
    })
    |> actor.on_message(handle_message)
    |> actor.start

  case result {
    Ok(started) -> Ok(HaClient(subject: started.data))
    Error(err) -> Error(err)
  }
}

/// Register a callback to receive HaState updates.
/// The callback is invoked immediately with the current state.
pub fn register(client: HaClient, callback: ClientCallback) -> Nil {
  process.send(client.subject, RegisterClient(callback))
}

// INTERNAL TYPES --------------------------------------------------------------

type Msg {
  RegisterClient(ClientCallback)
  MqttMessage(topic: String, payload: BitArray)
  MqttConnectionChanged(mqtt.ConnectionState)
  Reconnect
  /// Periodic watchdog tick. Independent of the disconnect → reconnect path,
  /// this guards against silent-stuck states by forcing a reconnect whenever
  /// we believe we are not connected and no retry is already in flight.
  HealthCheck
}

type State {
  State(
    config: Config,
    mqtt_client: mqtt_actor.Client,
    display_power: Bool,
    dark_mode: Bool,
    clients: List(ClientCallback),
    self: Subject(Msg),
    /// True while we believe an MQTT session is established (between
    /// ConnectAccepted and any subsequent disconnect).
    connected: Bool,
    /// Number of consecutive failed reconnect attempts since the last
    /// successful ConnectAccepted. Used to compute exponential backoff.
    /// Reset to 0 on each successful ConnectAccepted.
    reconnect_attempt: Int,
    /// True when a reconnect task has been scheduled but not yet fired,
    /// preventing multiple overlapping reconnect spawns when several
    /// connection events arrive in quick succession.
    reconnect_pending: Bool,
  )
}

// Backoff schedule constants (milliseconds).
const initial_backoff_ms = 5000

const max_backoff_ms = 60_000

// Watchdog tick interval. Long enough not to spam logs, short enough to
// recover from silent-stuck states within ~1 minute.
const watchdog_interval_ms = 60_000

// ACTOR INIT ------------------------------------------------------------------

fn init_mqtt(
  self: Subject(Msg),
  config: Config,
) -> Result(#(State, Subject(mqtt.Update)), String) {
  let prefix = config.device_prefix

  // Build the MQTT transport connector
  let connector = case config.mqtt_port {
    1883 -> tcp.connector_with_defaults(host: config.mqtt_host)
    port -> tcp.connector(host: config.mqtt_host, port:, connect_timeout: 5000)
  }

  let connect_options =
    mqtt.connect_with_id(connector, prefix <> "_home_terminal")
    |> mqtt.using_auth(
      config.mqtt_username,
      Some(bit_array.from_string(config.mqtt_password)),
    )
    |> mqtt.keep_alive_seconds(30)

  // Start the spoke MQTT actor
  let started = case mqtt_actor.build(connect_options) |> mqtt_actor.start(5000) {
    Ok(s) -> s
    Error(_) -> {
      log.println("[ha_client] failed to start MQTT actor")
      panic as "ha_client: failed to start MQTT actor"
    }
  }
  let client = started.data

  // Subscribe to MQTT updates, routing them into our actor's message types
  let updates_subject = process.new_subject()
  mqtt_actor.subscribe_to_updates(client, updates_subject)

  // LWT (Last Will and Testament) — published by broker if we disconnect
  let will =
    mqtt.PublishData(
      topic: prefix <> "/availability",
      payload: bit_array.from_string("offline"),
      qos: mqtt.AtLeastOnce,
      retain: True,
    )

  // Connect with clean session and LWT
  mqtt_actor.connect(client, True, Some(will))

  // Wait for connection to be accepted
  let connect_result =
    process.new_selector()
    |> process.select(updates_subject)
    |> process.selector_receive(from: _, within: 10_000)

  use <- require_connected(connect_result, config)

  // Recover previous state from retained MQTT messages before publishing our own
  let #(display_power, dark_mode) =
    recover_retained_state(client, updates_subject, prefix)

  log.println(
    "[ha_client] recovered state: display_power="
    <> bool_to_on_off(display_power)
    <> " dark_mode="
    <> bool_to_on_off(dark_mode),
  )

  // Apply display power side-effect to ensure hardware matches restored state
  set_display_power(config, display_power)

  let initial_state =
    State(
      config:,
      mqtt_client: client,
      display_power:,
      dark_mode:,
      clients: [],
      self:,
      connected: True,
      reconnect_attempt: 0,
      reconnect_pending: False,
    )
  setup_session(client, prefix, initial_state)

  // Start the watchdog loop. It runs independently of the actor's mailbox
  // and just pings us every watchdog_interval_ms.
  start_watchdog(self)

  Ok(#(initial_state, updates_subject))
}

/// Check the MQTT connect result and either continue or return an error.
/// Used with `use <- require_connected(result, config)` pattern.
fn require_connected(
  connect_result: Result(mqtt.Update, Nil),
  config: Config,
  continue: fn() -> Result(#(State, Subject(mqtt.Update)), String),
) -> Result(#(State, Subject(mqtt.Update)), String) {
  case connect_result {
    Ok(mqtt.ConnectionStateChanged(mqtt.ConnectAccepted(_))) -> {
      log.println(
        "[ha_client] connected to MQTT broker at " <> config.mqtt_host,
      )
      continue()
    }
    Ok(mqtt.ConnectionStateChanged(mqtt.ConnectRejected(reason))) -> {
      log.println(
        "[ha_client] connection rejected: " <> string.inspect(reason),
      )
      Error("MQTT connection rejected: " <> string.inspect(reason))
    }
    Ok(_) -> {
      log.println("[ha_client] unexpected MQTT response during connect")
      Error("Unexpected MQTT response during connect")
    }
    Error(Nil) -> {
      log.println("[ha_client] MQTT connection timed out")
      Error("MQTT connection timed out")
    }
  }
}

/// Subscribe to our own state topics, read any retained messages from the
/// broker, and unsubscribe. Returns the recovered (display_power, dark_mode)
/// values, defaulting to True if no retained message exists (first boot).
fn recover_retained_state(
  client: mqtt_actor.Client,
  updates_subject: Subject(mqtt.Update),
  prefix: String,
) -> #(Bool, Bool) {
  let display_power_topic = prefix <> "/display_power/state"
  let dark_mode_topic = prefix <> "/dark_mode/state"

  // Subscribe to our own state topics to receive retained messages
  let sub_result =
    mqtt_actor.subscribe(client, [
      mqtt.SubscribeRequest(display_power_topic, mqtt.AtLeastOnce),
      mqtt.SubscribeRequest(dark_mode_topic, mqtt.AtLeastOnce),
    ])

  case sub_result {
    Error(err) -> {
      log.println(
        "[ha_client] failed to subscribe to state topics for recovery: "
        <> string.inspect(err),
      )
      #(True, True)
    }
    Ok(_subscriptions) -> {
      // After SUBACK, the broker sends retained messages as PUBLISH packets.
      // Wait up to 2 seconds to collect them (we expect 0-2 messages).
      let selector =
        process.new_selector()
        |> process.select(updates_subject)

      let state = collect_retained_messages(selector, #(None, None), prefix, 2)

      // Unsubscribe from state topics — they're our output, not input
      let _ =
        mqtt_actor.unsubscribe(client, [display_power_topic, dark_mode_topic])

      let display_power = option.unwrap(state.0, True)
      let dark_mode = option.unwrap(state.1, True)
      #(display_power, dark_mode)
    }
  }
}

/// Collect up to `remaining` retained messages from the selector, with a
/// 2-second timeout per message. Returns (display_power, dark_mode) as Options.
fn collect_retained_messages(
  selector: process.Selector(mqtt.Update),
  acc: #(Option(Bool), Option(Bool)),
  prefix: String,
  remaining: Int,
) -> #(Option(Bool), Option(Bool)) {
  case remaining {
    0 -> acc
    _ -> {
      case process.selector_receive(from: selector, within: 2000) {
        Error(Nil) -> {
          // Timeout — no more retained messages
          acc
        }
        Ok(mqtt.ReceivedMessage(topic:, payload:, retained: True)) -> {
          let value =
            bit_array.to_string(payload)
            |> result.unwrap("")
            |> string.uppercase
          let on = value == "ON"

          let new_acc = case
            topic == prefix <> "/display_power/state",
            topic == prefix <> "/dark_mode/state"
          {
            True, _ -> #(Some(on), acc.1)
            _, True -> #(acc.0, Some(on))
            _, _ -> acc
          }
          collect_retained_messages(selector, new_acc, prefix, remaining - 1)
        }
        Ok(mqtt.ReceivedMessage(retained: False, ..)) -> {
          // Non-retained message; skip but keep waiting
          collect_retained_messages(selector, acc, prefix, remaining)
        }
        Ok(mqtt.ConnectionStateChanged(_)) -> {
          // Ignore connection state changes during recovery
          collect_retained_messages(selector, acc, prefix, remaining)
        }
      }
    }
  }
}

fn bool_to_on_off(value: Bool) -> String {
  case value {
    True -> "ON"
    False -> "OFF"
  }
}

/// Re-publish discovery, availability, current state, and re-subscribe to
/// command topics. Called both on initial connect and after reconnect.
fn setup_session(
  client: mqtt_actor.Client,
  prefix: String,
  state: State,
) -> Nil {
  publish_discovery(client, prefix)

  // Publish current state (not hardcoded True — preserve state across reconnect)
  publish_state(client, prefix <> "/display_power/state", state.display_power)
  publish_state(client, prefix <> "/dark_mode/state", state.dark_mode)

  // Publish availability
  mqtt_actor.publish(
    client,
    mqtt.PublishData(
      topic: prefix <> "/availability",
      payload: bit_array.from_string("online"),
      qos: mqtt.AtLeastOnce,
      retain: True,
    ),
  )

  // Subscribe to command topics
  let _sub_result =
    mqtt_actor.subscribe(client, [
      mqtt.SubscribeRequest(prefix <> "/display_power/set", mqtt.AtLeastOnce),
      mqtt.SubscribeRequest(prefix <> "/dark_mode/set", mqtt.AtLeastOnce),
    ])

  log.println("[ha_client] session established: discovery, state, subscriptions")
}

// MESSAGE HANDLER -------------------------------------------------------------

fn handle_message(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    RegisterClient(callback) -> {
      // Immediately push current state
      callback(HaState(
        display_power: state.display_power,
        dark_mode: state.dark_mode,
      ))
      actor.continue(State(..state, clients: [callback, ..state.clients]))
    }

    MqttMessage(topic:, payload:) -> {
      let prefix = state.config.device_prefix
      let payload_str =
        bit_array.to_string(payload)
        |> result.unwrap("")
        |> string.uppercase
      let on = payload_str == "ON"

      let new_state = case string.ends_with(topic, "/display_power/set") {
        True -> {
          log.println("[ha_client] display_power command: " <> payload_str)
          set_display_power(state.config, on)
          publish_state(
            state.mqtt_client,
            prefix <> "/display_power/state",
            on,
          )
          State(..state, display_power: on)
        }
        False ->
          case string.ends_with(topic, "/dark_mode/set") {
            True -> {
              log.println("[ha_client] dark_mode command: " <> payload_str)
              publish_state(
                state.mqtt_client,
                prefix <> "/dark_mode/state",
                on,
              )
              State(..state, dark_mode: on)
            }
            False -> {
              log.println("[ha_client] unknown topic: " <> topic)
              state
            }
          }
      }
      broadcast(new_state)
      actor.continue(new_state)
    }

    MqttConnectionChanged(mqtt.DisconnectedUnexpectedly(reason:)) -> {
      log.println("[ha_client] disconnected unexpectedly: " <> reason)
      // Mark disconnected and (re)schedule a reconnect using the current
      // backoff. We deliberately do NOT reset reconnect_attempt here — if we
      // were already in a reconnect loop and the broker briefly accepted us
      // before failing again, we should keep backing off rather than reset.
      // (reconnect_attempt is reset only on a fully successful ConnectAccepted.)
      let state = State(..state, connected: False)
      let state = maybe_schedule_reconnect(state, "disconnect")
      actor.continue(state)
    }

    MqttConnectionChanged(mqtt.Disconnected) -> {
      // Clean disconnect — usually a deliberate shutdown. Still treat as a
      // condition to recover from in case it was unexpected from our POV.
      log.println("[ha_client] disconnected (clean)")
      let state = State(..state, connected: False)
      let state = maybe_schedule_reconnect(state, "clean disconnect")
      actor.continue(state)
    }

    MqttConnectionChanged(mqtt.ConnectAccepted(_)) -> {
      log.println(
        "[ha_client] connected, re-establishing session"
        <> case state.reconnect_attempt {
          0 -> ""
          n -> " (after " <> int.to_string(n) <> " failed attempt(s))"
        },
      )
      let prefix = state.config.device_prefix
      // Re-publish discovery, availability, current state, and re-subscribe
      setup_session(state.mqtt_client, prefix, state)
      // Reset backoff state — we're healthy again.
      let state =
        State(
          ..state,
          connected: True,
          reconnect_attempt: 0,
          reconnect_pending: False,
        )
      actor.continue(state)
    }

    MqttConnectionChanged(mqtt.ConnectFailed(reason)) -> {
      log.println("[ha_client] connect failed: " <> reason)
      let state = State(..state, connected: False, reconnect_pending: False)
      let state = maybe_schedule_reconnect(state, "connect failed")
      actor.continue(state)
    }

    MqttConnectionChanged(mqtt.ConnectRejected(reason)) -> {
      // Broker actively rejected (auth failure, bad client id, etc.).
      // Retrying immediately is unlikely to help — the spoke library reports
      // these as terminal protocol errors. We still retry on the same backoff
      // ladder so that a transient broker config issue can recover, but the
      // logs make it clear what happened.
      log.println(
        "[ha_client] connect rejected: " <> string.inspect(reason),
      )
      let state = State(..state, connected: False, reconnect_pending: False)
      let state = maybe_schedule_reconnect(state, "connect rejected")
      actor.continue(state)
    }

    Reconnect -> {
      // Mark the pending flag false now that the scheduled task has fired
      // and we're about to act on it.
      let attempt = state.reconnect_attempt + 1
      log.println(
        "[ha_client] attempting reconnect (attempt "
        <> int.to_string(attempt)
        <> ")...",
      )
      let will =
        mqtt.PublishData(
          topic: state.config.device_prefix <> "/availability",
          payload: bit_array.from_string("offline"),
          qos: mqtt.AtLeastOnce,
          retain: True,
        )
      mqtt_actor.connect(state.mqtt_client, True, Some(will))
      // The outcome will arrive as a ConnectionStateChanged update which we
      // translate into MqttConnectionChanged. We bump reconnect_attempt now
      // so the count is correct regardless of which branch handles the
      // outcome.
      actor.continue(
        State(
          ..state,
          reconnect_attempt: attempt,
          reconnect_pending: False,
        ),
      )
    }

    HealthCheck -> {
      // Watchdog: if we believe we are not connected and no reconnect is
      // already in flight, kick one off immediately. This is the
      // belt-and-suspenders safety net against any unforeseen state machine
      // bug that might lead to a silent-stuck actor.
      case state.connected, state.reconnect_pending {
        True, _ -> actor.continue(state)
        False, True -> actor.continue(state)
        False, False -> {
          log.println(
            "[ha_client] watchdog: not connected and no reconnect pending; forcing one",
          )
          let state = maybe_schedule_reconnect(state, "watchdog")
          actor.continue(state)
        }
      }
    }
  }
}

fn broadcast(state: State) -> Nil {
  let ha_state =
    HaState(display_power: state.display_power, dark_mode: state.dark_mode)
  list.each(state.clients, fn(callback) { callback(ha_state) })
}

// RECONNECT / WATCHDOG --------------------------------------------------------

/// Compute the next reconnect delay using a capped exponential backoff:
///
///   attempt 0 (first failure)  → 5s   (initial_backoff_ms)
///   attempt 1                  → 10s
///   attempt 2                  → 20s
///   attempt 3                  → 40s
///   attempt 4+                 → 60s  (max_backoff_ms)
///
/// `attempt` is the number of consecutive failed attempts SO FAR (so the
/// caller passes state.reconnect_attempt before incrementing).
fn backoff_delay_ms(attempt: Int) -> Int {
  let shift = case attempt < 0 {
    True -> 0
    False -> attempt
  }
  // 5000 * 2^shift, capped at max_backoff_ms.
  let raw = initial_backoff_ms * pow2(shift)
  case raw > max_backoff_ms || raw < 0 {
    True -> max_backoff_ms
    False -> raw
  }
}

/// Simple integer 2^n with a small cap to avoid overflow. The cap is well
/// above what the backoff schedule will ever pass in.
fn pow2(n: Int) -> Int {
  case n <= 0 {
    True -> 1
    False ->
      case n > 30 {
        True -> 1_073_741_824
        // 2^30
        False -> 2 * pow2(n - 1)
      }
  }
}

/// Spawn a one-shot unlinked task that sleeps `delay_ms` then sends Reconnect
/// to the actor.
fn schedule_reconnect(self: Subject(Msg), delay_ms: Int) -> Nil {
  let _ = process.spawn_unlinked(fn() {
    process.sleep(delay_ms)
    process.send(self, Reconnect)
  })
  Nil
}

/// Idempotent scheduler: only schedule a reconnect if one isn't already
/// pending. Returns the updated state with reconnect_pending set.
fn maybe_schedule_reconnect(state: State, source: String) -> State {
  case state.reconnect_pending {
    True -> {
      log.println(
        "[ha_client] reconnect already pending; skipping " <> source <> " trigger",
      )
      state
    }
    False -> {
      let delay = backoff_delay_ms(state.reconnect_attempt)
      log.println(
        "[ha_client] scheduling reconnect in "
        <> int.to_string(delay)
        <> "ms (trigger="
        <> source
        <> ", attempt="
        <> int.to_string(state.reconnect_attempt + 1)
        <> ")",
      )
      schedule_reconnect(state.self, delay)
      State(..state, reconnect_pending: True)
    }
  }
}

/// Periodic watchdog. Sends HealthCheck to the actor every
/// watchdog_interval_ms forever. The actor decides what to do with it.
fn start_watchdog(self: Subject(Msg)) -> Nil {
  let _ = process.spawn_unlinked(fn() { watchdog_loop(self) })
  Nil
}

fn watchdog_loop(self: Subject(Msg)) -> Nil {
  process.sleep(watchdog_interval_ms)
  process.send(self, HealthCheck)
  watchdog_loop(self)
}

// MQTT PUBLISHING -------------------------------------------------------------

fn publish_discovery(client: mqtt_actor.Client, prefix: String) -> Nil {
  let discovery_topic = "homeassistant/device/" <> prefix <> "/config"

  let payload =
    json.object([
      #(
        "dev",
        json.object([
          #("ids", json.array([prefix], json.string)),
          #("name", json.string(humanize_prefix(prefix))),
          #("mf", json.string("home-terminal")),
          #("mdl", json.string("Raspberry Pi")),
          #("sw", json.string("1.0.0")),
        ]),
      ),
      #(
        "o",
        json.object([
          #("name", json.string("home-terminal")),
          #("sw", json.string("1.0.0")),
        ]),
      ),
      #(
        "avty",
        json.array(
          [
            json.object([
              #("t", json.string(prefix <> "/availability")),
            ]),
          ],
          fn(x) { x },
        ),
      ),
      #(
        "cmps",
        json.object([
          #(
            "display_power",
            json.object([
              #("p", json.string("switch")),
              #("name", json.string("Display Power")),
              #("unique_id", json.string(prefix <> "_display_power")),
              #("cmd_t", json.string(prefix <> "/display_power/set")),
              #("stat_t", json.string(prefix <> "/display_power/state")),
              #("ic", json.string("mdi:monitor")),
            ]),
          ),
          #(
            "dark_mode",
            json.object([
              #("p", json.string("switch")),
              #("name", json.string("Dark Mode")),
              #("unique_id", json.string(prefix <> "_dark_mode")),
              #("cmd_t", json.string(prefix <> "/dark_mode/set")),
              #("stat_t", json.string(prefix <> "/dark_mode/state")),
              #("ic", json.string("mdi:theme-light-dark")),
            ]),
          ),
        ]),
      ),
    ])
    |> json.to_string
    |> bit_array.from_string

  mqtt_actor.publish(
    client,
    mqtt.PublishData(
      topic: discovery_topic,
      payload:,
      qos: mqtt.AtLeastOnce,
      retain: True,
    ),
  )
}

fn publish_state(
  client: mqtt_actor.Client,
  topic: String,
  on: Bool,
) -> Nil {
  let payload = bool_to_on_off(on)
  mqtt_actor.publish(
    client,
    mqtt.PublishData(
      topic:,
      payload: bit_array.from_string(payload),
      qos: mqtt.AtLeastOnce,
      retain: True,
    ),
  )
}

/// Return the system hostname, replacing hyphens with underscores so the
/// result is safe as an MQTT topic segment and HA unique_id prefix.
fn default_device_prefix() -> String {
  inet_gethostname()
  |> string.replace(each: "-", with: "_")
}

@external(erlang, "ha_client_ffi", "gethostname")
fn inet_gethostname() -> String

/// Convert "kitchen_terminal" -> "Kitchen Terminal"
fn humanize_prefix(prefix: String) -> String {
  string.split(prefix, "_")
  |> list.map(string.capitalise)
  |> string.join(" ")
}

// DISPLAY CONTROL -------------------------------------------------------------

fn set_display_power(config: Config, on: Bool) -> Nil {
  case config.display_control_scheme, config.display_output {
    Some("swaymsg"), Some(output) -> {
      let power = case on {
        True -> "on"
        False -> "off"
      }
      log.println(
        "[ha_client] running: swaymsg output " <> output <> " power " <> power,
      )
      let env = build_wayland_env()
      // swaymsg needs SWAYSOCK — find it by globbing the runtime dir.
      let env =
        case find_sway_socket(env) {
          Ok(sock) -> [#("SWAYSOCK", sock), ..env]
          Error(reason) -> {
            log.println("[ha_client] swaymsg: could not find SWAYSOCK: " <> reason)
            env
          }
        }
      run_display_command("swaymsg", ["output", output, "power", power], env)
    }
    Some("wlopm"), Some(output) -> {
      let flag = case on {
        True -> "--on"
        False -> "--off"
      }
      log.println("[ha_client] running: wlopm " <> flag <> " " <> output)
      run_display_command("wlopm", [flag, output], build_wayland_env())
    }
    Some("wlr-randr"), Some(output) -> {
      let flag = case on {
        True -> "--on"
        False -> "--off"
      }
      log.println(
        "[ha_client] running: wlr-randr --output " <> output <> " " <> flag,
      )
      run_display_command(
        "wlr-randr",
        ["--output", output, flag],
        build_wayland_env(),
      )
    }
    Some(scheme), _ -> {
      log.println(
        "[ha_client] unknown DISPLAY_CONTROL_SCHEME: " <> scheme,
      )
      Nil
    }
    None, _ -> {
      log.println(
        "[ha_client] display control not configured (DISPLAY_CONTROL_SCHEME or DISPLAY_OUTPUT unset), skipping",
      )
      Nil
    }
  }
}

/// Build the list of Wayland environment variables to pass to display control
/// commands. Reads WAYLAND_DISPLAY and XDG_RUNTIME_DIR from the current
/// process environment.
fn build_wayland_env() -> List(#(String, String)) {
  [
    envoy.get("WAYLAND_DISPLAY")
      |> result.map(fn(v) { #("WAYLAND_DISPLAY", v) }),
    envoy.get("XDG_RUNTIME_DIR")
      |> result.map(fn(v) { #("XDG_RUNTIME_DIR", v) }),
  ]
  |> list.filter_map(fn(r) { r })
}

/// Find the sway IPC socket path.  Sway's kiosk config creates a stable
/// symlink at $XDG_RUNTIME_DIR/sway.sock on startup (via `exec ln -sf
/// $SWAYSOCK .../sway.sock`), so we can use a fixed path rather than
/// globbing for the PID-named socket.
fn find_sway_socket(
  env: List(#(String, String)),
) -> Result(String, String) {
  list.find(env, fn(pair) { pair.0 == "XDG_RUNTIME_DIR" })
  |> result.map(fn(pair) { pair.1 <> "/sway.sock" })
  |> result.replace_error("XDG_RUNTIME_DIR not set")
}

/// Run a display control command, logging success or failure.
fn run_display_command(
  cmd: String,
  args: List(String),
  env: List(#(String, String)),
) -> Nil {
  case
    shellout.command(run: cmd, with: args, in: ".", opt: [
      shellout.SetEnvironment(env),
    ])
  {
    Ok(out) -> {
      let out = string.trim(out)
      case string.is_empty(out) {
        True -> log.println("[ha_client] " <> cmd <> ": success")
        False -> log.println("[ha_client] " <> cmd <> " output: " <> out)
      }
    }
    Error(#(exit_code, out)) -> {
      log.println(
        "[ha_client] "
        <> cmd
        <> " FAILED (exit "
        <> int.to_string(exit_code)
        <> "): "
        <> string.trim(out),
      )
    }
  }
}
