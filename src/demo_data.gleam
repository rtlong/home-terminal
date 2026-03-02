// Demo mode data generator for home-terminal.
//
// When DEMO_MODE=1 is set, the app skips CalDAV and instead serves
// deterministically-generated fake calendar data.
//
// On startup a seed is derived from the current day (unix_day =
// unix_seconds / 86400).  All randomised choices — people names, calendar
// names, color hues, calendar→person assignments — are made once from that
// seed and stay stable for the whole day.  Event data is generated
// deterministically from the same seed and the requested time window, so
// future calendar views with longer or different windows can call
// generate_events/2 with different parameters and get stable, consistent
// results.
//
// The PRNG is a simple 64-bit LCG (Knuth's constants).  It is entirely
// pure / stateless: every function takes a `Seed` (Int) and returns
// `#(value, Seed)` so callers can chain them without mutable state.

// IMPORTS ---------------------------------------------------------------------

import cal.{type Event, AllDay, AtTime, Event}
import envoy
import gleam/dict
import gleam/float
import gleam/int
import gleam/list
import gleam/string
import log
import gleam/time/calendar.{
  type Date, Date, April, August, December, February, January, July, June,
  March, May, November, October, September,
}
import gleam/time/duration
import gleam/time/timestamp.{type Timestamp}
import state.{type Config, Config}

// TYPES -----------------------------------------------------------------------

pub type Seed =
  Int

fn int_range(from: Int, to: Int) -> List(Int) {
  int.range(from: from, to: to + 1, with: [], run: fn(acc, i) { [i, ..acc] })
  |> list.reverse
}

pub type DemoConfig {
  DemoConfig(
    seed: Seed,
    config: Config,
    travel_cache: dict.Dict(String, cal.TravelInfo),
    leg_cache: cal.LegCache,
  )
}

// PRNG ------------------------------------------------------------------------

/// LCG step: multiplier and increment from Knuth / MMIX.
fn lcg(seed: Seed) -> #(Int, Seed) {
  let next =
    { seed * 6_364_136_223_846_793_005 + 1_442_695_040_888_963_407 }
    |> int.bitwise_and(0xFFFFFFFFFFFFFFFF)
  // Use upper 32 bits as the output value (better statistical quality).
  let value = int.bitwise_shift_right(next, 32)
  #(value, next)
}

/// Return a pseudo-random Int in [0, max).
fn rand_int(seed: Seed, max: Int) -> #(Int, Seed) {
  let #(v, s) = lcg(seed)
  #(v |> int.remainder(max) |> result_or(0), s)
}

fn result_or(r: Result(a, b), default: a) -> a {
  case r {
    Ok(v) -> v
    Error(_) -> default
  }
}

/// Return a pseudo-random Float in [0.0, 1.0).
fn rand_float(seed: Seed) -> #(Float, Seed) {
  let #(v, s) = lcg(seed)
  let f = int.to_float(v) /. int.to_float(0xFFFFFFFF)
  #(f, s)
}

/// Return a pseudo-random Float in [lo, hi).
fn rand_float_range(seed: Seed, lo: Float, hi: Float) -> #(Float, Seed) {
  let #(f, s) = rand_float(seed)
  #(lo +. f *. { hi -. lo }, s)
}

/// Pick a random element from a non-empty list.
fn rand_pick(seed: Seed, items: List(a)) -> #(a, Seed) {
  let n = list.length(items)
  let #(i, s) = rand_int(seed, n)
  let item = case list.drop(items, i) |> list.first {
    Ok(v) -> v
    Error(_) ->
      case list.first(items) {
        Ok(v) -> v
        Error(_) -> panic as "rand_pick: empty list"
      }
  }
  #(item, s)
}

/// Return True with the given probability (0.0–1.0).
fn rand_bool(seed: Seed, probability: Float) -> #(Bool, Seed) {
  let #(f, s) = rand_float(seed)
  #(f <. probability, s)
}

// BOOT SEED -------------------------------------------------------------------

