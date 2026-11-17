extends Node3D
class_name GibsonCity

# The Gibson visualization: a city of translucent towers on a circuit-board ground,
# one tower per host. This version reads the Matrix's feed (/api/v1/matrix) and
# derives hosts from it; the layout rules are GibsonLayout's, the colours GibsonSchemes'.

const DEFAULT_POLL_SECONDS := 30.0
const FRESH_SECONDS := 6.0
const RISE_SECONDS := 1.2
const HEIGHT_EASE_SECONDS := 0.6
const BOARD_MARGIN := 96.0
const HOME := "LOCAL"
const TOWER_SHADER := preload("res://shaders/gibson/gibson_tower.gdshader")

var city_root: Node3D
var ground: MeshInstance3D
var towers_root: Node3D
var chips_root: Node3D
var camera: GibsonCamera
var api: StyxApi

var scheme_id: String = "state"
var palette: Dictionary = {}

var placement: Dictionary = GibsonLayout.new_placement()
var hosts: Array = []
var sizes: Dictionary = {}
var towers: Dictionary = {}          # host -> {node, material, row, tone, height, target, side, born}
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
    ground.material_override = _make_ground_material()
    city_root.add_child(ground)

    towers_root = Node3D.new()
    towers_root.name = "towers"
    city_root.add_child(towers_root)

    chips_root = Node3D.new()
    chips_root.name = "chips"
    city_root.add_child(chips_root)

    camera = GibsonCamera.new()
    camera.name = "camera"
    add_child(camera)

    api = StyxApi.new()
    api.request_on_ready = false
    var window := Globals.api_relative if Globals.api_relative != "" else "60s"
    api.init("/api/v1/matrix?relative=" + window)
    api.data_received.connect(_on_data)
    add_child(api)
    api.send_request()

    GibsonLayout.place(placement, [], [HOME])
    _sync_chips()
    _update_board()

    if Globals.shot != "":
        _take_shot()

func _exit_tree() -> void:
    _restore_presentation()

# ---- data -----------------------------------------------------------------

func _on_data(_endpoint: String, data: Array) -> void:
    hosts = GibsonLayout.hosts_from_matrix(data)
    GibsonLayout.place(placement, hosts, [HOME])
    sizes = GibsonLayout.tower_sizes(hosts)

    var first: bool = known == null
    if first:
        known = {}

    var present := {}
    for row in hosts:
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
        if is_new:
            t["height"] = t["target"] if first else 0.0
        if not known.has(host):
            known[host] = true
            if not first:
                t["born"] = clock
    for host in towers.keys():
        if not present.has(host):
            towers[host]["node"].queue_free()
            towers.erase(host)
            known.erase(host)

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
    towers_root.add_child(node)
    towers[host] = {
        "node": node, "material": material, "row": {}, "tone": "normal",
        "height": 0.0, "target": 1.0, "side": 1.5, "born": -1000.0,
    }

func _sync_chips() -> void:
    for source in placement["home"].keys():
        if not chips.has(source):
            var chip := MeshInstance3D.new()
            chip.name = "chip_" + str(source).validate_node_name()
            var box := BoxMesh.new()
            box.size = Vector3(2.0, 0.6, 2.0)
            chip.mesh = box
            var material := StandardMaterial3D.new()
            material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
            material.albedo_color = Color(0.015, 0.012, 0.02)
            chip.material_override = material
            chips_root.add_child(chip)
            chips[source] = chip
        var p := GibsonLayout.chip_position(placement, source)
        chips[source].position = Vector3(p.x, 0.3, p.y)
    for source in chips.keys():
        if not placement["home"].has(source):
            chips[source].queue_free()
            chips.erase(source)

func _make_ground_material() -> Material:
    var material := StandardMaterial3D.new()
    material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    material.albedo_color = palette["board"]
    return material

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
        api.send_request()

    _animate_towers(delta)
    _present()

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
        var fresh: bool = age < FRESH_SECONDS
        var glass: Color = palette["fresh"] if fresh else palette["glass"][t["tone"]]
        var material: ShaderMaterial = t["material"]
        material.set_shader_parameter("size", Vector3(side, shown, side))
        material.set_shader_parameter("glass", glass)
        material.set_shader_parameter("brightness", 1.0)

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

func _present_xr() -> void:
    var scene := _scene()
    if camera.current:
        camera.current = false
    var floor_node: Node = scene.get_node_or_null("stage/Floor") if scene else null
    if floor_node:
        floor_node.visible = true
    if _xr_placed:
        var k := 1.6 / (2.0 * extent)
        city_root.global_transform.basis = Basis.from_scale(Vector3(k, k, k))
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
    var s := 1.6 / (2.0 * extent)
    city_root.global_transform = Transform3D(Basis.from_scale(Vector3(s, s, s)),
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
