extends Node3D
class_name GibsonCity

# The Gibson visualization: a city of translucent towers on a circuit-board ground,
# one tower per host. It reads /api/v1/hosts and /api/v1/links when the server has
# them, and otherwise the Matrix's feed (/api/v1/matrix), from which it derives hosts
# and one link per host. The layout rules are GibsonLayout's, the colours GibsonSchemes'.

const DEFAULT_POLL_SECONDS := 30.0
const FRESH_SECONDS := 6.0
const RISE_SECONDS := 1.2
const HEIGHT_EASE_SECONDS := 0.6
const BOARD_MARGIN := 96.0
const HOME := "LOCAL"
const MAX_CARS := 96
const CAR_SPEED := 40.0
const CAR_Y := 0.06
const FLASH_SECONDS := 0.3
const ARRIVAL_SECONDS := 0.4
const BUSIEST_LABELS := 12
const LOG_POLL_SECONDS := 5.0
const FLY_SECONDS := 1.2
const CLICK_SLOP := 6.0
const LABEL_RANGE := 60.0
const TOWER_SHADER := preload("res://shaders/gibson/gibson_tower.gdshader")
const GROUND_SHADER := preload("res://shaders/gibson/gibson_ground.gdshader")
const SKY_SHADER := preload("res://shaders/gibson/gibson_sky.gdshader")
const STREAK_SHADER := preload("res://shaders/gibson/gibson_streak.gdshader")
const FONT_PATH := "res://assets/fonts/Michroma-Regular.ttf"

var city_root: Node3D
var ground: MeshInstance3D
var towers_root: Node3D
var chips_root: Node3D
var camera: GibsonCamera
var api: StyxApi                     # the Matrix feed; only made in the fallback mode
var hosts_api: StyxApi
var links_api: StyxApi
var mode: String = "pending"         # "pending" (first answer not in), "new" (hosts and links), "matrix"
var link_rows: Array = []            # the last /v1/links answer
var menu: GibsonMenu
var log_api: StyxApi                 # made on the first selection
var selected: String = ""            # the host of the selected tower
var log_rows: Array = []             # the selected host's rows of /v1/flows
var log_lines: PackedStringArray = PackedStringArray()
var log_state: String = "reading"    # "reading", "ready", "unavailable"
var pick: int = 0                    # the picked menu item
var log_accumulator: float = 0.0
var _press_at := Vector2.ZERO
var _select_done: bool = false
var sky: MeshInstance3D
var streaks: MultiMeshInstance3D
var _ground_material: ShaderMaterial
var _sky_material: ShaderMaterial
var _streak_material: ShaderMaterial
var _rim_material: StandardMaterial3D
var _font: Font = load(FONT_PATH) if ResourceLoader.exists(FONT_PATH) else null
var cars: Array = []                 # {host, points, lengths, along, dir, color, flash}
var links: Dictionary = {}           # source > via > target -> {next, seq, row, source, host, route}

var scheme_id: String = "state"
var palette: Dictionary = {}

var placement: Dictionary = GibsonLayout.new_placement()
var hosts: Array = []
var sizes: Dictionary = {}
var towers: Dictionary = {}          # host -> {node, material, row, tone, height, target, side, born}
var _chip_material := _make_chip_material()
var chips: Dictionary = {}           # source -> MeshInstance3D
var known = null                     # Dictionary of hosts seen; null until the first answer
var extent: float = 24.0
var clock: float = 0.0
var poll_accumulator: float = 0.0

# What presentation changed outside this node, restored on exit.
var _saved := {}
var _xr_active: bool = false
var _xr_placed: bool = false
var _xr_scale: float = -1.0          # -1: the table-top model (follows the city's size); else its scale, up to 1 (life size)
var _xr_table_origin := Vector3.ZERO
var _xr_life_spot := Vector3.ZERO    # where the city's origin goes at life size: fixed when the growing starts, so walking and the teleport move the viewer through it
var _xr_life_set: bool = false
var _xr_stick: float = 0.0
var _xr_hover: String = ""           # the tower the right hand points at
var _xr_pointer: MeshInstance3D
var _xr_wired: bool = false          # the controllers' signals are connected (once)
var _xr_menu_spot := Vector2.ZERO    # where the menu stands in the room (x, z), set when a tower is selected
const XR_ORIGIN := "objects/XROrigin3D"
const MENU_WIDTH_XR := 0.6           # metres
const MENU_LOCAL_WIDTH := 5.75       # the menu's content, in its own units

