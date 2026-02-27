import lustre/attribute.{type Attribute, attribute}
import lustre/element/svg

pub fn sunrise(attributes: List(Attribute(a))) {
  svg.svg(
    [
      attribute("stroke-linejoin", "round"),
      attribute("stroke-linecap", "round"),
      attribute("stroke-width", "2"),
      attribute("stroke", "currentColor"),
      attribute("fill", "none"),
      attribute("viewBox", "0 0 24 24"),
      attribute("height", "24"),
      attribute("width", "24"),
      ..attributes
    ],
    [
      svg.path([attribute("d", "M12 2v8")]),
      svg.path([attribute("d", "m4.93 10.93 1.41 1.41")]),
      svg.path([attribute("d", "M2 18h2")]),
      svg.path([attribute("d", "M20 18h2")]),
      svg.path([attribute("d", "m19.07 10.93-1.41 1.41")]),
      svg.path([attribute("d", "M22 22H2")]),
      svg.path([attribute("d", "m8 6 4-4 4 4")]),
      svg.path([attribute("d", "M16 18a4 4 0 0 0-8 0")]),
    ],
  )
}

pub fn sunset(attributes: List(Attribute(a))) {
  svg.svg(
    [
      attribute("stroke-linejoin", "round"),
      attribute("stroke-linecap", "round"),
      attribute("stroke-width", "2"),
      attribute("stroke", "currentColor"),
      attribute("fill", "none"),
      attribute("viewBox", "0 0 24 24"),
      attribute("height", "24"),
      attribute("width", "24"),
      ..attributes
    ],
    [
      svg.path([attribute("d", "M12 10V2")]),
      svg.path([attribute("d", "m4.93 10.93 1.41 1.41")]),
      svg.path([attribute("d", "M2 18h2")]),
      svg.path([attribute("d", "M20 18h2")]),
      svg.path([attribute("d", "m19.07 10.93-1.41 1.41")]),
      svg.path([attribute("d", "M22 22H2")]),
      svg.path([attribute("d", "m16 6-4 4-4-4")]),
      svg.path([attribute("d", "M16 18a4 4 0 0 0-8 0")]),
    ],
  )
}
