// Color palette generation for home-terminal.
//
// All colors are expressed in OKLCH (lightness, chroma, hue).
// Hue angles are in degrees [0, 360).
//
// Design:
//   - Each person has a single primary hue angle.
//   - Single-person calendars: analogous colors fanned around that hue.
//   - Both-person calendars: analogous colors around the shorter-arc midpoint.
//   - No-person calendars: analogous colors around the complement of the
//     overall scheme base hue.
//   - The app's bg/surface/accent CSS variables are derived from the base hue
//     so the whole UI is subtly tinted toward the scheme.

// IMPORTS ---------------------------------------------------------------------

import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/result
import gleam/string

// TYPES -----------------------------------------------------------------------

/// A generated color palette for the full app.
pub type Palette {
  Palette(
    /// Maps calendar name → CSS oklch() color string.
    calendar_colors: Dict(String, String),
    /// CSS custom property block (a `<style>` element's text content) with
    /// bg/surface/border/accent variables derived from the scheme.
    theme_vars: String,
    /// The night/twilight overlay color for the sun gradient.
    night_color: String,
  )
}

// CONSTANTS -------------------------------------------------------------------

// Event bar: vivid, high chroma, readable in both themes.
const bar_l = 0.65

const bar_c = 0.19

// Travel tint: same hue, lower chroma, slightly lower lightness — clearly
// distinct from the bar but obviously the same family.
const travel_l = 0.38

const travel_c = 0.09

// PUBLIC API ------------------------------------------------------------------

/// Generate the full palette from the person hue assignments and calendar
/// → people mappings.
///
/// `person_hues`: Dict(person_name, hue_degrees)
/// `all_people`: ordered list of people (person 0 = left bar, person 1 = right)
/// `calendar_people`: Dict(cal_name, List(person_name))
/// `all_calendar_names`: every known calendar name (including unassigned ones)
pub fn generate(
  person_hues: Dict(String, Float),
  all_people: List(String),
  calendar_people: Dict(String, List(String)),
  all_calendar_names: List(String),
) -> Palette {
  // ── Step 1: compute target hue per "group key" ───────────────────────────
  // Group key = sorted list of assigned people, joined by "|".
  // "Ryan"        → Ryan's hue
  // "Alex|Ryan"   → midpoint hue of the two
  // ""            → complement of the base hue

  let base_hue = scheme_base_hue(person_hues, all_people)

  // Collect all distinct group keys and the calendars in each.
  let groups: Dict(String, List(String)) =
    list.fold(all_calendar_names, dict.new(), fn(acc, cal_name) {
      let people =
        dict.get(calendar_people, cal_name)
        |> result_unwrap_empty
      let key = group_key(people)
      let existing = dict.get(acc, key) |> result_unwrap_empty
      dict.insert(acc, key, [cal_name, ..existing])
    })

  // ── Step 2: assign analogous hues within each group ──────────────────────
  let cal_colors =
    dict.fold(groups, dict.new(), fn(acc, key, cal_names) {
      let target_hue = group_target_hue(key, person_hues, all_people, base_hue)
      let n = list.length(cal_names)
      // Fan width: spread evenly up to ±16° total (so each step ≤ 8°).
      let spread = float.min(32.0, int_to_float(n) *. 8.0)
      let step = case n {
        1 -> 0.0
        _ -> spread /. int_to_float(n - 1)
      }
      let start = target_hue -. spread /. 2.0
      // Sort cal names for deterministic assignment.
      let sorted = list.sort(cal_names, string.compare)
      list.index_fold(sorted, acc, fn(acc2, cal_name, i) {
        let hue = normalize_hue(start +. int_to_float(i) *. step)
        dict.insert(acc2, cal_name, oklch(bar_l, bar_c, hue))
      })
    })

  // ── Step 3: derive theme CSS vars from base_hue ──────────────────────────
  let accent_hue = normalize_hue(base_hue +. 60.0)
  let night_hue = normalize_hue(base_hue +. 220.0)

  let theme_vars =
    string.join(
      [
        // Dark mode (default)
        ":root, :host {",
        "  --color-bg:            oklch(0.10 0.018 "
          <> fmt_hue(base_hue)
          <> ");",
        "  --color-surface:       oklch(0.14 0.015 "
          <> fmt_hue(base_hue)
          <> ");",
        "  --color-surface-2:     oklch(0.19 0.012 "
          <> fmt_hue(base_hue)
          <> ");",
        "  --color-text:          oklch(0.95 0.008 "
          <> fmt_hue(base_hue)
          <> ");",
        "  --color-text-muted:    oklch(0.60 0.012 "
          <> fmt_hue(base_hue)
          <> ");",
        "  --color-text-faint:    oklch(0.42 0.010 "
          <> fmt_hue(base_hue)
          <> ");",
        "  --color-border:        oklch(0.22 0.012 "
          <> fmt_hue(base_hue)
          <> ");",
        "  --color-border-dim:    oklch(0.28 0.010 "
          <> fmt_hue(base_hue)
          <> ");",
        "  --color-accent:        oklch(0.75 0.20  "
          <> fmt_hue(accent_hue)
          <> ");",
        "  --color-accent-dim:    oklch(0.55 0.16  "
          <> fmt_hue(accent_hue)
          <> ");",
        "  --color-accent-border: oklch(0.65 0.18  "
          <> fmt_hue(accent_hue)
          <> ");",
        "  --color-accent-border-dim: oklch(0.30 0.10 "
          <> fmt_hue(accent_hue)
          <> ");",
        "}",
      ],
      "\n",
    )

  let night_color = "oklch(0.20 0.14 " <> fmt_hue(night_hue) <> " / 80%)"

  Palette(calendar_colors: cal_colors, theme_vars:, night_color:)
}

