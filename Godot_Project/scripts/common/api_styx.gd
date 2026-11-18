extends Node
class_name StyxApi

# This line will generate the following debugger warning, please ignore:
# The signal "data_received" is declared but never explicitly used in the class
@warning_ignore("unused_signal")
signal data_received(endpoint: String, data: Array)
# An answer did not come or was not an array (never emitted for an empty array).
@warning_ignore("unused_signal")
signal request_failed(endpoint: String)

const UDP_ANSWER_SECONDS := 5.0

# Network client setup (UDP for native clients, TCP HTTPRequest for WebXR web export)
var http_client: HTTPRequest = HTTPRequest.new()
var is_initialized: bool = false  # Prevents duplicate initialization
var udp_client: PacketPeerUDP = PacketPeerUDP.new()
var packet_fragments := {}

var api_endpoint: String = ""
var request_on_ready: bool = true  # false: the owner sends when it wants
var request_in_flight: bool = false  # HTTP only: a send while set is dropped, not queued
var _udp_waiting: float = -1.0  # UDP only: seconds since send_request(), -1 when nothing is awaited

# True when requests go over HTTP(S): always on web, and natively when
# Globals.api_base_url is set (a Layman instance rather than the Pi).
func _uses_http() -> bool:
    return Globals.is_running_in_web or Globals.api_base_url != ""

# The URL for api_endpoint, still written by callers as "/api/v1/…".
func _http_url() -> String:
    if Globals.api_base_url == "":
        return "https://%s:%d%s" % [Globals.server_ip, Globals.server_port_tcp, api_endpoint]
    var url: String = Globals.api_base_url + api_endpoint.trim_prefix("/api")
    if Globals.api_extra_query != "":
        url += ("&" if url.contains("?") else "?") + Globals.api_extra_query
    return url

# Initialize styx_api with a specific endpoint
func init(api_path: String) -> void:
    if is_initialized:
        return
    is_initialized = true
    api_endpoint = api_path

# Ask for another path from now on (a selected tower's log).
func set_endpoint(api_path: String) -> void:
    api_endpoint = api_path
    if not _uses_http():
        packet_fragments.clear()

func _ready():
    if _uses_http():
        # Add HTTPRequest to the scene tree and connect signal
        add_child(http_client)
        http_client.timeout = 15.0  # a hung answer must not block every later request
        http_client.connect("request_completed", self._process_response_http)
        if request_on_ready:
            send_request()
    else:
        # Create and bind the UDP client to any available port
        if udp_client and not udp_client.is_bound():  # Ensure it's not already bound
            var bind_result: int = udp_client.bind(0)
            if bind_result != OK:
                print("Failed to bind UDP client, error code: ", bind_result)

func send_request() -> void:
    if api_endpoint == "":
        return  # init() has not been called: nothing to ask for
    if not _uses_http():
        var json_data: Dictionary = {"GET": api_endpoint}
        var json_str: String = JSON.stringify(json_data)

        # Send request via UDP
        udp_client.connect_to_host(Globals.server_ip, Globals.server_port_udp)
        var packet: PackedByteArray = json_str.to_utf8_buffer()
        var sent: int = udp_client.put_packet(packet)
        if sent == OK:
            _udp_waiting = 0.0
            print("Sent via UDP: ", json_str)
        else:
            print("Failed to send request via UDP")
            request_failed.emit(api_endpoint)
    else:
        if request_in_flight:
            print("Dropping HTTP request, one is still in flight")
            return
        var url := _http_url()
        print("Connecting to URL: ", url)
        var error = http_client.request(url, [], HTTPClient.METHOD_GET)
        if error != OK:
            print("Failed to initiate HTTP request. Error: ", error)
            request_failed.emit(api_endpoint)
        else:
            request_in_flight = true

func _process(delta: float) -> void:
    if not _uses_http():
        receive_udp_response()
        if _udp_waiting >= 0.0:
            _udp_waiting += delta
            if _udp_waiting >= UDP_ANSWER_SECONDS:
                # No complete answer: drop the fragments so a late one of this answer cannot join the next.
                _udp_waiting = -1.0
                packet_fragments.clear()
                request_failed.emit(api_endpoint)

func receive_udp_response() -> void:
    while udp_client.get_available_packet_count():
        var packet: PackedByteArray = udp_client.get_packet()
        var response: String = packet.get_string_from_utf8()
        process_response_udp(response)

func process_response_udp(response: String) -> void:
    # Parse the fragment
    var delimiter_index: int = response.find(":")
    if delimiter_index == -1:
        print("Received malformed packet: ", response)
        return

    var header: String = response.substr(0, delimiter_index)
    var body: String = response.substr(delimiter_index + 1)

    # Parse the header (format: "fragment_num/total_fragments")
    var fragment_info: PackedStringArray = header.split("/")
    if fragment_info.size() != 2:
        print("Received malformed packet header: ", header)
        return

    var fragment_num: int = int(fragment_info[0])
    var total_fragments: int = int(fragment_info[1])

    # Store the fragment
    if !packet_fragments.has(fragment_num):
        packet_fragments[fragment_num] = body

    # Once all fragments have been received, process the complete response.
    if packet_fragments.size() == total_fragments:
        var complete_response: String = ""
        for i in range(1, total_fragments + 1):
            complete_response += packet_fragments[i]

        # All fragments received, process the response
        _udp_waiting = -1.0
        process_data(complete_response)

        # Clear stored fragments for the next message
        packet_fragments.clear()

func _process_response_http(_result, response_code: int, _headers, body: PackedByteArray) -> void:
    request_in_flight = false
    if response_code == 200:
        var response: String = body.get_string_from_utf8()
        process_data(response)
    else:
        print("HTTP request failed with response code: ", response_code)
        request_failed.emit(api_endpoint)

# Process the data returned by the call to the API
func process_data(body: String) -> void:
    var json = JSON.new()
    var json_result = json.parse(body)

    if json_result == OK:
        var parsed_data = json.get_data()
        # An empty array is valid (a quiet session): emit it so old data can go.
        # Anything that is not an array leaves the last data on screen.
        if typeof(parsed_data) == TYPE_ARRAY:
            emit_signal("data_received", api_endpoint, parsed_data)
        else:
            print("Unexpected JSON response, keeping the last data")
            request_failed.emit(api_endpoint)
    else:
        print("Failed to parse JSON: ", body)
        request_failed.emit(api_endpoint)
