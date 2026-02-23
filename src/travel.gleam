// Google Maps travel-time lookup for home-terminal.
//
// Given a home address (origin) and an event location (destination), queries
// the Google Maps Distance Matrix API with traffic conditions and returns the
// display city name, human-readable distance, and travel-time estimate.
//
// Requires the GOOGLE_MAPS_API_KEY environment variable.
//
// API reference:
//   https://developers.google.com/maps/documentation/distance-matrix/overview

// IMPORTS ---------------------------------------------------------------------

import gleam/dynamic/decode
import gleam/hackney
import gleam/http/request
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import gleam/uri

// TYPES -----------------------------------------------------------------------

/// Travel info resolved for a single (home → destination) pair.
pub type TravelResult {
  TravelResult(
    /// Short city name extracted from the resolved destination address,
    /// e.g. "Boston, MA".
    city: String,
    /// Human-readable distance, e.g. "2.3 mi".
    distance_text: String,
    /// Estimated travel time with traffic, e.g. "12 mins".
    duration_text: String,
  )
}

// PUBLIC API ------------------------------------------------------------------

/// Query the Distance Matrix API and return travel info.
/// Returns Error(reason) if the API key is absent, the HTTP request fails,
/// the response status is not "OK", or the response cannot be parsed.
pub fn get_travel_info(
  home: String,
  destination: String,
  api_key: String,
) -> Result(TravelResult, String) {
  use body <- result.try(send_request(home, destination, api_key))
  parse_response(body)
}

// INTERNAL --------------------------------------------------------------------

fn send_request(
  home: String,
  destination: String,
  api_key: String,
) -> Result(String, String) {
  let params =
    [
      #("origins", home),
      #("destinations", destination),
      #("departure_time", "now"),
      #("units", "imperial"),
      #("key", api_key),
    ]
    |> list.map(fn(p) {
      uri.percent_encode(p.0) <> "=" <> uri.percent_encode(p.1)
    })
    |> string.join("&")

  let url =
    "https://maps.googleapis.com/maps/api/distancematrix/json?" <> params

  use req <- result.try(
    request.to(url)
    |> result.map_error(fn(_) { "failed to build request for: " <> url }),
  )

  use resp <- result.try(
    hackney.send(req)
    |> result.map_error(fn(err) {
      "HTTP request failed: " <> string.inspect(err)
    }),
  )

  Ok(resp.body)
}

fn parse_response(body: String) -> Result(TravelResult, String) {
  // First check the top-level status field.
  use top_status <- result.try(
    json.parse(body, decode.at(["status"], decode.string))
    |> result.map_error(fn(e) { "parse error: " <> string.inspect(e) }),
  )
  case top_status {
    "OK" -> {
      // Decode destination address, element status, distance, duration.
      // Arrays are decoded with decode.list then we take the first element.
      let first_string_in_list =
        decode.list(decode.string)
        |> decode.then(fn(items) {
          case items {
            [first, ..] -> decode.success(first)
            [] -> decode.failure("", "non-empty list")
          }
        })

      // Decoder for one element object: { status, distance.text, duration_in_traffic.text }
      let element_decoder = {
        use elem_status <- decode.field("status", decode.string)
        use dist <- decode.subfield(["distance", "text"], decode.string)
        use dur <- decode.subfield(
          ["duration_in_traffic", "text"],
          decode.string,
        )
        decode.success(#(elem_status, dist, dur))
      }

      // rows is List(row), row has elements: List(element)
      let row_decoder =
        decode.at(["elements"], decode.list(element_decoder))
        |> decode.then(fn(elems) {
          case elems {
            [first, ..] -> decode.success(first)
            [] -> decode.failure(#("", "", ""), "non-empty elements")
          }
        })

      let decoder = {
        use dest_addr <- decode.field(
          "destination_addresses",
          first_string_in_list,
        )
        use #(elem_status, dist, dur) <- decode.field(
          "rows",
          decode.list(row_decoder)
            |> decode.then(fn(rows) {
              case rows {
                [first, ..] -> decode.success(first)
                [] -> decode.failure(#("", "", ""), "non-empty rows")
              }
            }),
        )
        decode.success(#(dest_addr, elem_status, dist, dur))
      }
      case json.parse(body, decoder) {
        Error(e) -> Error("parse error: " <> string.inspect(e))
        Ok(#(dest_addr, elem_status, dist, dur)) ->
          case elem_status {
            "OK" ->
              Ok(TravelResult(
                city: city_from_address(dest_addr),
                distance_text: dist,
                duration_text: dur,
              ))
            other -> Error("element status: " <> other)
          }
      }
    }
    other -> Error("API status: " <> other)
  }
}

/// Extract a short city label from a full Google Maps address string.
/// "123 Main St, Boston, MA 02101, USA" → "Boston, MA"
/// Falls back to the full string if parsing fails.
fn city_from_address(addr: String) -> String {
  // Google's resolved address format: "street, city, state zip, country"
  // Split by ", " and take city + state abbreviation.
  let parts = string.split(addr, ", ")
  case parts {
    [_, city, state_zip, ..] -> {
      // state_zip may be "MA 02101" — keep just the state abbreviation.
      let state = case string.split(state_zip, " ") {
        [st, ..] -> st
        [] -> state_zip
      }
      city <> ", " <> state
    }
    [_, city, ..] -> city
    _ -> addr
  }
}