func _ready() -> void:
    scheme_id = Globals.scheme
    palette = GibsonSchemes.palette(scheme_id)

    city_root = Node3D.new()
    city_root.name = "city_root"
    add_child(city_root)

    ground = MeshInstance3D.new()
    ground.name = "ground"
    ground.mesh = PlaneMesh.new()
    _ground_material = ShaderMaterial.new()
    _ground_material.shader = GROUND_SHADER
    ground.material_override = _ground_material
    city_root.add_child(ground)

    towers_root = Node3D.new()
    towers_root.name = "towers"
    city_root.add_child(towers_root)

    chips_root = Node3D.new()
    chips_root.name = "chips"
    city_root.add_child(chips_root)

    streaks = MultiMeshInstance3D.new()
    streaks.name = "streaks"
    var multimesh := MultiMesh.new()
    multimesh.transform_format = MultiMesh.TRANSFORM_3D
    multimesh.use_colors = true
    var car_mesh := PlaneMesh.new()
    car_mesh.size = Vector2(0.25, 3.0)
    multimesh.mesh = car_mesh
    multimesh.instance_count = MAX_CARS
    multimesh.visible_instance_count = 0
    streaks.multimesh = multimesh
    _streak_material = ShaderMaterial.new()
    _streak_material.shader = STREAK_SHADER
    streaks.material_override = _streak_material
    streaks.extra_cull_margin = 4096.0
    city_root.add_child(streaks)

    sky = MeshInstance3D.new()
    sky.name = "sky"
    var sphere := SphereMesh.new()
    sphere.radius = 400.0
    sphere.height = 800.0
    sphere.radial_segments = 32
    sphere.rings = 16
    sky.mesh = sphere
    _sky_material = ShaderMaterial.new()
    _sky_material.shader = SKY_SHADER
    _sky_material.set_shader_parameter("atlas", GibsonFont.atlas())
    sky.material_override = _sky_material
    sky.extra_cull_margin = 4096.0
    add_child(sky)

    menu = GibsonMenu.new()
    city_root.add_child(menu)

    camera = GibsonCamera.new()
    camera.name = "camera"
    add_child(camera)

    hosts_api = _make_api("/api/v1/hosts?relative=" + _window())
    hosts_api.data_received.connect(_on_hosts_answer)
    hosts_api.request_failed.connect(_on_hosts_failed)
    links_api = _make_api("/api/v1/links?relative=" + _window())
    links_api.data_received.connect(_on_links_answer)
    _poll()

    GibsonLayout.place(placement, [], [HOME])
    _sync_chips()
    _update_board()
    _apply_scheme()

    if Globals.shot != "":
        _take_shot()

func _exit_tree() -> void:
    _restore_presentation()
    # The controllers belong to the scene and outlive this view: take the beam and the connections off them.
    if is_instance_valid(_xr_pointer):
        _xr_pointer.queue_free()
    var left := _xr_hand("LeftHand") as XRController3D
    var right := _xr_hand("RightHand") as XRController3D
    if left:
        if left.button_pressed.is_connected(_xr_left_button):
            left.button_pressed.disconnect(_xr_left_button)
        if left.input_vector2_changed.is_connected(_xr_left_stick):
            left.input_vector2_changed.disconnect(_xr_left_stick)
    if right and right.button_pressed.is_connected(_xr_right_button):
        right.button_pressed.disconnect(_xr_right_button)

# ---- data -----------------------------------------------------------------

func _window() -> String:
    return Globals.api_relative if Globals.api_relative != "" else "60s"

func _make_api(path: String) -> StyxApi:
    var node := StyxApi.new()
    node.request_on_ready = false
    node.init(path)
    add_child(node)
    return node

func _poll() -> void:
    if mode == "matrix":
        api.send_request()
    else:
        hosts_api.send_request()
        if mode != "matrix":   # a request that failed at once has already switched the mode and freed both
            links_api.send_request()

# The first /v1/hosts answer decides the mode: a server without the new API is asked
# for the Matrix feed instead, and the new API is not asked again until the next time
# the visualization is shown.
func _on_hosts_failed(_endpoint: String) -> void:
    if mode != "pending":
        return
    mode = "matrix"
    print("gibson: /api/v1/hosts is not served, reading the Matrix feed")
    hosts_api.queue_free()
    links_api.queue_free()
    api = _make_api("/api/v1/matrix?relative=" + _window())
    api.data_received.connect(_on_matrix_answer)
    api.send_request()

func _on_hosts_answer(_endpoint: String, data: Array) -> void:
    if mode == "pending":
        mode = "new"
        print("gibson: reading /api/v1/hosts and /api/v1/links")
    hosts = data.slice(0, GibsonLayout.MAX_TOWERS)
    _rebuild()

func _on_links_answer(_endpoint: String, data: Array) -> void:
    link_rows = data
    if mode == "new":
        _rebuild()

func _on_matrix_answer(_endpoint: String, data: Array) -> void:
    hosts = GibsonLayout.hosts_from_matrix(data)
    link_rows = []
    _rebuild()

