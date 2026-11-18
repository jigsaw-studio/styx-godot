extends Node3D
class_name GibsonMenu

# The menu of a selected tower, drawn in the scene: a header, right-aligned items
# (the log grouped by port and via), and beside the picked item up to four boxes, the
# newest rows of its group. In local units one unit is about a lowercase letter's width
# times 6; the owner scales and places the node. Local +Z is the side that is read from.
# The pure rules (what the items and boxes say) are GibsonLayout's.

const FONT_PATH := "res://assets/fonts/Michroma-Regular.ttf"
const FONT_SIZE := 48
const PIXEL_SIZE := 0.0042
const LINE := 0.34                   # items' pitch
const BOX_W := 2.3
const BOX_H := 0.62
const BOX_PITCH := 0.98
const BOX_X := 0.35                  # boxes start this far right of the items' right edge
const BAR := 0.03
const PRIORITY := 10
const LEFT := -3.1                   # the header's and the items' left edge
const SCALE := 1.3                   # the node's scale: about 7.5 city units wide, which reads from 9 units away

var host: String = ""
var title_row: Dictionary = {}
var groups: Array = []               # GibsonLayout.menu_of
var picked: int = 0
var state: String = "reading"        # "reading", "ready", "unavailable"
var bias_seconds: int = 0
var palette: Dictionary = {}

var _font: Font = load(FONT_PATH) if ResourceLoader.exists(FONT_PATH) else null
var _item_rects: Array = []          # Rect2 per item, in local x, y
var _signature: String = ""

func _init() -> void:
    name = "menu"
    scale = Vector3.ONE * SCALE
    visible = false

func _bar_material(colour: Color) -> StandardMaterial3D:
    var m := StandardMaterial3D.new()
    m.albedo_color = colour
    m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    m.no_depth_test = true
    m.render_priority = PRIORITY
    return m

# Show or update the menu. Rebuilds the labels only when what they say changed.
func show_menu(selected_host: String, row: Dictionary, log: Array, log_state: String, pick: int, colours: Dictionary, bias: int) -> void:
    var next_groups: Array = GibsonLayout.menu_of(log) if log_state == "ready" else []
    var next_picked := clampi(pick, 0, maxi(next_groups.size() - 1, 0))
    var signature := str([selected_host, log_state, next_picked, log.hash(), GibsonLayout.totals_of(row), bias, colours["highlight"], colours["text"]["normal"]])
    host = selected_host
    title_row = row
    groups = next_groups
    picked = next_picked
    state = log_state
    palette = colours
    bias_seconds = bias
    visible = true
    if signature == _signature:
        return
    _signature = signature
    _rebuild()

func hide_menu() -> void:
    visible = false
    _signature = ""
    host = ""

func _label(text: String, colour: Color, alignment: HorizontalAlignment, scale: float = 1.0) -> Label3D:
    var label := Label3D.new()
    label.text = text
    if _font:
        label.font = _font
    label.font_size = FONT_SIZE
    label.pixel_size = PIXEL_SIZE * scale
    label.shaded = false
    label.no_depth_test = true
    label.render_priority = PRIORITY
    label.double_sided = true
    label.outline_size = 0
    label.modulate = colour
    label.horizontal_alignment = alignment
    return label

func _outline(rect: Rect2, material: StandardMaterial3D) -> Node3D:
    var holder := Node3D.new()
    for bar in [
            [Vector2(rect.size.x, BAR), rect.position + Vector2(rect.size.x / 2.0, BAR / 2.0)],
            [Vector2(rect.size.x, BAR), rect.position + Vector2(rect.size.x / 2.0, rect.size.y - BAR / 2.0)],
            [Vector2(BAR, rect.size.y), rect.position + Vector2(BAR / 2.0, rect.size.y / 2.0)],
            [Vector2(BAR, rect.size.y), rect.position + Vector2(rect.size.x - BAR / 2.0, rect.size.y / 2.0)]]:
        var mesh := MeshInstance3D.new()
        var box := BoxMesh.new()
        box.size = Vector3(bar[0].x, bar[0].y, BAR)
        mesh.mesh = box
        mesh.material_override = material
        mesh.position = Vector3(bar[1].x, bar[1].y, 0.0)
        holder.add_child(mesh)
    return holder

