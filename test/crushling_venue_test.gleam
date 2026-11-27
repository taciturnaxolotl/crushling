import crushling/venue
import gleam/json

pub fn unknown_venue_is_refused_test() {
  let assert Ok(venue.Thread) =
    json.parse("{\"kind\":\"thread\"}", venue.decoder())
  let assert Error(_) = json.parse("{\"kind\":\"forum\"}", venue.decoder())
}
