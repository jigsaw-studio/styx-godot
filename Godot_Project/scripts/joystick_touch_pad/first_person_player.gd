extends CharacterBody3D

@onready var head = $head

@export var joystick_touch_pad:Control

const SPEED = 5.0
const JUMP_VELOCITY = 4.5
var MIN_HEIGHT = 0.0005  # Adjust to "main" scene's floor level
var MAX_HEIGHT = 20  # Ceiling limit
const LOOK_SENS = 2.0
const CAMERA_LOOK_SPEED = SPEED  # Match to position movement speed

var gravity = ProjectSettings.get_setting("physics/3d/default_gravity")
var initial_position: Vector3  # Store player's original position
var jump_just_pressed = false

var visualizations_scene = null  # TODO

func _ready():
    initial_position = global_transform.origin  # Store initial position
    visualizations_scene = get_node_or_null("../../visualizations")  # TODO

func reset_position():
    print("Resetting player to initial position:", initial_position)
    global_transform.origin = initial_position
    velocity = Vector3.ZERO  # Reset velocity to prevent continuous falling

    # Reset camera angle
    rotation = Vector3.ZERO
    head.rotation = Vector3.ZERO  # Reset head rotation to original state

func on_floor() -> bool:
    # is_on_floor() not returning correct value
    return global_transform.origin.y == get_floor_normal().y

func look(look_vector):
    look_vector = look_vector / get_viewport().content_scale_size.y
    look_vector = look_vector * LOOK_SENS
    rotate_y(look_vector.x)
    head.rotate_x(look_vector.y)
    head.rotation.x = clamp(head.rotation.x, deg_to_rad(-89), deg_to_rad(89))

func _physics_process(delta):
    
    # Handle camera control with Input Map actions
    var camera_look = Vector2.ZERO
    if Input.is_action_pressed("camera_left"):
        camera_look.x += CAMERA_LOOK_SPEED
    if Input.is_action_pressed("camera_right"):
        camera_look.x -= CAMERA_LOOK_SPEED
    if Input.is_action_pressed("camera_up"):
        camera_look.y += CAMERA_LOOK_SPEED
    if Input.is_action_pressed("camera_down"):
        camera_look.y -= CAMERA_LOOK_SPEED    
    look(camera_look)
    
    # Raise and lower perspective
    if Input.is_action_pressed("page_up"):
        head.position.y += CAMERA_LOOK_SPEED * delta
    if Input.is_action_pressed("page_down"):
        head.position.y -= CAMERA_LOOK_SPEED * delta
        
    # Handle looking around with joystick
    look(-joystick_touch_pad.get_touchpad_delta())
    
    # Apply gravity if not on the floor and movement isn't overriding it
    if not is_on_floor(): # is_on_floor() not returning correct value
        velocity.y -= gravity * delta

    # Prevent floating too high or sinking too low
    if global_position.y < Globals.MIN_HEIGHT:
        global_position.y = 0
        velocity.y = 0  # Stop downward movement
    elif global_position.y > Globals.MAX_HEIGHT:
        global_position.y = Globals.MAX_HEIGHT
        velocity.y = 0  # Stop upward movement
    
    # Jump input
    if jump_just_pressed and on_floor():
        jump_just_pressed = false
        velocity.y = JUMP_VELOCITY

    # On-screen joystick input
    var input_dir = joystick_touch_pad.get_joystick()

    # Keyboard and Input map controls:
    if Input.is_action_pressed("move_forward"):
        input_dir.y -= 1
    if Input.is_action_pressed("move_back"):
        input_dir.y += 1
    if Input.is_action_pressed("move_left"):
        input_dir.x -= 1
    if Input.is_action_pressed("move_right"):
        input_dir.x += 1

    # Reset to original position on Home key or button
    if Input.is_action_pressed("home"):
        reset_position()
        
    # Handle space bar for jump
    if Input.is_action_just_pressed("jump"):
        jump_just_pressed = true

    # Normalize to avoid diagonal overspeeding
    if input_dir.length() > 1:
        input_dir = input_dir.normalized()

    # Convert to 3D direction
    var direction = (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()

    # Movement
    if direction != Vector3.ZERO:
        velocity.x = direction.x * SPEED
        velocity.z = direction.z * SPEED
    else:
        velocity.x = move_toward(velocity.x, 0, SPEED)
        velocity.z = move_toward(velocity.z, 0, SPEED)

    move_and_slide()

func on_jump_button_pressed():
    jump_just_pressed = true
