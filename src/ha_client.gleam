// ha_client.gleam — Home Assistant integration via MQTT discovery.
//
// Connects to an MQTT broker, registers a HA device with two switch entities
// (display_power and dark_mode), and listens for commands from HA automations.
//
// Env vars:
//   MQTT_HOST, MQTT_PORT (default 1883), MQTT_USERNAME, MQTT_PASSWORD
//   HA_DEVICE_PREFIX (default "kitchen_terminal")
//   DISPLAY_OUTPUT, DISPLAY_CONTROL_SCHEME — both must be set for display control

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
    envoy.get("MQTT_PASSWORD")
    |> result.replace_error("MQTT_PASSWORD not set"),
  )
  let mqtt_port =
    envoy.get("MQTT_PORT")
    |> result.try(int.parse)
    |> result.unwrap(1883)
  let device_prefix =
    envoy.get("HA_DEVICE_PREFIX")
    |> result.unwrap("kitchen_terminal")
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
}

type State {
  State(
    config: Config,
    mqtt_client: mqtt_actor.Client,
    display_power: Bool,
    dark_mode: Bool,
    clients: List(ClientCallback),
    self: Subject(Msg),
  )
}

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
    )
  setup_session(client, prefix, initial_state)

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
      // Schedule reconnect after 5 seconds
      let self = state.self
      let _ = process.spawn_unlinked(fn() {
        process.sleep(5000)
        process.send(self, Reconnect)
      })
      actor.continue(state)
    }

    MqttConnectionChanged(mqtt.ConnectAccepted(_)) -> {
      log.println("[ha_client] connected, re-establishing session")
      let prefix = state.config.device_prefix
      // Re-publish discovery, availability, current state, and re-subscribe
      setup_session(state.mqtt_client, prefix, state)
      actor.continue(state)
    }

    MqttConnectionChanged(conn_state) -> {
      log.println(
        "[ha_client] connection state: " <> string.inspect(conn_state),
      )
      actor.continue(state)
    }

    Reconnect -> {
      log.println("[ha_client] attempting reconnect...")
      let will =
        mqtt.PublishData(
          topic: state.config.device_prefix <> "/availability",
          payload: bit_array.from_string("offline"),
          qos: mqtt.AtLeastOnce,
          retain: True,
        )
      mqtt_actor.connect(state.mqtt_client, True, Some(will))
      actor.continue(state)
    }
  }
}

fn broadcast(state: State) -> Nil {
  let ha_state =
    HaState(display_power: state.display_power, dark_mode: state.dark_mode)
  list.each(state.clients, fn(callback) { callback(ha_state) })
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

/// Convert "kitchen_terminal" -> "Kitchen Terminal"
fn humanize_prefix(prefix: String) -> String {
  string.split(prefix, "_")
  |> list.map(string.capitalise)
  |> string.join(" ")
}

// DISPLAY CONTROL -------------------------------------------------------------

fn set_display_power(config: Config, on: Bool) -> Nil {
  case config.display_control_scheme, config.display_output {
    Some("wlr-randr"), Some(output) -> {
      let flag = case on {
        True -> "--on"
        False -> "--off"
      }
      log.println(
        "[ha_client] running: wlr-randr --output " <> output <> " " <> flag,
      )
      case
        shellout.command(
          run: "wlr-randr",
          with: ["--output", output, flag],
          in: ".",
          opt: [],
        )
      {
        Ok(out) -> {
          let out = string.trim(out)
          case string.is_empty(out) {
            True -> log.println("[ha_client] wlr-randr: success")
            False -> log.println("[ha_client] wlr-randr output: " <> out)
          }
        }
        Error(#(exit_code, out)) -> {
          log.println(
            "[ha_client] wlr-randr FAILED (exit "
            <> int.to_string(exit_code)
            <> "): "
            <> string.trim(out),
          )
        }
      }
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
