// IMPORTS ---------------------------------------------------------------------

import cal.{type Event}

// CONFIGURATION ---------------------------------------------------------------

/// CalDAV credentials loaded from environment variables at startup.
/// CALDAV_URL      — e.g. "https://caldav.icloud.com"
/// CALDAV_USERNAME — Apple ID email address
/// CALDAV_PASSWORD — app-specific password from appleid.apple.com
pub type Config {
  Config(url: String, username: String, password: String)
}

// PUBLIC API ------------------------------------------------------------------

/// Fetch all events in the next 7 days from the CalDAV server.
/// Returns a list of Events or an error string suitable for display.
pub fn fetch_events(_config: Config) -> Result(List(Event), String) {
  // Implementation will:
  // 1. Send a CalDAV REPORT request with a time-range filter
  // 2. Parse the XML (iCalendar) response
  // 3. Map each VEVENT into a calendar.Event
  todo as "caldav.fetch_events not yet implemented"
}

/// Load credentials from environment variables.
/// Returns an error string if any required variable is missing.
pub fn config_from_env() -> Result(Config, String) {
  // TODO: use gleam_erlang os.get_env to read CALDAV_URL, CALDAV_USERNAME,
  // CALDAV_PASSWORD and return Config or a descriptive error
  todo as "caldav.config_from_env not yet implemented"
}