func _rebuild() -> void:
    var link_set: Array = GibsonLayout.links_from_hosts(hosts, HOME) if mode == "matrix" \
        else GibsonLayout.links_for(link_rows, hosts)
    var sources: Array = GibsonLayout.sources_of(link_set, HOME)
    GibsonLayout.place(placement, hosts, sources)
    sizes = GibsonLayout.tower_sizes(hosts)

    var first: bool = known == null
    if first:
        known = {}

    var present := {}
    var rank := -1
    for row in hosts:
        rank += 1
        var host: String = row["host"]
        present[host] = true
        var is_new := not towers.has(host)
        if is_new:
            _make_tower(host)
        var t: Dictionary = towers[host]
        t["row"] = row
        t["tone"] = GibsonLayout.tone_of(row)
        t["target"] = sizes[host]["height"]
        t["side"] = sizes[host]["side"]
        var pos := GibsonLayout.tower_position(placement, host)
        t["node"].position = Vector3(pos.x, t["node"].position.y, pos.y)
        _set_page(host)
        var label: Label3D = t["label"]
        label.visibility_range_end = 0.0 if rank < BUSIEST_LABELS else LABEL_RANGE
        if is_new:
            t["height"] = t["target"] if first else 0.0
        if not known.has(host):
            known[host] = true
            if not first:
                t["born"] = clock
    for host in towers.keys():
        if not present.has(host):
            towers[host]["node"].queue_free()
            towers[host]["label"].queue_free()
            towers.erase(host)
            known.erase(host)
            if host == selected:
                _select("")

    # One traffic link per link row; a link keeps its clock across answers.
    var live := {}
    for l in link_set:
        # One link per (source, via, target), as the server counts them: rows that differ only in
        # `via` are separate links, and keying on the pair alone would merge them into one.
        var id := "%s>%s>%s" % [l["source"], l.get("via", ""), l["target"]]
        live[id] = true
        var entry: Dictionary = links.get(id, {})
        if entry.is_empty():
            entry = {"next": GibsonLayout.hash01(id) * 3.0, "seq": 0}
            links[id] = entry
        entry["row"] = l
        entry["host"] = str(l["target"])
        entry["route"] = GibsonLayout.route_of(
            GibsonLayout.chip_position(placement, str(l["source"])),
            GibsonLayout.tower_position(placement, str(l["target"])))
    for id in links.keys():
        if not live.has(id):
            links.erase(id)

    if Globals.select_host != "" and not _select_done and towers.has(Globals.select_host):
        _select_done = true
        _select(Globals.select_host)

    extent = GibsonLayout.extent_of(placement)
    camera.extent = extent
    _update_board()
    _sync_chips()

# A tower's page: its lines, and its log when it is the selected one.
func _set_page(host: String) -> void:
    if not towers.has(host):
        return
    var t: Dictionary = towers[host]
    var page := GibsonLayout.page_of(t["row"], log_lines if host == selected else PackedStringArray())
    if page != t["page"]:
        t["page"] = page
        var material: ShaderMaterial = t["material"]
        material.set_shader_parameter("page", GibsonFont.page_texture(page))
        material.set_shader_parameter("page_rows", float(clampi(page.size(), 1, GibsonFont.MAX_PAGE_ROWS)))

func _make_tower(host: String) -> void:
    var node := MeshInstance3D.new()
    node.name = "tower_" + host.validate_node_name()
    node.mesh = BoxMesh.new()
    var material := ShaderMaterial.new()
    material.shader = TOWER_SHADER
    node.material_override = material
    material.set_shader_parameter("atlas", GibsonFont.atlas())
    towers_root.add_child(node)
    var label := _make_label(host)
    city_root.add_child(label)
    towers[host] = {
        "node": node, "material": material, "label": label, "row": {}, "tone": "normal",
        "height": 0.0, "target": 1.0, "side": 1.5, "born": -1000.0,
        "arrived": -1000.0, "page": PackedStringArray(), "style": "", "host": host,
    }

func _sync_chips() -> void:
    for source in placement["home"].keys():
        if not chips.has(source):
            var chip := MeshInstance3D.new()
            chip.name = "chip_" + str(source).validate_node_name()
            var box := BoxMesh.new()
            box.size = Vector3(2.0, 0.6, 2.0)
            chip.mesh = box
            chip.material_override = _chip_material
            chips_root.add_child(chip)
            _add_chip_rim(chip)
            var chip_label := _make_label(str(source))
            chip_label.modulate = palette["text"]["normal"]
            chip_label.position = Vector3(0, 1.2, 0)
            chip.add_child(chip_label)
            chips[source] = chip
        var p := GibsonLayout.chip_position(placement, source)
        chips[source].position = Vector3(p.x, 0.3, p.y)
    for source in chips.keys():
        if not placement["home"].has(source):
            chips[source].queue_free()
            chips.erase(source)

func _make_label(text: String) -> Label3D:
    var label := Label3D.new()
    label.name = "label"
    label.text = text.to_upper()
    if _font:
        label.font = _font
    label.font_size = 48
    label.pixel_size = 0.006
    label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
    label.shaded = false
    label.outline_size = 0
    return label

func _make_chip_material() -> Material:
    var material := StandardMaterial3D.new()
    material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    material.albedo_color = Color(0.015, 0.012, 0.02)
    return material

