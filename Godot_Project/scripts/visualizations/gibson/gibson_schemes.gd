class_name GibsonSchemes
extends RefCounted

# The colour schemes of the Gibson city. A palette is a Dictionary of Colors and flags:
#   board, glass {tone: Color}, text {tone: Color}, fresh, highlight, trace_a, trace_b,
#   traffic (null in State: the target's glass), home_rim, sky_base, sky_strand, sky_arc,
#   sky_formula, sky_wash, sky_strength, marks (state is shown by a mark, not by hue),
#   windows (Night: far text becomes lit windows).
# In State hue is the state; in the four film schemes every tower has one glass colour.

const IDS := ["state", "green", "cyan", "red", "night"]
const TONES := ["normal", "blocked", "untunnelled", "local"]

static func _c(hex: String) -> Color:
    return Color.html(hex)

static func _all(color: Color) -> Dictionary:
    return {"normal": color, "blocked": color, "untunnelled": color, "local": color}

static func _sky(strength: float) -> Dictionary:
    return {
        "sky_base": _c("#04021a"), "sky_strand": _c("#5a4de0"), "sky_arc": _c("#ffb428"),
        "sky_formula": _c("#ff6a8a"), "sky_wash": _c("#b8a8ff"), "sky_strength": strength,
    }

static func _film(board: String, glass: String, text: String, fresh: String, highlight: String,
        trace_a: String, trace_b: String, traffic: String, rim: String, strength: float, windows: bool) -> Dictionary:
    var p := {
        "board": _c(board), "glass": _all(_c(glass)), "text": _all(_c(text)),
        "fresh": _c(fresh), "highlight": _c(highlight),
        "trace_a": _c(trace_a), "trace_b": _c(trace_b), "traffic": _c(traffic),
        "home_rim": _c(rim), "marks": true, "windows": windows,
    }
    p.merge(_sky(strength))
    return p

static func palette(id: String) -> Dictionary:
    match id:
        "green":
            return _film("#010a08", "#1ec98a", "#8dffc9", "#e8fff4", "#5a4dff", "#6f5cff", "#ffb47a", "#c8fff0", "#ff3fd0", 1.0, false)
        "cyan":
            return _film("#01070c", "#2aa8c4", "#a8f0ff", "#e0fbff", "#8a5cff", "#2b3cff", "#7a5cff", "#e0fbff", "#ff3fd0", 1.0, false)
        "red":
            return _film("#0a0104", "#c8242e", "#ff6a5c", "#ffe0d8", "#2f6bff", "#1f6bff", "#3aa0ff", "#19f0e6", "#ff3fd0", 1.0, false)
        "night":
            return _film("#05040a", "#2a2530", "#ffd9a0", "#fff0c8", "#39d0d8", "#ffb060", "#fff0c8", "#ffe9b8", "#ffb060", 0.4, true)
    var glass := {
        "normal": _c("#19c37d"), "blocked": _c("#ff3b4a"),
        "untunnelled": _c("#ffb020"), "local": _c("#29c5e6"),
    }
    var text := {}
    for tone in TONES:
        text[tone] = glass[tone].lerp(Color.WHITE, 0.45)
    var state := {
        "board": _c("#020807"), "glass": glass, "text": text,
        "fresh": _c("#e8fff4"), "highlight": _c("#7a5cff"),
        "trace_a": _c("#6a58ff"), "trace_b": _c("#ffb978"), "traffic": null,
        "home_rim": _c("#ff3fd0"), "marks": false, "windows": false,
    }
    state.merge(_sky(1.0))
    return state

static func next_id(id: String) -> String:
    var i := IDS.find(id)
    return IDS[(i + 1) % IDS.size()]
