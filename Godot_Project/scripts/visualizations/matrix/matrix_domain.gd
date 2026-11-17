extends VisualizationWindow
class_name MatrixDomainWindow

# Description of visualization:
# - A list of domains to scroll should be retrieved from the API every UPDATE_INTERVAL seconds.
# - Each domain will scroll through the viewable area of the matrix from top to bottom.
# - The last letter of each domain will appear first (in the top row) and will descend
#   into view within that column, revealing the rest of the domain.
# - Scrolling down will continue until the name reaches the bottom, at which point letters
#   will be removed from view as they pass the bottom row, until the entire
#   domain name has scrolled out of view.
# - The specific column a given domain name will select for scrolling will be
#   based on a "batch" system.
# - Based on the number of domains returned (the maximum usable equal to total_columns),
#   the top domains in order should be grouped into batches set by NUM_BATCHES.
# - Each of the total_columns should be randomly assigned to one of the batches
#   for display (each batch should get the same number of columns assigned).
# - When a given domain finishes scrolling that same domain should begin scrolling again
#   in the next available column for its batch (randomly chosen from the remainder 
#   if more than one is available).
# - At the end of the UPDATE_INTERVAL the API will be queried again and the batch
#   distribution should be reset.

var styx_api: StyxApi
var peek_api: StyxApi  # light refresh that only adds new destinations
var peek_timer: float = 0.0
var fading: bool = false

# Configuration
var UPDATE_INTERVAL: float = 30.0  # Time in seconds between API updates
var API_ENDPOINT: String = "/api/v1/matrix"
var API_PARAMS: String = "?relative=60s"

# Batch configuration
var NUM_BATCHES: int = 3  # Number of batches to split domains into
var BATCH_DELAY: float = 10.0  # Seconds between each batch

# Core properties
var resolution = Vector2(1024, 1024)
var render_speed: float = 0.36
var total_columns: int = resolution.x / 8.0  # const float LX = 8.0; // letter space x
var total_rows: int = resolution.y / 10.0  # const float LY = 10.0; // letter space y
var max_rain_speed: float = 5.0  # Max possible speed is 10.0
var min_rain_speed: float = 1.0  # Min possible speed is 0.1

# State tracking
var domain_counts = {}
var active_domains = {}
var update_timer: float = 0.0
var batch_timer: float = 0.0
var current_batch: int = 0
var pending_batches = []
var available_columns = []  # Track all available columns
var batch_ranges = []  # Store column ranges for each batch
var last_used_columns = {}  # Tracks last-used column for each domain
var column_cooldown = {}  # Maps columns to the time they should remain unavailable

var character_table: Dictionary = {
    "0": 0.0,  "1": 1.0,  "2": 2.0,  "3": 3.0,  "4": 4.0,
    "5": 5.0,  "6": 6.0,  "7": 7.0,  "8": 8.0,  "9": 9.0,
    "A": 10.0, "B": 11.0, "C": 12.0, "D": 13.0, "E": 14.0,
    "F": 15.0, "G": 16.0, "H": 17.0, "I": 18.0, "J": 19.0,
    "K": 20.0, "L": 21.0, "M": 22.0, "N": 23.0, "O": 24.0,
    "P": 25.0, "Q": 26.0, "R": 27.0, "S": 28.0, "T": 29.0,
    "U": 30.0, "V": 31.0, "W": 32.0, "X": 33.0, "Y": 34.0,
    "Z": 35.0, ".": 36.0, "-": 37.0, ":": 38.0, " ": 39.0
}

func _ready() -> void:
    window_position = Vector3(0, Globals.EYE_HEIGHT, 6)
    window_size = Vector2(5, 5)
    shader_path = "res://shaders/matrix/matrix_domain.gdshader"

    # Initialize columns
    initialize_columns()
    
    # Initialize API
    API_PARAMS = "?relative=" + (Globals.api_relative if Globals.api_relative != "" else "60s")
    styx_api = StyxApi.new()
    styx_api.init(API_ENDPOINT + API_PARAMS)
    styx_api.connect("data_received", Callable(self, "_on_data_received"))
    add_child(styx_api)
    
    # Initial API request
    styx_api.send_request()

    # The light refresh (off unless Globals.api_poll_seconds is set). No request
    # now: the main one just went.
    if Globals.api_poll_seconds > 0.0:
        peek_api = StyxApi.new()
        peek_api.init(API_ENDPOINT + API_PARAMS)
        peek_api.connect("data_received", Callable(self, "_on_peek_received"))
        add_child(peek_api)