# A rim around the chip's top edge, and a row of pins along two edges.
func _add_chip_rim(chip: MeshInstance3D) -> void:
    if _rim_material == null:
        _rim_material = StandardMaterial3D.new()
        _rim_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    # The rim: four thin bars along the top edge (the top itself stays dark).
    for bar in [[Vector3(2.06, 0.06, 0.08), Vector3(0, 0.3, -1.0)], [Vector3(2.06, 0.06, 0.08), Vector3(0, 0.3, 1.0)],
            [Vector3(0.08, 0.06, 2.06), Vector3(-1.0, 0.3, 0)], [Vector3(0.08, 0.06, 2.06), Vector3(1.0, 0.3, 0)]]:
        var rim := MeshInstance3D.new()
        var rim_box := BoxMesh.new()
        rim_box.size = bar[0]
        rim.mesh = rim_box
        rim.material_override = _rim_material
        rim.position = bar[1]
        chip.add_child(rim)
    for side in [-1.0, 1.0]:
        for i in range(6):
            var pin := MeshInstance3D.new()
            var pin_box := BoxMesh.new()
            pin_box.size = Vector3(0.3, 0.12, 0.12)
            pin.mesh = pin_box
            pin.material_override = _rim_material
            pin.position = Vector3(side * 1.15, -0.1, -0.85 + 0.34 * i)
            chip.add_child(pin)

func _update_board() -> void:
    var margin := BOARD_MARGIN
    if _xr_active:
        margin = 2.0 if Globals.passthrough_enabled else 8.0
    var half := extent + margin
    (ground.mesh as PlaneMesh).size = Vector2(2.0 * half, 2.0 * half)

# ---- frame ----------------------------------------------------------------

func _process(delta: float) -> void:
    clock += delta

    var seconds := Globals.api_poll_seconds if Globals.api_poll_seconds > 0.0 else DEFAULT_POLL_SECONDS
    poll_accumulator += delta
    if poll_accumulator >= seconds:
        poll_accumulator = 0.0
        _poll()

    if selected != "":
        log_accumulator += delta
        if log_accumulator >= LOG_POLL_SECONDS:
            log_accumulator = 0.0
            _fetch_log()
        _place_menu()
    _animate_towers(delta)
    _run_traffic(delta)
    _present()
    _follow_camera()

# The sky is infinitely far (it follows the camera, never turns); the board fades
# with the camera's distance in the city's own space.
func _follow_camera() -> void:
    var viewer: Node3D = camera
    if _xr_active:
        var head := _xr_head()
        if head:
            viewer = head
    # In XR the sky is only for life size without passthrough.
    sky.visible = not _xr_active or (_xr_scale >= 0.999 and not Globals.passthrough_enabled)
    sky.global_position = viewer.global_position
    var local := city_root.to_local(viewer.global_position)
    _ground_material.set_shader_parameter("camera_local", local)

func _style_key(t: Dictionary, fresh: bool) -> String:
    return "%s|%s|%s|%s" % [scheme_id, t["tone"], fresh, t["host"] == selected]

func _animate_towers(delta: float) -> void:
    var ease_k := 1.0 - exp(-delta / (HEIGHT_EASE_SECONDS / 4.0))
    for host in towers:
        var t: Dictionary = towers[host]
        t["height"] = lerpf(t["height"], t["target"], ease_k)
        var shown: float = t["height"]
        var age: float = clock - t["born"]
        if age < RISE_SECONDS:
            var k := clampf(age / RISE_SECONDS, 0.0, 1.0)
            shown *= k * k * (3.0 - 2.0 * k)
        shown = maxf(shown, 0.02)
        var side: float = t["side"]
        var node: MeshInstance3D = t["node"]
        node.scale = Vector3(side, shown, side)
        node.position.y = shown / 2.0
        var label: Label3D = t["label"]
        label.position = Vector3(node.position.x, shown + 0.6, node.position.z)

        var material: ShaderMaterial = t["material"]
        material.set_shader_parameter("size", Vector3(side, shown, side))
        var fresh: bool = age < FRESH_SECONDS
        var key := _style_key(t, fresh)
        if key != t["style"]:
            t["style"] = key
            _style_tower(t, fresh)
        # Brightness: how lately it was reached (full when the feed has no ages), a slow
        # pulse while a connection is open, and a short boost when a car arrives.
        var row: Dictionary = t["row"]
        var level := GibsonLayout.brightness_of(row)
        if int(row.get("open", 0)) > 0:
            level *= 1.0 + 0.15 * sin(TAU * clock / 2.0)
        if host == _xr_hover:
            level *= 1.25
        var arrived: float = clock - t["arrived"]
        if arrived < ARRIVAL_SECONDS:
            level *= 1.0 + 0.25 * (1.0 - arrived / ARRIVAL_SECONDS)
        material.set_shader_parameter("brightness", level)