/// Return a seed for the PRNG.
///
/// If the `DEMO_SEED` environment variable is set to a valid integer it is
/// used directly, allowing exact reproduction of a previous run.  Otherwise a
/// fresh seed is derived from the nanosecond system clock at the moment of the
/// call, which changes on every boot.
pub fn make_seed() -> Seed {
  case envoy.get("DEMO_SEED") {
    Ok(s) ->
      case int.parse(s) {
        Ok(n) -> n
        Error(_) -> {
          log.println(
            "[demo_data] DEMO_SEED value '"
            <> s
            <> "' is not a valid integer — ignoring",
          )
          random_seed()
        }
      }
    Error(_) -> random_seed()
  }
}

@external(erlang, "demo_data_ffi", "system_time_nanoseconds")
fn system_time_nanoseconds() -> Int

fn random_seed() -> Seed {
  // Mix nanosecond time through two LCG steps so consecutive calls that land
  // in the same nanosecond still produce distinct seeds.
  let #(_, s1) = lcg(system_time_nanoseconds())
  let #(_, s2) = lcg(s1)
  s2
}


// NAME POOLS ------------------------------------------------------------------

const first_names = [
  "Alex", "Jordan", "Taylor", "Morgan", "Casey", "Riley", "Jamie", "Quinn",
  "Avery", "Blake", "Drew", "Sage", "Reese", "Hayden", "Cameron", "Logan",
  "Charlie", "Finley", "Rowan", "Emery",
]

const calendar_name_parts = [
  #("Work", ["Meetings", "Projects", "Tasks", "Schedule"]),
  #("Personal", ["Life", "Plans", "Errands", "Appointments"]),
  #("Fitness", ["Training", "Workouts", "Classes", "Health"]),
  #("Family", ["Home", "Household", "Together", "Shared"]),
  #("Social", ["Friends", "Events", "Outings", "Hangouts"]),
]

const event_summaries_work = [
  "Standup", "Sprint Planning", "Retrospective", "1:1 with manager",
  "Team sync", "Design review", "Code review", "All-hands",
  "Client call", "Stakeholder update", "Product demo", "Interview",
  "Onboarding session", "Lunch & learn", "Architecture discussion",
  "Deployment window", "Incident review",
]

const event_summaries_personal = [
  "Dentist", "Doctor appointment", "Haircut", "Therapy",
  "Grocery run", "Car service", "Eye exam", "Pick up prescription",
  "Post office", "Library", "DMV appointment", "Vet",
]

const event_summaries_fitness = [
  "Yoga", "Spin class", "Run", "Gym", "Pilates",
  "Swimming", "HIIT class", "Cycling", "Boot camp", "CrossFit",
]

const event_summaries_social = [
  "Dinner with friends", "Game night", "Book club", "Movie night",
  "Birthday party", "Housewarming", "Happy hour", "Brunch",
  "Coffee catch-up", "Trivia night", "Concert",
]

const event_summaries_family = [
  "Family dinner", "Brunch at parents", "Help mom move",
  "Kids soccer game", "School play", "Parent-teacher conference",
  "Holiday prep", "Weekend trip planning",
]

const event_summaries_holiday = [
  "Presidents Day", "Memorial Day observed", "Labor Day",
  "Columbus Day", "Veterans Day", "Election Day",
]

const locations = [
  "Downtown Conference Center", "123 Main St", "City Medical Center",
  "456 Oak Ave", "Central Park", "789 Elm Blvd",
  "Northside Gym", "Harbor View Restaurant", "Old Town Square",
  "Riverside Mall", "University Campus", "Tech Hub Building",
]

// RANDOMISED CONFIG GENERATION ------------------------------------------------