/// Extract the hue angle from an "oklch(L C H)" string.
/// Public so the settings wheel can position dots by hue.
pub fn parse_hue(css: String) -> Result(Float, Nil) {
  parse_oklch_hue(css)
}

/// Return the CSS oklch color string for a calendar's travel tint.
/// Lower lightness and chroma than the bar — same hue family.
pub fn travel_color(bar_css: String) -> String {
  // bar_css is "oklch(L C H)" — extract H by parsing the string.
  // Simplest approach: the hue is the same, just substitute travel_l/travel_c.
  // We store the hue in the dict when generating, but we only have the CSS
  // string here, so we re-derive it. Since we know the format exactly we can
  // parse it back. Format: "oklch(0.65 0.19 <hue>)"
  case parse_oklch_hue(bar_css) {
    Ok(hue) -> oklch(travel_l, travel_c, hue)
    Error(_) -> bar_css
  }
}

// INTERNAL --------------------------------------------------------------------

/// Hue of the overall scheme: circular mean of all person hues.
/// If no people are configured, falls back to 250° (blue).
fn scheme_base_hue(
  person_hues: Dict(String, Float),
  all_people: List(String),
) -> Float {
  let hues = list.filter_map(all_people, fn(p) { dict.get(person_hues, p) })
  case hues {
    [] -> 250.0
    _ -> circular_mean(hues)
  }
}

/// Build the group key for a list of assigned people:
/// empty list → "", one person → that person's name,
/// multiple → sorted names joined by "|".
fn group_key(people: List(String)) -> String {
  people |> list.sort(string.compare) |> string.join("|")
}

/// Target hue for a group, given its key.
fn group_target_hue(
  key: String,
  person_hues: Dict(String, Float),
  all_people: List(String),
  base_hue: Float,
) -> Float {
  let names = case key {
    "" -> []
    k -> string.split(k, "|")
  }
  case names {
    // No people → complement of base
    [] -> normalize_hue(base_hue +. 180.0)
    // One person → their hue
    [p] ->
      dict.get(person_hues, p)
      |> result.unwrap(base_hue)
    // Multiple people → shorter-arc midpoint
    _ -> {
      let hues = list.filter_map(names, fn(p) { dict.get(person_hues, p) })
      case hues {
        [] -> base_hue
        [h] -> h
        _ ->
          // For exactly two people (the common case) use arc_midpoint.
          // For more people use the circular mean.
          case all_people, hues {
            _, [h1, h2] -> arc_midpoint(h1, h2)
            _, hs -> circular_mean(hs)
          }
      }
    }
  }
}