# What a tower looks like by its tone and whether it is fresh: set only when that changes.
func _style_tower(t: Dictionary, fresh: bool) -> void:
    var tone: String = t["tone"]
    var material: ShaderMaterial = t["material"]
    var marks: bool = palette["marks"]
    var glass: Color = palette["fresh"] if fresh else palette["glass"][tone]
    var text: Color = palette["fresh"] if fresh else palette["text"][tone]
    material.set_shader_parameter("glass", glass)
    material.set_shader_parameter("text_color", text)
    material.set_shader_parameter("stripes", marks and tone == "blocked")
    material.set_shader_parameter("dashes", marks and tone == "untunnelled")
    material.set_shader_parameter("windows", palette["windows"])
    material.set_shader_parameter("selected", t["host"] == selected)
    material.set_shader_parameter("highlight", palette["highlight"])
    var row: Dictionary = t["row"]
    var count := float(row.get("count", 0))
    var fraction := float(row.get("blocked", 0)) / count if count > 0.0 else 0.0
    var cap := 0.0
    if fraction > 0.0 and fraction < 1.0:
        cap = maxf(fraction, 0.5 / maxf(float(t["target"]), 1.0))
    material.set_shader_parameter("cap_fraction", cap)
    material.set_shader_parameter("cap_color", palette["fresh"] if marks else palette["glass"]["blocked"])
    material.set_shader_parameter("cap_stripes", marks)
    var label: Label3D = t["label"]
    label.modulate = text

# ---- traffic --------------------------------------------------------------------

func _car_color(t: Dictionary, refused: bool) -> Color:
    var traffic = palette["traffic"]
    if refused and not palette["marks"]:
        return palette["glass"]["blocked"]
    if traffic != null:
        return traffic
    return palette["glass"][t["tone"]].lerp(Color.WHITE, 0.6)

func _run_traffic(delta: float) -> void:
    # New cars, from each link's own numbers.
    for id in links:
        var link: Dictionary = links[id]
        var host: String = link["host"]
        if not towers.has(host):
            continue
        var row: Dictionary = link["row"]
        var interval := GibsonLayout.car_interval(row)
        link["next"] -= delta
        if interval < 0.0:
            link["next"] = maxf(link["next"], 0.0)   # quiet: no car, and none owed when it wakes
            continue
        if link["next"] > 0.0:
            continue
        var t: Dictionary = towers[host]
        link["next"] += interval
        link["seq"] += 1
        if cars.size() >= MAX_CARS:
            continue   # the cap: this link's car is skipped
        var count := int(row.get("count", 0))
        var refused := count > 0 and int(row.get("blocked", 0)) >= count
        var sent := float(row.get("sent", 0))
        var received := float(row.get("received", 0))
        var share := clampf(sent / (sent + received), 0.2, 0.8) if sent + received > 0.0 else 1.0
        var outbound := refused or GibsonLayout.hash01(id + ":" + str(link["seq"])) < share
        var points: PackedVector2Array = link["route"]
        if points.size() < 2:
            continue
        var lengths := PackedFloat32Array()
        var total := 0.0
        for i in range(points.size() - 1):
            total += points[i].distance_to(points[i + 1])
            lengths.append(total)
        cars.append({
            "host": host, "points": points, "lengths": lengths, "total": total, "along": 0.0,
            "outbound": outbound, "refused": refused, "flash": -1.0,
            "color": _car_color(t, refused),
        })

    # Move them; draw them.
    var multimesh := streaks.multimesh
    var i := 0
    while i < cars.size():
        var car: Dictionary = cars[i]
        if car["flash"] >= 0.0:
            car["flash"] += delta
            if car["flash"] >= FLASH_SECONDS:
                cars.remove_at(i)
                continue
        else:
            car["along"] += CAR_SPEED * delta
            if car["along"] >= car["total"]:
                car["along"] = car["total"]
                if towers.has(car["host"]) and car["outbound"]:
                    towers[car["host"]]["arrived"] = clock
                if car["refused"]:
                    car["flash"] = 0.0   # a refused car stops at the foot of the tower and flashes
                else:
                    cars.remove_at(i)
                    continue
        i += 1
    multimesh.visible_instance_count = cars.size()
    for n in range(cars.size()):
        var car: Dictionary = cars[n]
        var travelled: float = car["along"] if car["outbound"] else car["total"] - car["along"]
        var seg := _segment_on(car, travelled)
        var points: PackedVector2Array = car["points"]
        var lengths: PackedFloat32Array = car["lengths"]
        var seg_start: float = lengths[seg - 1] if seg > 0 else 0.0
        var seg_len := lengths[seg] - seg_start
        var k := 0.0 if seg_len <= 0.0 else clampf((travelled - seg_start) / seg_len, 0.0, 1.0)
        var at := points[seg].lerp(points[seg + 1], k)
        var d := points[seg + 1] - points[seg]
        var heading := d.normalized() if d.length() > 0.0 else Vector2(0, -1)
        if not car["outbound"]:
            heading = -heading
        var yaw := atan2(-heading.x, -heading.y)   # the plane's head end is -Z
        var basis := Basis(Vector3.UP, yaw)
        var origin := Vector3(at.x, CAR_Y, at.y)
        if car["flash"] >= 0.0:
            basis = basis * Basis.from_scale(Vector3(1.0 + 4.0 * (1.0 - car["flash"] / FLASH_SECONDS), 1.0, 0.4))
        else:
            # The head is at the car's point: the 3 unit plane sits behind it.
            origin -= Vector3(heading.x, 0.0, heading.y) * 1.5
        multimesh.set_instance_transform(n, Transform3D(basis, origin))
        multimesh.set_instance_color(n, car["color"])

