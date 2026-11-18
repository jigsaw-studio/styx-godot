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
var host_rows: Array = []            # the last /v1/hosts answer, cut
var link_rows: Array = []            # the last /v1/links answer
var sky: MeshInstance3D
var streaks: MultiMeshInstance3D
var _ground_material: ShaderMaterial
var _sky_material: ShaderMaterial
var _streak_material: ShaderMaterial
var _rim_material: StandardMaterial3D
var _font: Font = load(FONT_PATH) if ResourceLoader.exists(FONT_PATH) else null
var cars: Array = []                 # {host, points, lengths, along, dir, color, flash}
var links: Dictionary = {}           # source + ">" + target -> {next, seq, row, source, host, route}

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
    host_rows = data.slice(0, GibsonLayout.MAX_TOWERS)
    _rebuild()

func _on_links_answer(_endpoint: String, data: Array) -> void:
    link_rows = data
    if mode == "new":
        _rebuild()

func _on_matrix_answer(_endpoint: String, data: Array) -> void:
    host_rows = GibsonLayout.hosts_from_matrix(data)
    link_rows = []
    _rebuild()

func _rebuild() -> void:
    hosts = host_rows
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
        var page := GibsonLayout.page_of(row)
        if page != t["page"]:
            t["page"] = page
            var material: ShaderMaterial = t["material"]
            material.set_shader_parameter("page", GibsonFont.page_texture(page))
            material.set_shader_parameter("page_rows", float(clampi(page.size(), 1, GibsonFont.MAX_PAGE_ROWS)))
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

    # One traffic link per link row; a link keeps its clock across answers.
    var live := {}
    for l in link_set:
        var id := "%s>%s" % [l["source"], l["target"]]
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

    extent = GibsonLayout.extent_of(placement)
    camera.extent = extent
    _update_board()
    _sync_chips()

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
        "arrived": -1000.0, "page": PackedStringArray(), "style": "",
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
    var half := extent + (8.0 if _xr_active else BOARD_MARGIN)
    (ground.mesh as PlaneMesh).size = Vector2(2.0 * half, 2.0 * half)

# ---- frame ----------------------------------------------------------------

func _process(delta: float) -> void:
    clock += delta

    var seconds := Globals.api_poll_seconds if Globals.api_poll_seconds > 0.0 else DEFAULT_POLL_SECONDS
    poll_accumulator += delta
    if poll_accumulator >= seconds:
        poll_accumulator = 0.0
        _poll()

    _animate_towers(delta)
    _run_traffic(delta)
    _present()
    _follow_camera()

# The sky is infinitely far (it follows the camera, never turns); the board fades
# with the camera's distance in the city's own space.
func _follow_camera() -> void:
    var viewer: Node3D = camera
    if _xr_active:
        var scene := _scene()
        var xr_camera := scene.get_node_or_null("objects/XROrigin3D/XRCamera3D") if scene else null
        if xr_camera:
            viewer = xr_camera
    sky.visible = not _xr_active
    sky.global_position = viewer.global_position
    var local := city_root.to_local(viewer.global_position)
    _ground_material.set_shader_parameter("camera_local", local)

func _style_key(t: Dictionary, fresh: bool) -> String:
    return "%s|%s|%s" % [scheme_id, t["tone"], fresh]

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
    if Globals.embed or not (event is InputEventKey):
        return
    var key := event as InputEventKey
    if key.pressed and not key.echo and key.keycode == KEY_C:
        scheme_id = GibsonSchemes.next_id(scheme_id)
        _apply_scheme()

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
        if not xr:
            camera.make_current()
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

# The table-top model is 1.6 m across.
func _model_basis() -> Basis:
    var k := 1.6 / (2.0 * extent)
    return Basis.from_scale(Vector3(k, k, k))

func _present_xr() -> void:
    var scene := _scene()
    if camera.current:
        camera.current = false
    var floor_node: Node = scene.get_node_or_null("stage/Floor") if scene else null
    if floor_node:
        floor_node.visible = true
    if _xr_placed:
        city_root.global_transform.basis = _model_basis()
    if _xr_placed or scene == null:
        return
    var xr_camera := scene.get_node_or_null("objects/XROrigin3D/XRCamera3D") as Node3D
    if xr_camera == null:
        return
    # A table-top model, 1.2 m in front of the viewer, its board at 0.9 m.
    var head := xr_camera.global_transform
    var forward := -head.basis.z
    forward.y = 0.0
    forward = forward.normalized() if forward.length() > 0.001 else Vector3.FORWARD
    city_root.global_transform = Transform3D(_model_basis(),
        Vector3(head.origin.x, 0.9, head.origin.z) + forward * 1.2)
    _xr_placed = true

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