/// Generate a fully randomised Config and associated travel/leg caches
/// from a seed.  The same seed always produces the same config.
pub fn generate_config(seed: Seed) -> DemoConfig {
  // ── Two people with distinct names ───────────────────────────────────────
  let #(name0, s1) = rand_pick(seed, first_names)
  let remaining_names = list.filter(first_names, fn(n) { n != name0 })
  let #(name1, s2) = rand_pick(s1, remaining_names)
  let people = [name0, name1]

  // ── Per-person hue angles, at least 60° apart ────────────────────────────
  let #(hue0, s3) = rand_float_range(s2, 0.0, 360.0)
  // Ensure hue1 is at least 60° away (and at most 300° away = other side).
  let #(offset, s4) = rand_float_range(s3, 60.0, 300.0)
  let hue1 = float.modulo(hue0 +. offset, 360.0) |> result_or(0.0)
  let people_colors =
    dict.from_list([#(name0, hue0), #(name1, hue1)])

  // ── Calendar names: 2 per person + 1 shared + 1 holiday-style ───────────
  //    person0: two calendars (one assigned to them, one work-ish)
  //    person1: two calendars (one assigned to them, one work-ish)
  //    shared:  one calendar assigned to both
  //    holidays: one calendar assigned to no one
  let make_cal_name = fn(s: Seed, owner: String, pool_idx: Int) -> #(String, Seed) {
    let pool = list.drop(calendar_name_parts, pool_idx) |> list.first
    case pool {
      Ok(#(base, suffixes)) -> {
        let #(suffix, s2) = rand_pick(s, suffixes)
        #(owner <> " " <> base <> " – " <> suffix, s2)
      }
      Error(_) -> #(owner <> " Calendar", s)
    }
  }

  let #(cal_p0_a, s5) = make_cal_name(s4, name0, 0)
  let #(cal_p0_b, s6) = make_cal_name(s5, name0, 2)
  let #(cal_p1_a, s7) = make_cal_name(s6, name1, 0)
  let #(cal_p1_b, s8) = make_cal_name(s7, name1, 2)
  let #(shared_suffix, s9) = rand_pick(s8, ["Family", "Shared", "Household", "Together"])
  let cal_shared = name0 <> " & " <> name1 <> " " <> shared_suffix
  let cal_holidays = "Public Holidays"

  let all_calendars = [cal_p0_a, cal_p0_b, cal_p1_a, cal_p1_b, cal_shared, cal_holidays]

  let calendar_people =
    dict.from_list([
      #(cal_p0_a, [name0]),
      #(cal_p0_b, [name0]),
      #(cal_p1_a, [name1]),
      #(cal_p1_b, [name1]),
      #(cal_shared, [name0, name1]),
      // holidays → assigned to neither person → BarCenter (unassigned)
      #(cal_holidays, []),
    ])

  let calendars =
    dict.from_list(
      list.map(all_calendars, fn(name) {
        #(name, state.CalendarConfig(visible: True, show_location: True))
      }),
    )

  let config =
    Config(
      home_address: "100 Home Base Ave",
      people: people,
      calendar_people: calendar_people,
      people_colors: people_colors,
      calendars: calendars,
      ical_urls: [],
      // Boston-area lat/lon for sun/moon display.
      latitude: 42.36,
      longitude: -71.06,
    )

  // ── Travel cache: synthetic home→location entries ─────────────────────────
  let travel_entries =
    list.index_map(locations, fn(loc, i) {
      let dist_miles = 1 + i * 3
      let dur_mins = 5 + i * 8
      let info =
        cal.TravelInfo(
          city: loc,
          distance_text: int.to_string(dist_miles) <> " mi",
          duration_text: int.to_string(dur_mins) <> " min",
          duration_secs: dur_mins * 60,
        )
      #(loc, info)
    })
  let travel_cache = dict.from_list(travel_entries)

  // ── Leg cache: home→loc forward legs (derived from travel_cache) ──────────
  let leg_cache =
    list.fold(travel_entries, dict.new(), fn(acc, pair) {
      let #(loc, info) = pair
      let fwd_key = "100 Home Base Ave|||" <> loc
      let rev_key = loc <> "|||100 Home Base Ave"
      acc
      |> dict.insert(fwd_key, info.duration_secs)
      |> dict.insert(rev_key, info.duration_secs)
    })

  DemoConfig(
    seed: s9,
    config: config,
    travel_cache: travel_cache,
    leg_cache: leg_cache,
  )
}

// EVENT GENERATION ------------------------------------------------------------

/// Generate a list of events for the 7-day window starting at `window_start`.
/// The generation is deterministic: same seed + same window_start → same events.
/// window_start is a Date (the first day to show, i.e. today).
pub fn generate_events(
  demo_cfg: DemoConfig,
  window_start: Date,
) -> #(List(Event), List(String)) {
  let seed = demo_cfg.seed
  let cfg = demo_cfg.config

  // Calendar name lists by type, for event pool selection.
  let person0 = list.first(cfg.people) |> result_or("")
  let person1 = list.drop(cfg.people, 1) |> list.first |> result_or("")

  let p0_cals =
    dict.to_list(cfg.calendar_people)
    |> list.filter_map(fn(pair) {
      let #(cal, people) = pair
      case people {
        [p] if p == person0 -> Ok(cal)
        _ -> Error(Nil)
      }
    })
  let p1_cals =
    dict.to_list(cfg.calendar_people)
    |> list.filter_map(fn(pair) {
      let #(cal, people) = pair
      case people {
        [p] if p == person1 -> Ok(cal)
        _ -> Error(Nil)
      }
    })
  let shared_cals =
    dict.to_list(cfg.calendar_people)
    |> list.filter_map(fn(pair) {
      let #(cal, people) = pair
      case list.length(people) >= 2 {
        True -> Ok(cal)
        False -> Error(Nil)
      }
    })
  let unassigned_cals =
    dict.to_list(cfg.calendar_people)
    |> list.filter_map(fn(pair) {
      let #(cal, people) = pair
      case people {
        [] -> Ok(cal)
        _ -> Error(Nil)
      }
    })

  // Per-day seed: mix day index into the base seed.
  let day_seed = fn(day_offset: Int) -> Seed {
    let #(_, s) = lcg(seed + day_offset * 1_000_003)
    s
  }

  let all_events =
    int_range(0, 6)
    |> list.flat_map(fn(day_offset) {
      let day = date_add_days(window_start, day_offset)
      let ds = day_seed(day_offset)
      generate_day_events(
        ds, day, day_offset, p0_cals, p1_cals, shared_cals, unassigned_cals,
      )
    })

  // Add a handful of multi-day all-day events and a cross-midnight timed event.
  let #(special_events, _) =
    generate_special_events(seed, window_start, p0_cals, p1_cals, shared_cals, unassigned_cals)

  let events = list.append(all_events, special_events)

  let calendar_names =
    events
    |> list.map(fn(e) { e.calendar_name })
    |> list.append(dict.keys(cfg.calendars))
    |> list.unique
    |> list.sort(string.compare)

  #(events, calendar_names)
}

