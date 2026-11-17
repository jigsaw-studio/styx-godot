extends Node3D

var interface_alerts : bool = false
var xr_interface : XRInterface

func _ready():

    if Globals.embed:
        _setup_embed()
        initialize_visualizations()
        return

    if not Globals.is_running_in_web:
        $ui/WebCanvasLayer.visible = false
        xr_interface = XRServer.find_interface("OpenXR")
        if xr_interface and xr_interface.is_initialized():
            print("OpenXR initialized")
            
            # Turn off v-sync!
            DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)

            get_viewport().use_xr = true

            Globals.passthrough_enabled = enable_passthrough()
        else:
            print("OpenXR not initialized, please check if your headset is connected")
            Globals.joystick_touch_pad_enabled = true

    else:        
        $ui/WebCanvasLayer.visible = true
    
        xr_interface = XRServer.find_interface("WebXR")
        if xr_interface:
            print("WebXR initialized")

            $ui/WebCanvasLayer/WebButton.pressed.connect(self._on_button_pressed)
            # WebXR uses a lot of asynchronous callbacks, so we connect to various
            # signals in order to receive them.
            xr_interface.session_supported.connect(self._webxr_session_supported)
            xr_interface.session_started.connect(self._webxr_session_started)
            xr_interface.session_ended.connect(self._webxr_session_ended)
            xr_interface.session_failed.connect(self._webxr_session_failed)

            # This returns immediately - our _webxr_session_supported() method
            # (which we connected to the "session_supported" signal above) will
            # be called sometime later to let us know if it's supported or not.
            xr_interface.is_session_supported("immersive-vr")
            #xr_interface.is_session_supported("immersive-ar")
        else :
            Globals.joystick_touch_pad_enabled = true
    
    update_joystick_touch_pad(Globals.joystick_touch_pad_enabled)

    # Initialize visualizations after environment interface is established
    initialize_visualizations()

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(_delta):
    pass

func enable_passthrough() -> bool:
    xr_interface = XRServer.primary_interface
    if xr_interface and xr_interface.is_passthrough_supported():
        if !xr_interface.start_passthrough():
            return false
        else:
            var modes: Array = xr_interface.get_supported_environment_blend_modes()
            if xr_interface.XR_ENV_BLEND_MODE_ALPHA_BLEND in modes:
                xr_interface.set_environment_blend_mode(xr_interface.XR_ENV_BLEND_MODE_ALPHA_BLEND)
            else:
                return false

        get_viewport().transparent_bg = true

    return true

func _webxr_session_supported(session_mode: String, supported: bool) -> void:
    if session_mode == 'immersive-vr':
        if supported:
            $ui/WebCanvasLayer.visible = true
        else:
            if interface_alerts:
                OS.alert("Your browser doesn't support VR")
    elif session_mode == 'immersive-ar':
        if supported:
            $ui/WebCanvasLayer.visible = true
        else:
            if interface_alerts:
                OS.alert("Your browser doesn't support AR")
 
func _on_button_pressed() -> void:
    # Whether we want an immersive VR session ('immersive-vr'),
    # as opposed to AR ('immersive-ar'),
    # or a simple 3DoF viewer ('viewer').
    xr_interface.session_mode = 'immersive-vr'
    #xr_interface.session_mode = 'immersive-ar'
    # 'bounded-floor' is room scale, 'local-floor' is a standing or sitting
    # experience (it puts you 1.6m above the ground if you have 3DoF headset),
    # whereas as 'local' puts you down at the ARVROrigin.
    # This list means it'll first try to request 'bounded-floor', then
    # fallback on 'local-floor' and ultimately 'local', if nothing else is
    # supported.
    xr_interface.requested_reference_space_types = 'bounded-floor, local-floor, local'
    # In order to use 'local-floor' or 'bounded-floor' we must also
    # mark the features as required or optional.
    xr_interface.required_features = 'local-floor'
    xr_interface.optional_features = 'bounded-floor'
 
    # Position of XROrigin3D is getting reset and the perspective
    # falls through the floor so we manually place it back above at 1.6m
    var xr_origin = get_node_or_null("objects/XROrigin3D")
    if xr_origin and xr_origin is Node3D:
        var xform = xr_origin.global_transform
        xform.origin.y = 1.6
        xr_origin.global_transform = xform

    # This will return false if we're unable to even request the session,
    # however, it can still fail asynchronously later in the process, so we
    # only know if it's really succeeded or failed when our
    # _webxr_session_started() or _webxr_session_failed() methods are called.
    if not xr_interface.initialize():
        if interface_alerts:
            OS.alert("Failed to initialize WebXR")
        return

