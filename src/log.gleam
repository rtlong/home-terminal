// Simple logger — writes timestamped lines to stdout.
//
// Timestamps are UTC ISO-8601 format (second precision).
// When running under systemd, journald captures stdout and adds its own
// metadata; the in-band timestamp makes log lines self-contained when
// reading raw journal output.

import gleam/io
import gleam/string
import gleam/time/duration
import gleam/time/timestamp

pub fn println(line: String) -> Nil {
  let ts =
    timestamp.system_time()
    |> timestamp.to_rfc3339(duration.seconds(0))
    // Trim sub-second precision: "2026-03-01T15:03:53.123Z" -> "2026-03-01T15:03:53"
    |> fn(s) {
      case string.split_once(s, ".") {
        Ok(#(before, _)) -> before
        Error(_) -> s
      }
    }
  io.println(ts <> " " <> line)
}