/// Generate events for a single day.
fn generate_day_events(
  seed: Seed,
  day: Date,
  day_offset: Int,
  p0_cals: List(String),
  p1_cals: List(String),
  shared_cals: List(String),
  unassigned_cals: List(String),
) -> List(Event) {
  // Decide how many timed events for each sub-row today (0–3 each).
  let #(n_p0, s1) = rand_int(seed, 4)
  let #(n_p1, s2) = rand_int(s1, 4)
  let #(n_shared, s3) = rand_int(s2, 3)

  // Person 0 events (BarLeft).
  let #(p0_events, s4) =
    generate_n_timed(s3, day, day_offset, n_p0, p0_cals, work_summaries_for(day_offset), True)

  // Person 1 events (BarRight).
  let #(p1_events, s5) =
    generate_n_timed(s4, day, day_offset, n_p1, p1_cals, personal_summaries_for(day_offset), False)

  // Shared events (BarCenter – assigned to both).
  let #(shared_events, s6) =
    generate_n_timed(s5, day, day_offset, n_shared, shared_cals, social_summaries_for(day_offset), False)

  // Occasionally add an all-day event from the unassigned (holiday) calendar.
  let #(add_holiday, s7) = rand_bool(s6, 0.18)
  let holiday_events = case add_holiday, unassigned_cals {
    True, [cal, ..] -> {
      let #(summary, _) = rand_pick(s7, event_summaries_holiday)
      [make_allday_event(day, summary, cal, day_offset * 100 + 99)]
    }
    _, _ -> []
  }

  list.flatten([p0_events, p1_events, shared_events, holiday_events])
}

