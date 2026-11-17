extends Camera3D
class_name GibsonCamera

# Two modes. The tour is a pure function of the tour's time and the city's extent.
# Any input switches to flying; 20 s without input blends back to the tour over 2 s.

const IDLE_RETURN := 20.0
const BLEND_SECONDS := 2.0
const BASE_SPEED := 12.0
const LOOK_DEGREES_PER_PIXEL := 0.25
const FLOOR_Y := 0.8
const PITCH_LIMIT := 85.0

var extent: float = 24.0             # the city's, set by the owner
var _extent: float = 24.0            # what the tour and limits use: eased, so a growing city is no cut
var tour_time: float = 0.0
var idle: float = IDLE_RETURN       # seconds since the last input; starts in the tour
var blend: float = 1.0               # 1: the tour; 0: the user's own view
var _fly_origin: Vector3 = Vector3.ZERO
var _yaw: float = 0.0
var _pitch: float = 0.0
var _dragging: bool = false
var _tour_position: Vector3 = Vector3.ZERO

func _init() -> void:
    far = 1000.0
    fov = 70.0
    rotation_order = EULER_ORDER_YXZ

func _ready() -> void:
    _apply_tour()

# ---- the tour -------------------------------------------------------------

static func _ease(x: float) -> float:
    var t := clampf(x, 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)

# The street leg's length and the whole loop's, from the city's size.
static func tour_lengths(extent_value: float) -> Dictionary:
    var run := 2.0 * (extent_value + 10.0)
    var fly := clampf(run / 14.0, 12.0, 20.0)
    return {"run": run, "fly": fly, "loop": 12.0 + 8.0 + fly + 20.0}

static func _look(from: Vector3, target: Vector3) -> Basis:
    var dir := (target - from)
    if dir.length() < 0.001:
        return Basis.IDENTITY
    var up := Vector3.UP if absf(dir.normalized().y) < 0.99 else Vector3.FORWARD
    return Basis.looking_at(dir, up)

static func _orbit(a: float, e: float) -> Vector3:
    var r := e * 1.4
    return Vector3(r * sin(a), e * 1.4, r * cos(a))

# The camera's pose at tour time `t` in a city of half-size `e`: a position and a
# direction it looks at. Every change is eased: no cuts.
static func tour_pose(t_raw: float, e: float) -> Transform3D:
    var lens := tour_lengths(e)
    var fly_s: float = lens["fly"]
    var t := fposmod(t_raw, lens["loop"])
    var street_x := 8.0
    var z0 := e + 10.0
    var pos: Vector3
    var target: Vector3
    var overhead_target := Vector3.ZERO
    var street_target := Vector3(street_x, 6.0, z0 - 30.0)
    if t < 12.0:
        # Overhead, a quarter turn around the city.
        pos = _orbit(_ease(t / 12.0) * PI * 0.5, e)
        target = overhead_target
    elif t < 20.0:
        # Descend to the street's far end.
        var k := _ease((t - 12.0) / 8.0)
        pos = _orbit(PI * 0.5, e).lerp(Vector3(street_x, 8.0, z0), k)
        target = overhead_target.lerp(street_target, k)
    elif t < 20.0 + fly_s:
        # Down the street, height easing between 6 and 10.
        var u := (t - 20.0) / fly_s
        var z := lerpf(z0, -z0, u)
        pos = Vector3(street_x, 8.0 + 2.0 * sin(u * TAU), z)
        target = Vector3(street_x, 6.0, z - 30.0)
    else:
        # Rise and turn back to the overhead orbit's start.
        var k := _ease((t - 20.0 - fly_s) / 20.0)
        var from_pos := Vector3(street_x, 8.0, -z0)
        pos = from_pos.lerp(_orbit(0.0, e), k)
        target = Vector3(street_x, 6.0, -z0 - 30.0).lerp(overhead_target, k)
    return Transform3D(_look(pos, target), pos)

func _apply_tour() -> void:
    var pose := tour_pose(tour_time, _extent)
    _tour_position = pose.origin
    global_transform = pose

# ---- flying ---------------------------------------------------------------

func overhead() -> Transform3D:
    return tour_pose(0.0, _extent)

func _take_control() -> void:
    if blend > 0.0:
        # Whatever is on screen now is where flying starts.
        var rot := global_transform.basis.get_euler(EULER_ORDER_YXZ)
        _yaw = rot.y
        _pitch = rot.x
        _fly_origin = global_position
    blend = 0.0
    idle = 0.0