func _webxr_session_started() -> void:
    $ui/WebCanvasLayer.visible = false
    # This tells Godot to start rendering to the headset.
    get_viewport().use_xr = true

    Globals.passthrough_enabled = enable_passthrough()

    # This will be the reference space type you ultimately got, out of the
    # types that you requested above. This is useful if you want the game to
    # work a little differently in 'bounded-floor' versus 'local-floor'.
    print ("Reference space type: " + xr_interface.reference_space_type)
 
func _webxr_session_ended() -> void:
    $ui/WebCanvasLayer.visible = true
    # If the user exits immersive mode, then we tell Godot to render to the web
    # page again.
    get_viewport().use_xr = false
 
func _webxr_session_failed(message: String) -> void:
    if interface_alerts:
        OS.alert("Failed to initialize: " + message)

func update_joystick_touch_pad(enable : bool) -> void:
    if not enable:
        # XR is active: use XR camera (default)
        # Hide or disable the standard camera approach
        $objects/joystick_touch_pad.visible = false
        $objects/joystick_touch_pad/head/Camera3D.current = false
    else:
        # XR not active: use joystick camera
        $objects/XROrigin3D.visible = false
        $objects/XROrigin3D/XRCamera3D.current = false
        $objects/VisionVolumeCamera/Camera3D.current = false
        
        $objects/joystick_touch_pad.visible = true
        $objects/joystick_touch_pad/head/Camera3D.current = true

# Embedded in another page (Layman, "?embed=1"): the Matrix plane fills the frame,
# on black, with no XR, no controls and a camera that cannot move.
func _setup_embed() -> void:
    Globals.joystick_touch_pad_enabled = true
    update_joystick_touch_pad(true)

    # A CanvasLayer is not hidden by its parent Control: hide both.
    $ui.visible = false
    $ui/WebCanvasLayer.visible = false

    # Keys pressed in the host page must not walk the camera away.
    var player = $objects/joystick_touch_pad
    player.set_physics_process(false)
    player.set_process_input(false)
    player.set_process_unhandled_input(false)

    $stage/Floor.visible = false

    var environment: Environment = $env/WorldEnvironment.environment
    environment.background_mode = Environment.BG_COLOR
    environment.background_color = Color.BLACK

    # The Matrix windows are 5 x 5 m planes at z = 6 facing +Z. With the default
    # 75 degree vertical field of view the plane fills the height at
    # 2.5 / tan(37.5 degrees) metres: put the camera there. On a wide frame the sides
    # stay black; the plane is not stretched.
    var distance := 2.5 / tan(deg_to_rad(37.5))
    player.position = Vector3(0, 0, 6.0 + distance)

func initialize_visualizations() -> void:
    var visualizations_scene = get_node_or_null("visualizations")

    if visualizations_scene:
        # The following visualizations entirely depend on shaders
        if not Globals.is_running_in_visionos:
            # Godot Vision does not currently support shaders
            if Globals.viz == "gibson":
                visualizations_scene.show_visualization("gibson")
                return
            # The walk-around rain competes with the plane when it is the whole picture
            if not Globals.embed:
                visualizations_scene.show_visualization("matrix_3d_rain")

            visualizations_scene.show_visualization("matrix_background")
            visualizations_scene.show_visualization("matrix_domain")
        else:
            visualizations_scene.show_visualization("bar_chart_raw")
            visualizations_scene.show_visualization("bar_chart_remote")