func initialize_columns() -> void:
    available_columns = []
    batch_ranges = []

    # Initialize batch_ranges for each batch
    batch_ranges.resize(NUM_BATCHES)
    for i in range(NUM_BATCHES):
        batch_ranges[i] = []

    # Assign each column to a random batch
    for col in range(total_columns):
        var batch_idx = randi() % NUM_BATCHES
        batch_ranges[batch_idx].append(col)

    # All columns start as available
    available_columns = range(total_columns)

func _process(delta: float) -> void:
    update_timer += delta

    if peek_api:
        peek_timer += delta
        if peek_timer >= Globals.api_poll_seconds:
            peek_timer = 0.0
            if not fading:
                peek_api.send_request()

    if current_batch < NUM_BATCHES:
        batch_timer += delta
        if batch_timer >= BATCH_DELAY:
            batch_timer = 0.0
            display_next_batch()
    
    # Check for completed domains
    var domains_to_remove = []
    for domain in active_domains.keys():
        var domain_info = active_domains[domain]
        domain_info.elapsed_time += delta
        
        if domain_info.elapsed_time >= calculate_domain_duration(domain):
            print("Removing domain: ", domain)
            domains_to_remove.append(domain)
    
    # Handle completed domains
    for domain in domains_to_remove:
        cleanup_domain(domain)

    # Check for interval expiration
    if update_timer >= UPDATE_INTERVAL:
        fade_out_all_domains()
        update_timer = 0.0  # Prevents multiple triggers
        
    # Reduce column cooldowns over time
    for col in column_cooldown.keys():
        column_cooldown[col] -= delta
        if column_cooldown[col] <= 0:
            column_cooldown.erase(col)

func fade_out_all_domains() -> void:
    fading = true
    var domains = active_domains.keys().duplicate()
    if domains.is_empty():
        _on_all_domains_faded()
        return

    # Use a reference object to track remaining domains
    var tracker = {"remaining": domains.size()}
    
    for domain in domains:
        var domain_info = active_domains[domain]
        if is_instance_valid(domain_info.mesh_instance):
            var tween = create_tween()
            tween.tween_method(
                func(alpha: float):
                    if is_instance_valid(domain_info.mesh_instance) and domain_info.mesh_instance.material_override:
                        domain_info.mesh_instance.material_override.set_shader_parameter("alpha", alpha),
                1.0, 0.0, 0.5  # TODO increate fade time
            )
            tween.connect("finished", func():
                _remove_domain(domain)
                tracker.remaining -= 1
                if tracker.remaining == 0:
                    _on_all_domains_faded()
            )

func _on_all_domains_faded() -> void:
    fading = false
    # Clear all existing domains and reset state
    active_domains.clear()
    domain_counts.clear()
    pending_batches.clear()
    
    initialize_columns()
    current_batch = 0
    batch_timer = 0.0
    update_timer = 0.0
    
    # Request new data
    styx_api.send_request()

func _remove_domain(domain: String) -> void:
    if active_domains.has(domain):
        var domain_info = active_domains[domain]
        if is_instance_valid(domain_info.mesh_instance):
            domain_info.mesh_instance.queue_free()
        active_domains.erase(domain)

func get_available_column_for_batch(batch_idx: int, domain: String) -> int:
    if batch_idx < 0 or batch_idx >= NUM_BATCHES:
        return -1

    var possible_columns = []
    for col in batch_ranges[batch_idx]:
        if available_columns.has(col) and last_used_columns.get(domain, -1) != col:
            # Ensure column is not in cooldown
            if not column_cooldown.has(col):
                possible_columns.append(col)

    if possible_columns.is_empty():
        return -1

    possible_columns.shuffle()
    var chosen_column = possible_columns[0]

    # Store the last-used column for the domain
    last_used_columns[domain] = chosen_column
    available_columns.erase(chosen_column)
    return chosen_column

func return_column_to_pool(column: int) -> void:
    if column >= 0 and column < total_columns and not column in available_columns:
        available_columns.append(column)

func _on_data_received(_endpoint: String, data: Array) -> void:
    domain_counts.clear()
    pending_batches.clear()
    
    # Process received data
    for entry in data:
        if entry.has("address") and entry.has("count"):
            domain_counts[entry.address] = entry.count
    
    prepare_batches()