# The index of the route segment `travelled` falls in.
func _segment_on(car: Dictionary, travelled: float) -> int:
    var lengths: PackedFloat32Array = car["lengths"]
    for i in range(lengths.size() - 1):
        if travelled <= lengths[i]:
            return i
    return lengths.size() - 1

# ---- schemes -------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
    if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT and not _xr_active:
        var mb := event as InputEventMouseButton
        if mb.pressed:
            _press_at = mb.position
        elif mb.position.distance_to(_press_at) < CLICK_SLOP:
            _click(mb.position)
        return
    if Globals.embed or not (event is InputEventKey):
        return
    var key := event as InputEventKey
    if not key.pressed or key.echo:
        return
    if key.keycode == KEY_C:
        scheme_id = GibsonSchemes.next_id(scheme_id)
        _apply_scheme()
    elif selected != "" and key.keycode == KEY_ESCAPE:
        _select("")
        get_viewport().set_input_as_handled()
    elif selected != "" and (key.keycode == KEY_UP or key.keycode == KEY_DOWN):
        pick = maxi(0, mini(pick + (1 if key.keycode == KEY_DOWN else -1), menu.groups.size() - 1))
        _update_menu()
        get_viewport().set_input_as_handled()

# A click that was not a drag.
func _click(at: Vector2) -> void:
    var viewport_camera := get_viewport().get_camera_3d()
    if viewport_camera == null:
        return
    _act_on_ray(viewport_camera.project_ray_origin(at), viewport_camera.project_ray_normal(at))

# What a click or a trigger on a world-space ray does: an item of the menu, else a tower, else deselect.
func _act_on_ray(origin: Vector3, direction: Vector3) -> void:
    if selected != "" and menu.visible:
        var to_menu := menu.global_transform.affine_inverse()
        var item := menu.item_at(to_menu * origin, (to_menu.basis * direction).normalized())
        if item >= 0:
            pick = item
            _update_menu()
            return
    var to_city := city_root.global_transform.affine_inverse()
    _select(_tower_hit(to_city * origin, (to_city.basis * direction).normalized()))

# The host of the tower a ray (in the city's space) enters first, or "".
func _tower_hit(origin: Vector3, direction: Vector3) -> String:
    var hosts_in_order := []
    var boxes := []
    for host in towers:
        var node: MeshInstance3D = towers[host]["node"]
        var half := node.scale.x / 2.0
        boxes.append({
            "min": Vector3(node.position.x - half, 0.0, node.position.z - half),
            "max": Vector3(node.position.x + half, node.scale.y, node.position.z + half),
        })
        hosts_in_order.append(host)
    var index := GibsonLayout.pick_box(origin, direction, boxes)
    return hosts_in_order[index] if index >= 0 else ""

# ---- selection, the log and the menu ----------------------------------------------

func _select(host: String) -> void:
    if host == selected:
        return
    var before := selected
    selected = host
    log_rows = []
    log_lines = PackedStringArray()
    log_state = "reading"
    pick = 0
    log_accumulator = 0.0
    _set_page(before)
    for name in [before, host]:
        if towers.has(name):
            towers[name]["style"] = ""
    camera.holding = host != ""
    if host == "":
        if log_api:
            log_api.cancel()
        menu.hide_menu()
        return
    _set_page(host)
    _fetch_log()
    _update_menu()
    if _xr_active:
        _xr_set_menu_spot()
    else:
        var t: Dictionary = towers[host]
        var from := city_root.to_local(camera.global_position)
        var node: MeshInstance3D = t["node"]
        var fly := GibsonLayout.fly_pose(Vector2(node.position.x, node.position.z), t["side"], t["target"], Vector2(from.x, from.z))
        camera.fly_to(city_root.to_global(fly["eye"]), city_root.to_global(fly["target"]), FLY_SECONDS)

func _fetch_log() -> void:
    if mode == "matrix":
        log_state = "unavailable"   # the Matrix feed has no log
        _update_menu()
        return
    if log_api == null:
        log_api = _make_api("/api/v1/flows")
        log_api.data_received.connect(_on_log_answer)
        log_api.request_failed.connect(_on_log_failed)
    log_api.set_endpoint("/api/v1/flows?host=%s&limit=100&relative=%s" % [selected.uri_encode(), _window()])
    log_api.send_request()

func _bias_seconds() -> int:
    return int(Time.get_time_zone_from_system()["bias"]) * 60

func _on_log_answer(_endpoint: String, data: Array) -> void:
    if selected == "":
        return
    log_rows = GibsonLayout.log_of(selected, data)
    log_lines = GibsonLayout.log_lines(log_rows, _bias_seconds())
    log_state = "ready"
    _set_page(selected)
    _update_menu()

func _on_log_failed(_endpoint: String) -> void:
    if selected != "" and log_state == "reading":
        log_state = "unavailable"
        _update_menu()

func _update_menu() -> void:
    if selected == "" or not towers.has(selected):
        menu.hide_menu()
        return
    menu.show_menu(selected, towers[selected]["row"], log_rows, log_state, pick, palette, _bias_seconds())
    pick = menu.picked