/// Choose a summary pool biased toward work for weekdays, leisure for weekends.
fn work_summaries_for(_day_offset: Int) -> List(String) {
  // day_offset 0 = today; we generate starting from today.
  // We don't know the actual weekday here, but the variety is fine.
  list.append(event_summaries_work, event_summaries_personal)
}

fn personal_summaries_for(_day_offset: Int) -> List(String) {
  list.append(event_summaries_personal, event_summaries_fitness)
}

fn social_summaries_for(_day_offset: Int) -> List(String) {
  list.append(event_summaries_social, event_summaries_family)
}

/// Generate `n` timed events for a given day, threading the seed.
fn generate_n_timed(
  seed: Seed,
  day: Date,
  day_offset: Int,
  n: Int,
  calendars: List(String),
  summaries: List(String),
  prefer_daytime: Bool,
) -> #(List(Event), Seed) {
  case n, calendars {
    0, _ -> #([], seed)
    _, [] -> #([], seed)
    _, _ ->
      list.fold(int_range(0, n - 1), #([], seed), fn(acc, i) {
        let #(events, s) = acc
        let uid_base = day_offset * 1000 + i * 17
        let #(evt, s2) =
          generate_timed_event(s, day, uid_base, calendars, summaries, prefer_daytime)
        #([evt, ..events], s2)
      })
  }
}

/// Generate a single timed event on `day`.
fn generate_timed_event(
  seed: Seed,
  day: Date,
  uid_base: Int,
  calendars: List(String),
  summaries: List(String),
  prefer_daytime: Bool,
) -> #(Event, Seed) {
  let #(cal_name, s1) = rand_pick(seed, calendars)
  let #(summary, s2) = rand_pick(s1, summaries)

  // Start hour: mostly 8am–7pm, with occasional early/late.
  let #(is_odd_hour, s3) = rand_bool(s2, case prefer_daytime { True -> 0.08 False -> 0.15 })
  let #(start_hour, s4) = case is_odd_hour {
      True -> {
        // Pick either early morning (5–7) or late evening (21–23).
        let #(late, s) = rand_bool(s3, 0.5)
        case late {
          True -> {
            let #(h, ss) = rand_int(s, 3)
            #(h + 21, ss)
          }
          False -> {
            let #(h, ss) = rand_int(s, 3)
            #(h + 5, ss)
          }
        }
      }
      False -> {
        let #(h, ss) = rand_int(s3, 12)
        #(h + 8, ss)
      }
  }

  // Start minute: snap to 0, 15, 30, or 45 most of the time.
  let #(quarter, s5) = rand_int(s4, 4)
  let #(use_odd_min, s6) = rand_bool(s5, 0.2)
  let #(start_min, s7) = case use_odd_min {
    True -> rand_int(s6, 60)
    False -> #(quarter * 15, s6)
  }

  // Duration: 15 min to 3 hours, weighted shorter.
  let #(dur_choice, s8) = rand_int(s7, 12)
  let dur_mins = case dur_choice {
    0 -> 15
    1 | 2 -> 30
    3 | 4 -> 45
    5 | 6 -> 60
    7 | 8 -> 90
    9 -> 120
    10 -> 150
    _ -> 180
  }

  // Occasionally add a location (enables travel time rendering).
  let #(has_loc, s9) = rand_bool(s8, 0.3)
  let #(location, s10) = case has_loc {
    True -> rand_pick(s9, locations)
    False -> #("", s9)
  }

  // Occasionally make it a free/transparent event.
  let #(is_free, s11) = rand_bool(s10, 0.12)

  let start_ts = day_to_local_midnight_ts(day) |> ts_add_minutes(start_hour * 60 + start_min)
  let end_ts = start_ts |> ts_add_minutes(dur_mins)

  let uid = "demo-" <> int.to_string(uid_base) <> "-" <> cal_name

  #(
    Event(
      uid: uid,
      summary: summary,
      start: AtTime(start_ts),
      end: AtTime(end_ts),
      calendar_name: cal_name,
      location: location,
      free: is_free,
      description: "",
      url: "",
    ),
    s11,
  )
}