func _set_pose(position_value: Vector3, yaw: float, pitch: float) -> void:
    _fly_origin = position_value
    _yaw = yaw
    _pitch = clampf(pitch, deg_to_rad(-PITCH_LIMIT), deg_to_rad(PITCH_LIMIT))
    global_transform = Transform3D(Basis.from_euler(Vector3(_pitch, _yaw, 0.0), EULER_ORDER_YXZ), _fly_origin)

func _unhandled_input(event: InputEvent) -> void:
    if not current:
        return
    if event is InputEventMouseButton:
        var mb := event as InputEventMouseButton
        if mb.button_index == MOUSE_BUTTON_LEFT:
            _dragging = mb.pressed
            if mb.pressed:
                _take_control()
        elif mb.pressed and (mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN):
            _take_control()
            var step := maxf(1.5, 0.08 * global_position.y)
            var sign_value := 1.0 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else -1.0
            _move(-global_transform.basis.z * step * sign_value)
    elif event is InputEventMouseMotion and _dragging:
        var mm := event as InputEventMouseMotion
        _take_control()
        var k := deg_to_rad(LOOK_DEGREES_PER_PIXEL)
        _set_pose(_fly_origin, _yaw - mm.relative.x * k, _pitch - mm.relative.y * k)

func _move(delta_position: Vector3) -> void:
    var p := _fly_origin + delta_position
    p.y = maxf(p.y, FLOOR_Y)
    var flat := Vector2(p.x, p.z)
    var limit := _extent + 80.0
    if flat.length() > limit:
        flat = flat.normalized() * limit
        p.x = flat.x
        p.z = flat.y
    _set_pose(p, _yaw, _pitch)

func _process(delta: float) -> void:
    tour_time += delta
    _extent = lerpf(_extent, extent, 1.0 - exp(-delta / 0.5))
    if _dragging and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
        _dragging = false
    var moved := false
    var move := Vector3.ZERO
    var look := Vector2.ZERO

    if not Globals.embed:
        var b := global_transform.basis
        if Input.is_action_pressed("move_forward"): move += -b.z
        if Input.is_action_pressed("move_back"): move += b.z
        if Input.is_action_pressed("move_left"): move += -b.x
        if Input.is_action_pressed("move_right"): move += b.x
        if Input.is_action_pressed("page_up"): move += Vector3.UP
        if Input.is_action_pressed("page_down"): move += Vector3.DOWN
        if Input.is_action_pressed("camera_left"): look.x += 1.0
        if Input.is_action_pressed("camera_right"): look.x -= 1.0
        if Input.is_action_pressed("camera_up"): look.y += 1.0
        if Input.is_action_pressed("camera_down"): look.y -= 1.0
        if Input.is_action_just_pressed("home"):
            var pose := overhead()
            _take_control()
            var rot := pose.basis.get_euler(EULER_ORDER_YXZ)
            _set_pose(pose.origin, rot.y, rot.x)
            moved = true

    var pad: Node = get_tree().current_scene.get_node_or_null("ui/joystick_touch_pad") if get_tree().current_scene else null
    if pad and pad is CanvasItem and (pad as CanvasItem).is_visible_in_tree() and pad.has_method("get_joystick"):
        var stick: Vector2 = pad.get_joystick()
        move += global_transform.basis.x * stick.x + (-global_transform.basis.z) * -stick.y
        var swipe: Vector2 = pad.get_touchpad_delta()
        look += Vector2(-swipe.x, -swipe.y) * 0.4

    if move != Vector3.ZERO or look != Vector2.ZERO:
        _take_control()
        var speed := BASE_SPEED * (3.0 if Input.is_action_pressed("jump") and not Globals.embed else 1.0)
        if look != Vector2.ZERO:
            var rate := deg_to_rad(90.0) * delta
            _set_pose(_fly_origin, _yaw + look.x * rate, _pitch + look.y * rate)
        if move != Vector3.ZERO:
            _move(move.normalized() * speed * delta)
        moved = true

    if _dragging:
        idle = 0.0

    if moved:
        return

    idle += delta
    if blend >= 1.0:
        _apply_tour()
    elif idle >= IDLE_RETURN:
        blend = minf(1.0, blend + delta / BLEND_SECONDS)
        var pose := tour_pose(tour_time, _extent)
        var k := _ease(blend)
        var mine := Quaternion(Basis.from_euler(Vector3(_pitch, _yaw, 0.0), EULER_ORDER_YXZ))
        var target := Quaternion(pose.basis)
        global_transform = Transform3D(Basis(mine.slerp(target, k)), _fly_origin.lerp(pose.origin, k))