# Adds destinations not yet on screen, at once; never removes or changes anything.
func _on_peek_received(_endpoint: String, data: Array) -> void:
    if fading:
        return
    for entry in data:
        if not (entry is Dictionary and entry.has("address") and entry.has("count")):
            continue
        var address = entry.address
        if domain_counts.has(address) or active_domains.has(address):
            continue
        domain_counts[address] = entry.count
        var column := -1
        var batch := -1
        # Nearest earlier batch first, then later ones.
        var order := range(mini(current_batch, NUM_BATCHES) - 1, -1, -1)
        order.append_array(range(current_batch, NUM_BATCHES))
        for b in order:
            column = get_available_column_for_batch(b, address)
            if column != -1:
                batch = b
                break
        if column == -1:
            continue  # the next full cycle places it
        while pending_batches.size() <= batch:
            pending_batches.append([])
        pending_batches[batch].append({"domain": address, "speed": max_rain_speed})
        create_single_domain(address, max_rain_speed, column)

func prepare_batches() -> void:
    var domain_speeds = calculate_frequencies(domain_counts)
    
    # Sort domains by access count (descending)
    var sorted_domains = domain_counts.keys()
    sorted_domains.sort_custom(func(a, b): return domain_counts[a] > domain_counts[b])
    
    # Prepare domain data
    var all_domains = []
    for domain in sorted_domains:
        all_domains.append({
            "domain": domain,
            "speed": domain_speeds[domain]
        })
    
    # Distribute domains across batches
    pending_batches = []
    var domains_per_batch = ceili(float(all_domains.size()) / NUM_BATCHES)
    
    for i in range(NUM_BATCHES):
        var start_idx = i * domains_per_batch
        var end_idx = mini(start_idx + domains_per_batch, all_domains.size())
        if start_idx < all_domains.size():
            pending_batches.append(all_domains.slice(start_idx, end_idx))
    
    # Start first batch
    display_next_batch()

func display_next_batch() -> void:
    if current_batch >= NUM_BATCHES or current_batch >= pending_batches.size():
        return
    
    var batch_domains = pending_batches[current_batch]
    
    for domain_data in batch_domains:
        var column = get_available_column_for_batch(current_batch, domain_data.domain)
        if column != -1:
            create_single_domain(domain_data.domain, domain_data.speed, column)
    
    current_batch += 1

func create_single_domain(domain: String, speed: float, column: int) -> void:
    var domain_chars = []
    for c in domain.reverse():
        domain_chars.append(character_table.get(c.to_upper(), 39.0))

    # Calculate initial position to start above the display
    var start_offset = float(domain.length()) * 10.0  # Multiply by character height
    
    # Ensure consistent start time across batches (independent of system time)
    var start_time = -start_offset / speed  # Ensures it starts above the screen

    shader_parameters = {
        "resolution": resolution,
        "render_speed": render_speed,
        "rain_speed": speed,
        "domain": PackedFloat32Array(domain_chars),
        "domain_length": domain.length(),
        "domain_column": column,
        "start_time": start_time,  # Adjusted start time for proper positioning
    }

    setup_window()

    if mesh_instance and mesh_instance.material_override is ShaderMaterial:
        mesh_instance.material_override.render_priority = 1

    active_domains[domain] = {
        "elapsed_time": 0.0,
        "speed": speed,
        "column": column,
        "mesh_instance": mesh_instance,
        "start_time": start_time,
    }

func calculate_frequencies(counts: Dictionary) -> Dictionary:
    if counts.is_empty():
        return {}
    var max_count = counts.values().max()
    if max_count == 0:
        return {}
    
    var frequencies = {}
    for domain in counts:
        var normalized_freq = (counts[domain] / float(max_count)) * (max_rain_speed - min_rain_speed) + min_rain_speed
        frequencies[domain] = normalized_freq
    
    return frequencies

func calculate_domain_duration(domain: String) -> float:
    var domain_info = active_domains[domain]
    # Calculate time needed for domain to scroll completely out of view
    # Add extra time to account for starting above the display
    return ((domain.length() + total_rows + 10) * 10.0) / domain_info.speed

func cleanup_domain(domain: String) -> void:
    if active_domains.has(domain):
        var domain_info = active_domains[domain]
        
        # Mark column as "cooling down" (prevents immediate reuse)
        column_cooldown[domain_info.column] = UPDATE_INTERVAL  # Prevent reuse for full refresh cycle
        
        return_column_to_pool(domain_info.column)

        # Only restart if domain is still in the dataset
        if domain in domain_counts:
            var batch_idx = get_batch_for_domain(domain)
            if batch_idx != -1:
                var new_column = get_available_column_for_batch(batch_idx, domain)
                if new_column != -1:
                    create_single_domain(domain, domain_info.speed, new_column)

        if is_instance_valid(domain_info.mesh_instance):
            domain_info.mesh_instance.queue_free()
        active_domains.erase(domain)

func get_batch_for_domain(domain: String) -> int:
    for batch_idx in range(pending_batches.size()):
        for domain_data in pending_batches[batch_idx]:
            if domain_data.domain == domain:
                return batch_idx
    return -1
