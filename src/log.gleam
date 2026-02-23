// Simple file logger.
//
// Appends timestamped lines to ~/.local/share/home-terminal/app.log via FFI.
// The log path is set once at startup by calling set_path/1.
// Falls back to io.println if no path has been set (e.g. in tests).

import gleam/io
import state

// MODULE-LEVEL MUTABLE PATH ---------------------------------------------------
// We store the log path in the process dictionary so it's accessible without
// threading it through every call site.

pub fn set_path(path: String) -> Nil {
  log_ffi_set_path(path)
}

pub fn println(line: String) -> Nil {
  case log_ffi_get_path() {
    "" -> io.println(line)
    path -> log_ffi_write_line(path, line)
  }
}

pub fn default_path() -> String {
  state.data_dir() <> "/app.log"
}

@external(erlang, "log_ffi", "set_path")
fn log_ffi_set_path(path: String) -> Nil

@external(erlang, "log_ffi", "get_path")
fn log_ffi_get_path() -> String

@external(erlang, "log_ffi", "write_line")
fn log_ffi_write_line(path: String, line: String) -> Nil