# The menu stands 0.3 in front of the selected tower's face nearest the viewer, faces the
# viewer's horizontal direction, and has its top at min(height, 9), or higher when the
# menu is taller than that.
func _place_menu() -> void:
    if not towers.has(selected) or not menu.visible:
        return
    if _xr_active:
        _place_menu_xr()
        return
    var t: Dictionary = towers[selected]
    var node: MeshInstance3D = t["node"]
    var viewer := city_root.to_local(camera.global_position)
    var at := Vector2(node.position.x, node.position.z)
    var n := GibsonLayout.face_normal(Vector2(viewer.x, viewer.z), at)
    var centre := at + n * (float(t["side"]) / 2.0 + 0.3)
    var top := maxf(minf(float(t["height"]), 9.0), menu.height())
    var flat := Vector2(viewer.x - centre.x, viewer.z - centre.y)
    var yaw := atan2(flat.x, flat.y) if flat.length() > 0.001 else 0.0
    menu.scale = Vector3.ONE * GibsonMenu.SCALE
    menu.rotation = Vector3(0.0, yaw, 0.0)
    menu.position = Vector3(centre.x, top, centre.y) + menu.basis.x * 0.2

# In XR the menu is not scaled with the city: 0.6 m wide, 0.9 m in front of where the
# viewer was when the tower was selected, its middle at 1.2 m, facing the viewer.
func _place_menu_xr() -> void:
    var head := _xr_head()
    if head == null:
        return
    var k := MENU_WIDTH_XR / MENU_LOCAL_WIDTH
    var flat := Vector2(head.global_position.x - _xr_menu_spot.x, head.global_position.z - _xr_menu_spot.y)
    var yaw := atan2(flat.x, flat.y) if flat.length() > 0.001 else 0.0
    var basis := Basis(Vector3.UP, yaw) * Basis.from_scale(Vector3.ONE * k)
    var half_height := menu.height() / GibsonMenu.SCALE * k / 2.0
    var origin := Vector3(_xr_menu_spot.x, 1.2 + half_height, _xr_menu_spot.y) + basis.x * 0.2
    menu.global_transform = Transform3D(basis, origin)

# The menu stands 0.9 m ahead of the viewer, where they were looking when it opened.
func _xr_set_menu_spot() -> void:
    var head := _xr_head()
    if head == null:
        return
    var forward := _xr_forward(head)
    _xr_menu_spot = Vector2(head.global_position.x + forward.x * 0.9, head.global_position.z + forward.z * 0.9)

func _xr_head() -> Node3D:
    return _xr_hand("XRCamera3D")

# A node of the scene's XR rig (the camera or a controller), or null.
func _xr_hand(node_name: String) -> Node3D:
    var scene := _scene()
    return scene.get_node_or_null(XR_ORIGIN + "/" + node_name) as Node3D if scene else null

# Where the viewer looks, flat on the floor.
func _xr_forward(head: Node3D) -> Vector3:
    var forward := -head.global_transform.basis.z
    forward.y = 0.0
    return forward.normalized() if forward.length() > 0.001 else Vector3.FORWARD

func _apply_scheme() -> void:
    palette = GibsonSchemes.palette(scheme_id)
    _ground_material.set_shader_parameter("board", palette["board"])
    _ground_material.set_shader_parameter("trace_a", palette["trace_a"])
    _ground_material.set_shader_parameter("trace_b", palette["trace_b"])
    for name in ["sky_base", "sky_strand", "sky_arc", "sky_formula", "sky_wash"]:
        _sky_material.set_shader_parameter(name, palette[name])
    _sky_material.set_shader_parameter("board", palette["board"])
    _sky_material.set_shader_parameter("strength", palette["sky_strength"])
    _rim_material.albedo_color = palette["home_rim"]
    for chip in chips.values():
        (chip.get_node("label") as Label3D).modulate = palette["text"]["normal"]
    for t in towers.values():
        t["style"] = ""
    _update_menu()
    for car in cars:
        car["color"] = _car_color(towers[car["host"]], car["refused"]) if towers.has(car["host"]) else car["color"]

# ---- presentation: a flat screen, or a model on a table in XR ------------------

func _scene() -> Node:
    return get_tree().current_scene

func _remember(node: Object, property: String) -> void:
    if node == null:
        return
    var key := str(node.get_instance_id()) + ":" + property
    if not _saved.has(key):
        _saved[key] = [node, property, node.get(property)]

func _present() -> void:
    var xr := get_viewport().use_xr
    if xr != _xr_active:
        _xr_active = xr
        _xr_placed = false
        if xr and selected != "":
            _xr_set_menu_spot()
        if not xr:
            camera.make_current()
            _xr_hover = ""
            if _xr_pointer:
                _xr_pointer.visible = false
        _update_board()
    if xr:
        _present_xr()
    else:
        _present_flat()

