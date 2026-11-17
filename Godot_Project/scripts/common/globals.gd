extends Node

# Environment
var DEBUG: bool = false
var is_running_in_visionos: bool = OS.get_name() == "iOS" and OS.get_environment("GODOT_PLATFORM") == "visionOS"
var is_running_in_web: bool = OS.get_name() == "Web" or OS.get_name() == "HTML5"
var joystick_touch_pad_enabled: bool = false
var passthrough_enabled: bool = false

# User
var EYE_HEIGHT: float = 1.75
var MAX_HEIGHT: float = 20  # Ceiling limit
var MIN_HEIGHT: float = 0.0005  # Floor limit

# API
var server_ip: String = "172.16.100.1"
var server_port_tcp: int = 443
var server_port_udp: int = 8192