/// Midpoint of two hues along the shorter arc of the color wheel.
fn arc_midpoint(h1: Float, h2: Float) -> Float {
  let diff = normalize_hue(h2 -. h1)
  case diff <=. 180.0 {
    True -> normalize_hue(h1 +. diff /. 2.0)
    False -> normalize_hue(h1 -. { 360.0 -. diff } /. 2.0)
  }
}

/// Circular mean of a list of hue angles (degrees).
/// Converts to unit vectors, averages, converts back.
fn circular_mean(hues: List(Float)) -> Float {
  let n = int_to_float(list.length(hues))
  let #(sum_sin, sum_cos) =
    list.fold(hues, #(0.0, 0.0), fn(acc, h) {
      let r = to_rad(h)
      #(acc.0 +. math_sin(r), acc.1 +. math_cos(r))
    })
  let mean_rad = math_atan2(sum_sin /. n, sum_cos /. n)
  normalize_hue(to_deg(mean_rad))
}

/// Wrap a hue into [0, 360).
fn normalize_hue(h: Float) -> Float {
  let m = h -. 360.0 *. math_floor(h /. 360.0)
  case m <. 0.0 {
    True -> m +. 360.0
    False -> m
  }
}

/// Format a Float as an oklch color string.
fn oklch(l: Float, c: Float, h: Float) -> String {
  "oklch(" <> fmt_f(l) <> " " <> fmt_f(c) <> " " <> fmt_hue(h) <> ")"
}

/// Format a hue float to one decimal place.
fn fmt_hue(h: Float) -> String {
  let tenths = float_round(h *. 10.0)
  let whole = tenths / 10
  let frac = int.absolute_value(tenths % 10)
  int.to_string(whole) <> "." <> int.to_string(frac)
}

/// Format a small float (0–1) to three decimal places.
fn fmt_f(f: Float) -> String {
  let thousandths = float_round(f *. 1000.0)
  let whole = thousandths / 1000
  let frac = int.absolute_value(thousandths % 1000)
  int.to_string(whole) <> "." <> string.pad_start(int.to_string(frac), 3, "0")
}

/// Parse the hue out of an "oklch(L C H)" string.
fn parse_oklch_hue(s: String) -> Result(Float, Nil) {
  // Format: "oklch(0.650 0.190 <hue>)"
  // Split on "(" then ")" to get the inner, then split on " " to get fields.
  case string.split(s, "(") {
    [_, inner_and_close] ->
      case string.split(inner_and_close, ")") {
        [inner, ..] ->
          case string.split(inner, " ") {
            [_, _, hue_str, ..] -> parse_float(hue_str)
            _ -> Error(Nil)
          }
        _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

/// Parse a float from a string like "187.3".
fn parse_float(s: String) -> Result(Float, Nil) {
  case string.split(s, ".") {
    [whole, frac] -> {
      use w <- result.try(int.parse(whole))
      use f <- result.try(int.parse(frac))
      let scale = pow10(string.length(frac))
      Ok(int_to_float(w) +. int_to_float(f) /. int_to_float(scale))
    }
    [whole] -> {
      use w <- result.try(int.parse(whole))
      Ok(int_to_float(w))
    }
    _ -> Error(Nil)
  }
}

fn pow10(n: Int) -> Int {
  case n {
    0 -> 1
    _ -> 10 * pow10(n - 1)
  }
}

fn result_unwrap_empty(r: Result(List(a), b)) -> List(a) {
  result.unwrap(r, [])
}

fn int_to_float(n: Int) -> Float {
  int.to_float(n)
}

fn to_rad(deg: Float) -> Float {
  deg *. 0.017453292519943295
}

fn to_deg(rad: Float) -> Float {
  rad *. 57.29577951308232
}

@external(erlang, "math", "sin")
fn math_sin(x: Float) -> Float

@external(erlang, "math", "cos")
fn math_cos(x: Float) -> Float

@external(erlang, "math", "atan2")
fn math_atan2(y: Float, x: Float) -> Float

@external(erlang, "math", "floor")
fn math_floor(x: Float) -> Float

@external(erlang, "erlang", "round")
fn float_round(f: Float) -> Int