func _present_flat() -> void:
    city_root.transform = Transform3D.IDENTITY
    if not camera.current:
        camera.make_current()
    var scene := _scene()
    if scene == null:
        return
    var player := scene.get_node_or_null("objects/joystick_touch_pad")
    if player and not _saved.has("player"):
        _saved["player"] = [player, "physics", player.is_physics_processing()]
        player.set_physics_process(false)
    var floor_node := scene.get_node_or_null("stage/Floor")
    if floor_node:
        _remember(floor_node, "visible")
        floor_node.visible = false
    var world_env := scene.get_node_or_null("env/WorldEnvironment") as WorldEnvironment
    if world_env and world_env.environment:
        _remember(world_env.environment, "background_mode")
        _remember(world_env.environment, "background_color")
        world_env.environment.background_mode = Environment.BG_COLOR
        world_env.environment.background_color = Color.BLACK

# The model in XR: a table-top city 1.6 m across 1.2 m in front of the viewer (board at
# 0.9 m), which the left thumbstick grows towards life size: there the home block is under
# the viewer and the board 2 cm above the floor. The origin moves with the scale, so the
# city grows around where it stands.
func _present_xr() -> void:
    var scene := _scene()
    if camera.current:
        camera.current = false
    var floor_node: Node = scene.get_node_or_null("stage/Floor") if scene else null
    if floor_node:
        floor_node.visible = true
    var head := _xr_head()
    if head == null:
        return
    _xr_wire()
    if not _xr_placed:
        _xr_table_origin = Vector3(head.global_position.x, 0.9, head.global_position.z) + _xr_forward(head) * 1.2
        _xr_placed = true
    var table := GibsonLayout.table_scale(extent)
    var current := table if _xr_scale < 0.0 else clampf(_xr_scale, table, 1.0)
    var next := GibsonLayout.scale_step(current, _xr_stick, get_process_delta_time(), table)
    if next != current:
        current = next
        _xr_scale = -1.0 if current <= table + 1.0e-4 else current
    if current <= table + 1.0e-4:
        _xr_life_set = false
    elif not _xr_life_set:
        _xr_life_set = true
        _xr_life_spot = GibsonLayout.life_origin(head.global_position)
    var origin := _xr_table_origin.lerp(_xr_life_spot, GibsonLayout.zoom_k(current, table))
    city_root.global_transform = Transform3D(Basis.from_scale(Vector3.ONE * current), origin)
    _xr_point()

# The controllers' signals, connected once: right trigger selects, left thumbstick scales,
# left A/X the next scheme, left B/Y jumps between table-top and life size. Nothing here
# touches the teleport (left trigger) or the turn (right thumbstick).
func _xr_wire() -> void:
    if _xr_wired:
        return
    _xr_wired = true
    var left := _xr_hand("LeftHand") as XRController3D
    var right := _xr_hand("RightHand") as XRController3D
    if left:
        left.button_pressed.connect(_xr_left_button)
        left.input_vector2_changed.connect(_xr_left_stick)
    if right:
        right.button_pressed.connect(_xr_right_button)
        _xr_pointer = MeshInstance3D.new()
        _xr_pointer.name = "gibson_pointer"
        var beam := BoxMesh.new()
        beam.size = Vector3(0.002, 0.002, 3.0)
        _xr_pointer.mesh = beam
        var material := StandardMaterial3D.new()
        material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
        material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
        material.albedo_color = Color(0.5, 0.5, 0.5)
        _xr_pointer.material_override = material
        _xr_pointer.position = Vector3(0.0, 0.0, -1.5)
        right.add_child(_xr_pointer)

func _xr_left_stick(action: String, value: Vector2) -> void:
    if action == "primary":
        _xr_stick = value.y

func _xr_left_button(action: String) -> void:
    if action == "ax_button":
        scheme_id = GibsonSchemes.next_id(scheme_id)
        _apply_scheme()
    elif action == "by_button":
        _xr_scale = 1.0 if _xr_scale < 0.0 else -1.0
        _xr_placed = false

func _xr_right_button(action: String) -> void:
    if action != "trigger_click" or not _xr_active:
        return
    var right := _xr_hand("RightHand")
    if right:
        _act_on_ray(right.global_position, -right.global_transform.basis.z)

# The pointer is shown only in XR; the tower it points at is the hovered one.
func _xr_point() -> void:
    var right := _xr_hand("RightHand")
    if _xr_pointer:
        _xr_pointer.visible = true
    if right == null:
        _xr_hover = ""
        return
    var to_city := city_root.global_transform.affine_inverse()
    _xr_hover = _tower_hit(to_city * right.global_position, (to_city.basis * -right.global_transform.basis.z).normalized())

func _restore_presentation() -> void:
    for key in _saved:
        var entry: Array = _saved[key]
        if not is_instance_valid(entry[0]):
            continue
        if key == "player":
            entry[0].set_physics_process(entry[2])
        else:
            entry[0].set(entry[1], entry[2])
    _saved.clear()

# ---- the check picture ----------------------------------------------------------

func _take_shot() -> void:
    await get_tree().create_timer(Globals.shot_after).timeout
    await RenderingServer.frame_post_draw
    var image := get_viewport().get_texture().get_image()
    if image == null:
        print("gibson: no image to save (headless?)")
    else:
        image.save_png(Globals.shot)
        print("gibson: saved ", Globals.shot)
    get_tree().quit()