# Everything is laid out in local x (right) and y (down is negative), the items' right edge at x = 0
# and the first line at y = 0.
func _rebuild() -> void:
    for child in get_children():
        child.queue_free()
    _item_rects.clear()
    var text_colour: Color = palette["text"]["normal"]
    var highlight: Color = palette["highlight"]
    var refused: Color = palette["glass"]["blocked"]
    var highlight_material := _bar_material(highlight)
    var blocked_material := _bar_material(refused)

    var header := _label(host.to_upper(), highlight, HORIZONTAL_ALIGNMENT_LEFT, 1.15)
    header.position = Vector3(LEFT, 0.0, 0.0)
    add_child(header)
    var totals := _label(GibsonLayout.totals_of(title_row), text_colour, HORIZONTAL_ALIGNMENT_LEFT, 0.75)
    totals.position = Vector3(LEFT, -0.4, 0.0)
    add_child(totals)

    var top := -0.95
    if state != "ready" or groups.is_empty():
        var message := "READING..."
        if state == "unavailable":
            message = "NO LOG FROM THIS SERVER"
        elif state == "ready":
            message = "NOTHING RECORDED"
        var line := _label(message, text_colour, HORIZONTAL_ALIGNMENT_LEFT)
        line.position = Vector3(LEFT, top, 0.0)
        add_child(line)
        return

    for i in range(groups.size()):
        var y := top - LINE * i
        var item := _label(String(groups[i]["label"]) + " >", highlight if i == picked else text_colour, HORIZONTAL_ALIGNMENT_RIGHT)
        item.position = Vector3(0.0, y, 0.0)
        add_child(item)
        _item_rects.append(Rect2(LEFT, y - LINE * 0.5, -LEFT, LINE))

    # The picked item's boxes, stacked downward from its line.
    var rows: Array = groups[picked]["rows"]
    var y0 := top - LINE * picked
    for b in range(mini(rows.size(), GibsonLayout.MAX_MENU_BOXES)):
        var box: Dictionary = GibsonLayout.box_of(rows[b], bias_seconds)
        var material: StandardMaterial3D = blocked_material if box["blocked"] else highlight_material
        var colour: Color = refused if box["blocked"] else highlight
        var x := BOX_X
        var yy := y0 + 0.17 - BOX_PITCH * b
        var rect := Rect2(Vector2(x, yy - BOX_H), Vector2(BOX_W, BOX_H))
        add_child(_outline(rect, material))
        var title := _label(box["title"], colour, HORIZONTAL_ALIGNMENT_LEFT, 0.8)
        title.position = Vector3(x + 0.12, yy - BOX_H / 2.0, 0.0)
        add_child(title)
        var caption := _label(box["caption"], colour, HORIZONTAL_ALIGNMENT_LEFT, 0.65)
        caption.position = Vector3(x + 0.12, yy - BOX_H - 0.14, 0.0)
        add_child(caption)

# The item a ray (in the menu's own space) points at, or -1.
func item_at(origin: Vector3, direction: Vector3) -> int:
    if not visible:
        return -1
    return GibsonLayout.pick_rect(origin, direction, _item_rects)

# The menu's height in city units: the taller of the items and the picked item's boxes.
func height() -> float:
    var boxes := mini(groups[picked]["rows"].size(), GibsonLayout.MAX_MENU_BOXES) if not groups.is_empty() else 0
    return SCALE * (1.3 + maxf(LINE * maxi(groups.size(), 1), LINE * picked + BOX_PITCH * boxes))
