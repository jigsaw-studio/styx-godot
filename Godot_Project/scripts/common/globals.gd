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
# When set, every request goes to this base over HTTP(S) instead of to the Pi:
# "http://localhost:8880/api/styx" for a Layman instance. "/api/v1/matrix" is then
# requested as api_base_url + "/v1/matrix". Empty: the Pi, as before.
var api_base_url: String = ""
# Appended to every request's query when set, e.g. "session=<id>" (Layman).
var api_extra_query: String = ""
# Overrides the "relative" window of the Matrix request when set, e.g. "15m".
var api_relative: String = ""
# Seconds between light refreshes that only ADD destinations not yet on screen.
# 0: off, the Pi's behaviour.
var api_poll_seconds: float = 0.0
# Embedded in another page (Layman): no UI, fixed camera, Matrix only.
var embed: bool = false

func _init() -> void:
    _read_settings()

# Settings come from the page's query string (web) or from the command line
# (native: --api=… --session=… --relative=… --poll=… after "--") and, for the
# API base only, the STYX_API_URL environment variable. The text can come from a
# URL anyone can craft, so every value is validated before it is used.
func _read_settings() -> void:
    var args := _read_web_query() if is_running_in_web else _read_cmdline()

    var api: String = args.get("api", "")
    if api == "" and not is_running_in_web:
        api = OS.get_environment("STYX_API_URL")
    if is_running_in_web:
        # On the web only a path on the page's own origin is accepted: a crafted
        # link must not make the page contact (and draw hosts from) another site.
        api = (str(JavaScriptBridge.eval("window.location.origin", true)) + api) if api.begins_with("/") and not api.begins_with("//") else ""
    if api.begins_with("http://") or api.begins_with("https://"):
        api_base_url = api.rstrip("/")

    var session: String = args.get("session", "")
    if _matches(session, "^[A-Za-z0-9_-]{1,128}\\z"):
        api_extra_query = "session=" + session

    var relative: String = args.get("relative", "")
    if _matches(relative, "^[0-9]{1,6}[smhd]\\z"):
        api_relative = relative

    var poll: String = args.get("poll", "")
    if poll.is_valid_float():
        var seconds := poll.to_float()
        if seconds >= 1.0 and seconds <= 60.0:
            api_poll_seconds = seconds

    embed = is_running_in_web and args.get("embed", "") == "1"

func _matches(text: String, pattern: String) -> bool:
    var re := RegEx.new()
    re.compile(pattern)
    return re.search(text) != null

func _read_cmdline() -> Dictionary:
    var out := {}
    for arg in OS.get_cmdline_user_args():
        if arg.begins_with("--") and arg.contains("="):
            var kv: PackedStringArray = arg.substr(2).split("=", true, 1)
            out[kv[0]] = kv[1]
    return out

func _read_web_query() -> Dictionary:
    var out := {}
    var search = JavaScriptBridge.eval("window.location.search", true)
    if typeof(search) != TYPE_STRING or search.length() < 2:
        return out
    for pair in search.substr(1).split("&", false):
        var kv = pair.split("=", true, 1)
        out[kv[0].uri_decode()] = kv[1].uri_decode() if kv.size() > 1 else ""
    return out