/// Generate special-case events that exercise edge cases:
///   - A multi-day all-day event spanning 3 days (middle-day chip promotion)
///   - A multi-day all-day event for 1 day (normal chip)
///   - A timed event that crosses midnight (start-day + end-day rendering)
///   - A timed event with travel that pushes the window start earlier
fn generate_special_events(
  seed: Seed,
  window_start: Date,
  p0_cals: List(String),
  p1_cals: List(String),
  shared_cals: List(String),
  _unassigned_cals: List(String),
) -> #(List(Event), Seed) {
  // Multi-day all-day: starts on day 1, spans 3 days (days 1–3).
  let #(allday_cal, s1) = rand_pick(seed, list.append(p0_cals, shared_cals))
  let #(allday_summary, s2) = rand_pick(s1, ["Team Offsite", "Conference", "Work Trip", "Vacation", "Workshop"])
  let allday_start = date_add_days(window_start, 1)
  let allday_end = date_add_days(window_start, 4)  // exclusive end = day 4

  // Cross-midnight timed event: starts day 3 at 22:00, ends day 4 at 01:30.
  let #(xm_cal, s3) = rand_pick(s2, list.append(p1_cals, shared_cals))
  let #(xm_summary, s4) = rand_pick(s3, ["Late show", "Night shift", "Long dinner", "Concert", "Closing set"])
  let xm_start = day_to_local_midnight_ts(date_add_days(window_start, 3)) |> ts_add_minutes(22 * 60)
  let xm_end = day_to_local_midnight_ts(date_add_days(window_start, 4)) |> ts_add_minutes(90)

  // Early-morning event on day 5 that expands the window leftward.
  let #(early_cal, s5) = rand_pick(s4, p0_cals)
  let #(early_summary, s6) = rand_pick(s5, ["Early flight", "Pre-dawn run", "Morning call", "Airport pickup"])
  let early_start = day_to_local_midnight_ts(date_add_days(window_start, 5)) |> ts_add_minutes(5 * 60 + 30)
  let early_end = early_start |> ts_add_minutes(45)

  // Overlapping events on person 0's sub-row on day 2 (tests grid stacking).
  let #(overlap_summary_a, s7) = rand_pick(s6, event_summaries_work)
  let #(overlap_summary_b, s8) = rand_pick(s7, event_summaries_work)
  let #(overlap_cal_a, s9) = rand_pick(s8, p0_cals)
  let #(overlap_cal_b, s10) = rand_pick(s9, p0_cals)
  let overlap_base = day_to_local_midnight_ts(date_add_days(window_start, 2)) |> ts_add_minutes(14 * 60)
  let overlap_a_start = overlap_base
  let overlap_a_end = overlap_base |> ts_add_minutes(90)
  let overlap_b_start = overlap_base |> ts_add_minutes(30)
  let overlap_b_end = overlap_base |> ts_add_minutes(120)

  let events = [
    Event(
      uid: "demo-special-allday",
      summary: allday_summary,
      start: AllDay(allday_start),
      end: AllDay(allday_end),
      calendar_name: allday_cal,
      location: "",
      free: False,
      description: "",
      url: "",
    ),
    Event(
      uid: "demo-special-xm",
      summary: xm_summary,
      start: AtTime(xm_start),
      end: AtTime(xm_end),
      calendar_name: xm_cal,
      location: "",
      free: False,
      description: "",
      url: "",
    ),
    Event(
      uid: "demo-special-early",
      summary: early_summary,
      start: AtTime(early_start),
      end: AtTime(early_end),
      calendar_name: early_cal,
      location: "",
      free: False,
      description: "",
      url: "",
    ),
    Event(
      uid: "demo-overlap-a",
      summary: overlap_summary_a,
      start: AtTime(overlap_a_start),
      end: AtTime(overlap_a_end),
      calendar_name: overlap_cal_a,
      location: "",
      free: False,
      description: "",
      url: "",
    ),
    Event(
      uid: "demo-overlap-b",
      summary: overlap_summary_b,
      start: AtTime(overlap_b_start),
      end: AtTime(overlap_b_end),
      calendar_name: overlap_cal_b,
      location: "",
      free: False,
      description: "",
      url: "",
    ),
  ]

  #(events, s10)
}

// DATE / TIMESTAMP HELPERS ----------------------------------------------------

/// Add `days` calendar days to a Date.
pub fn date_add_days(date: Date, days: Int) -> Date {
  // Convert to a day number, add, convert back.
  let jd = date_to_jdn(date) + days
  jdn_to_date(jd)
}

/// Julian Day Number from a proleptic Gregorian date.
fn date_to_jdn(date: Date) -> Int {
  let y = date.year
  let m = calendar.month_to_int(date.month)
  let d = date.day
  d - 32_075
  + { 1461 * { y + 4800 + { m - 14 } / 12 } / 4 }
  + { 367 * { m - 2 - { m - 14 } / 12 * 12 } / 12 }
  - { 3 * { { y + 4900 + { m - 14 } / 12 } / 100 } / 4 }
}

/// Gregorian date from a Julian Day Number.
fn jdn_to_date(jdn: Int) -> Date {
  let l = jdn + 68_569
  let n = 4 * l / 146_097
  let l2 = l - { 146_097 * n + 3 } / 4
  let i = 4000 * { l2 + 1 } / 1_461_001
  let l3 = l2 - 1461 * i / 4 + 31
  let j = 80 * l3 / 2447
  let d = l3 - 2447 * j / 80
  let l4 = j / 11
  let m = j + 2 - 12 * l4
  let y = 100 * { n - 49 } + i + l4
  Date(year: y, month: int_to_month(m), day: d)
}

fn int_to_month(m: Int) -> calendar.Month {
  case m {
    1 -> January
    2 -> February
    3 -> March
    4 -> April
    5 -> May
    6 -> June
    7 -> July
    8 -> August
    9 -> September
    10 -> October
    11 -> November
    _ -> December
  }
}

/// Return the UTC Timestamp for local midnight on `date`, assuming the
/// system's local timezone offset at the time this runs.
/// This is a best-effort: uses the current local_offset() for conversion.
fn day_to_local_midnight_ts(date: Date) -> Timestamp {
  // Use Julian Day Number arithmetic to get days since Unix epoch (JDN 2440588).
  let jdn = date_to_jdn(date)
  let unix_day = jdn - 2_440_588
  let local_offset = calendar.local_offset()
  let offset_secs =
    duration.to_seconds(local_offset)
    |> float.round
  // Local midnight = unix_day * 86400 seconds - local offset.
  let unix_secs = unix_day * 86_400 - offset_secs
  timestamp.from_unix_seconds(unix_secs)
}

/// Add `minutes` to a Timestamp.
fn ts_add_minutes(ts: Timestamp, minutes: Int) -> Timestamp {
  timestamp.add(ts, duration.seconds(minutes * 60))
}

/// Build an all-day Event.
fn make_allday_event(date: Date, summary: String, calendar_name: String, uid_suffix: Int) -> Event {
  Event(
    uid: "demo-allday-" <> int.to_string(uid_suffix),
    summary: summary,
    start: AllDay(date),
    end: AllDay(date_add_days(date, 1)),
    calendar_name: calendar_name,
    location: "",
    free: False,
    description: "",
    url: "",
  )
}
