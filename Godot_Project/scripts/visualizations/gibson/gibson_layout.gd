class_name GibsonLayout
extends RefCounted

# The rules of the Gibson city, as pure functions: no node, no Globals, no randomness.
# A host row is a Dictionary with the fields of the Gibson API's /v1/hosts
# (host, block, ports, sent, received, count, open, blocked, untunnelled, scope,
# first_seen_ago, last_seen_ago, clients, tools, services).

const LOT := 3.0
const BLOCK_LOTS := 4
const STREET := 4.0
const BLOCK_PITCH := 16.0
const MAX_TOWERS := 160      # this round makes one mesh and material per tower
const LOTS_PER_BLOCK := 16
const HOME_DEFAULT_LOT := 5
const SECOND_LEVEL := ["co", "com", "net", "org", "gov", "ac", "edu"]

# Slot index -> block coordinates, a square spiral from the centre.
static func spiral(i: int) -> Vector2i:
    if i <= 0:
        return Vector2i.ZERO
    var r := int(ceil((sqrt(float(i + 1)) - 1.0) / 2.0))
    var side := 2 * r
    var k := i - (2 * r - 1) * (2 * r - 1)
    var edge := k / side
    var o := k % side
    match edge:
        0:
            return Vector2i(r, -r + 1 + o)
        1:
            return Vector2i(r - 1 - o, r)
        2:
            return Vector2i(-r, r - 1 - o)
    return Vector2i(-r + 1 + o, -r)

# "api.github.com:443" -> ["api.github.com", 443]; "example.org" -> ["example.org", -1].
# The port is what follows the last ":" when it is all digits; an address with more
# than one ":" and no "]" is an IPv6 literal without a port.
static func split_address(address: String) -> Array:
    var text := address.strip_edges().to_lower()
    if text.begins_with("[") and text.contains("]"):
        var close := text.find("]")
        var inner := text.substr(1, close - 1)
        var rest := text.substr(close + 1)
        if rest.begins_with(":") and rest.substr(1).is_valid_int():
            return [inner, int(rest.substr(1))]
        return [inner, -1]
    if text.count(":") > 1:
        return [text, -1]
    var cut := text.rfind(":")
    if cut >= 0:
        var tail := text.substr(cut + 1)
        if tail != "" and tail.is_valid_int() and not tail.begins_with("-") and not tail.begins_with("+"):
            return [text.substr(0, cut), int(tail)]
    return [text, -1]

static func _ipv4(host: String) -> PackedInt32Array:
    var out := PackedInt32Array()
    var parts := host.split(".")
    if parts.size() != 4:
        return out
    for p in parts:
        if p == "" or not p.is_valid_int() or p.begins_with("-") or p.begins_with("+") or p.length() > 3:
            return PackedInt32Array()
        var n := int(p)
        if n < 0 or n > 255:
            return PackedInt32Array()
        out.append(n)
    return out

# The contract's block rule, the simple name rule (no Public Suffix List here).
static func block_of(host: String) -> String:
    var h := host.to_lower()
    var v4 := _ipv4(h)
    if v4.size() == 4:
        return "%d.%d.0.0/16" % [v4[0], v4[1]]
    if h.contains(":"):
        return h
    var labels := h.split(".")
    if labels.size() <= 1:
        return h
    var n := 2
    if labels[labels.size() - 1].length() == 2 and labels.size() >= 3 and SECOND_LEVEL.has(labels[labels.size() - 2]):
        n = 3
    return ".".join(labels.slice(labels.size() - n))

static func is_private_ipv4(host: String) -> bool:
    var v := _ipv4(host)
    if v.size() != 4:
        return false
    if v[0] == 10:
        return true
    if v[0] == 172 and v[1] >= 16 and v[1] <= 31:
        return true
    if v[0] == 192 and v[1] == 168:
        return true
    return v[0] == 169 and v[1] == 254

# Matrix rows -> host rows. Ports of one host are merged: numbers add, "untunnelled"
# is true if any is. Sorted by count descending then host; cut to MAX_TOWERS.
static func hosts_from_matrix(rows: Array) -> Array:
    var by_host := {}
    for row in rows:
        if typeof(row) != TYPE_DICTIONARY:
            continue
        var parts := split_address(str(row.get("address", "")))
        var host: String = parts[0]
        if host == "":
            continue
        var port: int = parts[1]
        if not by_host.has(host):
            by_host[host] = {
                "host": host, "block": block_of(host), "ports": [],
                "sent": 0, "received": 0, "count": 0, "open": 0, "blocked": 0,
                "untunnelled": false,
                "scope": "lan" if is_private_ipv4(host) else "",
                "first_seen_ago": 0, "last_seen_ago": 0,
                "clients": [], "tools": [], "services": [],
            }
        var h: Dictionary = by_host[host]
        h["sent"] += int(row.get("sent", 0))
        h["received"] += int(row.get("received", 0))
        h["count"] += int(row.get("count", 0))
        h["blocked"] += int(row.get("blocked", 0))
        if bool(row.get("untunnelled", false)):
            h["untunnelled"] = true
        if port >= 0 and not h["ports"].has(port):
            h["ports"].append(port)
    var out: Array = by_host.values()
    for h in out:
        h["ports"].sort()
    out.sort_custom(func(a, b):
        if a["count"] != b["count"]:
            return a["count"] > b["count"]
        return a["host"] < b["host"])
    if out.size() > MAX_TOWERS:
        out.resize(MAX_TOWERS)
    return out

# Link rows (/v1/links: source, target, sent, received, count, open, blocked,
# last_seen_ago) whose target has a tower, in the order given.
static func links_for(links: Array, hosts: Array) -> Array:
    var present := {}
    for h in hosts:
        present[h["host"]] = true
    var out := []
    for l in links:
        if typeof(l) == TYPE_DICTIONARY and present.has(str(l.get("target", ""))) and str(l.get("source", "")) != "":
            out.append(l)
    return out

# The distinct sources of some links, ascending (a stable order for the home chips);
# `fallback` alone when there are none.
static func sources_of(links: Array, fallback: String) -> Array:
    var seen := {}
    for l in links:
        seen[str(l["source"])] = true
    var out: Array = seen.keys()
    out.sort()
    return out if not out.is_empty() else [fallback]

# What the Matrix feed gives in place of links: one link per host, from `home`.
static func links_from_hosts(hosts: Array, home: String) -> Array:
    var out := []
    for h in hosts:
        out.append({
            "source": home, "target": h["host"], "sent": h["sent"], "received": h["received"],
            "count": h["count"], "open": h["open"], "blocked": h["blocked"],
            "last_seen_ago": h["last_seen_ago"],
        })
    return out

# How bright a tower's glass is: 0.35 (quiet) to 1.0 (reached now).
static func brightness_of(row: Dictionary) -> float:
    var activity := clampf(1.0 - float(row.get("last_seen_ago", 0)) / 30.0, 0.0, 1.0)
    return 0.35 + 0.65 * activity

# Seconds between a link's cars; a link quiet for over a minute with nothing open sends none (-1).
static func car_interval(link: Dictionary) -> float:
    var ago := float(link.get("last_seen_ago", 0))
    if ago > 60.0 and int(link.get("open", 0)) <= 0:
        return -1.0
    var count := float(link.get("count", 1))
    return clampf(6.0 / (1.0 + log(1.0 + count)), 0.4, 6.0) * (1.0 + ago / 10.0)

# "blocked" | "untunnelled" | "local" | "normal"; the first that matches.
static func tone_of(row: Dictionary) -> String:
    var count := int(row.get("count", 0))
    if count > 0 and int(row.get("blocked", 0)) >= count:
        return "blocked"
    if bool(row.get("untunnelled", false)):
        return "untunnelled"
    var scope := str(row.get("scope", ""))
    if scope == "local" or scope == "lan":
        return "local"
    return "normal"

static func new_placement() -> Dictionary:
    return {"blocks": {}, "lots": {}, "home": {}}

# placement = {"blocks": {block_id: slot}, "lots": {host: {"block": id, "lot": n}}, "home": {source: lot}}
# Changed in place, by the rules of "Who stands where": a host that stays keeps its
# lot; a host that leaves frees it; a block with no hosts gives up its slot.
static func place(placement: Dictionary, hosts: Array, sources: Array) -> void:
    var blocks: Dictionary = placement["blocks"]
    var lots: Dictionary = placement["lots"]
    var home: Dictionary = placement["home"]

    # The home block: the lowest free lot per source, in order, at most 16.
    var wanted := []
    for s in sources:
        if not wanted.has(str(s)):
            wanted.append(str(s))
    if wanted.is_empty() or (wanted.size() == 1 and wanted[0] == "LOCAL"):
        wanted = ["LOCAL"]
        if not home.has("LOCAL"):
            home.clear()
            home["LOCAL"] = HOME_DEFAULT_LOT
    for s in home.keys():
        if not wanted.has(s):
            home.erase(s)
    var used_home := {}
    for s in home:
        used_home[int(home[s])] = true
    for s in wanted:
        if home.has(s):
            continue
        var lot := LOTS_PER_BLOCK - 1
        for j in range(LOTS_PER_BLOCK):
            if not used_home.has(j):
                lot = j
                break
        home[s] = lot
        used_home[lot] = true

    # Hosts that left.
    var present := {}
    for h in hosts:
        present[h["host"]] = true
    for host in lots.keys():
        if not present.has(host):
            lots.erase(host)

    # Occupancy by block id.
    var used := {}
    for host in lots:
        var entry: Dictionary = lots[host]
        if not used.has(entry["block"]):
            used[entry["block"]] = {}
        used[entry["block"]][int(entry["lot"])] = true
    for id in blocks.keys():
        if not used.has(id):
            blocks.erase(id)

    for h in hosts:
        var host: String = h["host"]
        if lots.has(host):
            continue
        var base: String = str(h.get("block", block_of(host)))
        var n := 1
        while true:
            var id := base if n == 1 else "%s#%d" % [base, n]
            if not blocks.has(id):
                var slot := 1
                var taken := {}
                for v in blocks.values():
                    taken[int(v)] = true
                while taken.has(slot):
                    slot += 1
                blocks[id] = slot
                used[id] = {0: true}
                lots[host] = {"block": id, "lot": 0}
                break
            var occupied: Dictionary = used.get(id, {})
            var free := -1
            for j in range(LOTS_PER_BLOCK):
                if not occupied.has(j):
                    free = j
                    break
            if free >= 0:
                occupied[free] = true
                used[id] = occupied
                lots[host] = {"block": id, "lot": free}
                break
            n += 1

static func _lot_point(slot: Vector2i, lot: int) -> Vector2:
    var lx := lot % BLOCK_LOTS
    var lz := lot / BLOCK_LOTS
    return Vector2(
        slot.x * BLOCK_PITCH + (lx - 1.5) * LOT,
        slot.y * BLOCK_PITCH + (lz - 1.5) * LOT)

# x, z of a tower's centre; the home block's centre when the host is unplaced.
static func tower_position(placement: Dictionary, host: String) -> Vector2:
    var lots: Dictionary = placement["lots"]
    if not lots.has(host):
        return Vector2.ZERO
    var entry: Dictionary = lots[host]
    return _lot_point(spiral(int(placement["blocks"].get(entry["block"], 0))), int(entry["lot"]))

static func chip_position(placement: Dictionary, source: String) -> Vector2:
    return _lot_point(Vector2i.ZERO, int(placement["home"].get(source, HOME_DEFAULT_LOT)))

# The half-size of the square holding every block and the home block; at least 24.
static func extent_of(placement: Dictionary) -> float:
    var e := 24.0
    for slot in placement["blocks"].values():
        var s := spiral(int(slot))
        e = maxf(e, maxf(absf(s.x), absf(s.y)) * BLOCK_PITCH + BLOCK_PITCH * 0.5)
    return e

# {host: {"height": float, "side": float}}, by the design's formula.
static func tower_sizes(hosts: Array) -> Dictionary:
    var any_bytes := false
    var vmax := 0.0
    var cmax := 0.0
    for h in hosts:
        if float(h["sent"]) + float(h["received"]) > 0.0:
            any_bytes = true
        cmax = maxf(cmax, float(h["count"]))
    var values := {}
    for h in hosts:
        var v: float = (float(h["sent"]) + float(h["received"])) if any_bytes else float(h["count"])
        values[h["host"]] = v
        vmax = maxf(vmax, v)
    var out := {}
    for h in hosts:
        var norm := 0.0 if vmax <= 0.0 else log(1.0 + values[h["host"]]) / log(1.0 + vmax)
        var side := 1.2
        if cmax > 0.0:
            side += 0.8 * log(1.0 + float(h["count"])) / log(1.0 + cmax)
        out[h["host"]] = {"height": 2.0 + 34.0 * norm, "side": side}
    return out

static func _street(v: float) -> float:
    return BLOCK_PITCH * roundf((v - 8.0) / BLOCK_PITCH) + 8.0

# From (x, z) to (x, z) along the streets; every segment is axis-aligned.
static func route_of(from: Vector2, to: Vector2) -> PackedVector2Array:
    var zs := _street(from.y)
    var xs := _street(to.x)
    var zt := _street(to.y)
    var raw := [from, Vector2(from.x, zs), Vector2(xs, zs), Vector2(xs, zt), Vector2(to.x, zt), to]
    var out := PackedVector2Array()
    for p in raw:
        if out.is_empty() or out[out.size() - 1] != p:
            out.append(p)
    return out

static func format_bytes(n: float) -> String:
    if n < 1024.0:
        return "%dB" % int(n)
    var units := ["K", "M", "G"]
    var v := n
    var i := -1
    while v >= 1024.0 and i < 2:
        v /= 1024.0
        i += 1
    return "%.1f%s" % [v, units[i]]

static func format_ago(seconds: float) -> String:
    var s := int(maxf(seconds, 0.0))
    if s < 60:
        return "%dS" % s
    if s < 3600:
        return "%dM" % (s / 60)
    if s < 86400:
        return "%dH" % (s / 3600)
    return "%dD" % (s / 86400)

static func _join(items: Array) -> String:
    var parts := PackedStringArray()
    for i in items:
        parts.append(str(i))
    return " ".join(parts)

# The lines of a tower's faces, upper-case, at most 24 characters each, ending with
# the two blank lines that separate one repeat of the page from the next.
static func page_of(row: Dictionary, log_lines: PackedStringArray = PackedStringArray()) -> PackedStringArray:
    var lines := PackedStringArray()
    var host := str(row.get("host", "")).to_upper()
    if host == "":
        host = "-"
    var i := 0
    while i < host.length():
        lines.append(host.substr(i, 24))
        i += 24
    lines.append("")
    var ports: Array = row.get("ports", [])
    if not ports.is_empty():
        lines.append(("PORT " + _join(ports)).substr(0, 24))
    lines.append("COUNT %d" % int(row.get("count", 0)))
    if int(row.get("open", 0)) > 0:
        lines.append("OPEN %d" % int(row.get("open", 0)))
    lines.append("UP " + format_bytes(float(row.get("sent", 0))))
    lines.append("DOWN " + format_bytes(float(row.get("received", 0))))
    var scope := str(row.get("scope", ""))
    if scope != "":
        lines.append(("SCOPE " + scope.to_upper()).substr(0, 24))
    if int(row.get("blocked", 0)) > 0:
        lines.append("REFUSED %d" % int(row.get("blocked", 0)))
    for s in row.get("services", []):
        lines.append(("VIA " + str(s).to_upper()).substr(0, 24))
    for t in row.get("tools", []):
        lines.append(("TOOL " + str(t).to_upper()).substr(0, 24))
    for c in row.get("clients", []):
        lines.append(("FROM " + str(c).to_upper()).substr(0, 24))
    lines.append("SEEN %s AGO" % format_ago(float(row.get("last_seen_ago", 0))))
    # A selected tower's log goes on after SEEN, as many lines as the page can hold.
    var room := GibsonFont.MAX_PAGE_ROWS - lines.size() - 2
    for n in range(mini(log_lines.size(), maxi(room, 0))):
        lines.append(log_lines[n])
    lines.append("")
    lines.append("")
    return lines

# A stable value in [0, 1).
static func hash01(text: String) -> float:
    return float(text.hash() & 0xFFFFFF) / 16777216.0

# ---- selection, the log and the menu --------------------------------------------

const MAX_LOG_LINES := 40
const MAX_MENU_ITEMS := 12
const MAX_MENU_BOXES := 4
const TITLE_CHARS := 22

# A host a viewer may select: it goes into a request's URL.
static func valid_host(host: String) -> bool:
    var re := RegEx.new()
    re.compile("^[a-z0-9._:\\[\\]/-]{1,255}\\z")
    return re.search(host) != null

# The index of the nearest box the ray enters, or -1. boxes: Array of {"min": Vector3, "max": Vector3}.
static func pick_box(origin: Vector3, direction: Vector3, boxes: Array) -> int:
    var best := -1
    var best_t := INF
    for i in range(boxes.size()):
        var lo: Vector3 = boxes[i]["min"]
        var hi: Vector3 = boxes[i]["max"]
        var t_min := 0.0
        var t_max := INF
        var hit := true
        for axis in range(3):
            var o: float = origin[axis]
            var d: float = direction[axis]
            if absf(d) < 1.0e-9:
                if o < lo[axis] or o > hi[axis]:
                    hit = false
                    break
                continue
            var t1: float = (lo[axis] - o) / d
            var t2: float = (hi[axis] - o) / d
            t_min = maxf(t_min, minf(t1, t2))
            t_max = minf(t_max, maxf(t1, t2))
            if t_min > t_max:
                hit = false
                break
        if hit and t_min < best_t:
            best_t = t_min
            best = i
    return best

# The index of the rectangle (in the z = 0 plane of the ray's own space) the ray crosses, or -1.
static func pick_rect(origin: Vector3, direction: Vector3, rects: Array) -> int:
    if absf(direction.z) < 1.0e-9:
        return -1
    var t := -origin.z / direction.z
    if t < 0.0:
        return -1
    var at := origin + direction * t
    for i in range(rects.size()):
        if (rects[i] as Rect2).has_point(Vector2(at.x, at.y)):
            return i
    return -1

# The unit vector (x, z) of the side of a tower a viewer at `from` faces: the axis the
# viewer is further along.
static func face_normal(from: Vector2, tower: Vector2) -> Vector2:
    var d := from - tower
    if absf(d.x) >= absf(d.y):
        return Vector2(1.0 if d.x >= 0.0 else -1.0, 0.0)
    return Vector2(0.0, 1.0 if d.y >= 0.0 else -1.0)

# Where the camera goes to look at a tower: 9 units out from the face nearest the viewer,
# eye at min(height * 0.6, 10), looking at the tower at that height.
static func fly_pose(tower: Vector2, side: float, height: float, from: Vector2) -> Dictionary:
    var n := face_normal(from, tower)
    var eye := tower + n * (side * 0.5 + 9.0)
    var y := minf(height * 0.6, 10.0)
    return {"eye": Vector3(eye.x, y, eye.y), "target": Vector3(tower.x, y, tower.y)}

static func _text(row: Dictionary, key: String) -> String:
    var v = row.get(key)
    return "" if v == null else str(v)

static func port_of(row: Dictionary) -> int:
    var v = row.get("port")
    if (typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT) and int(v) > 0:
        return int(v)
    return -1

# OK, LIVE, REFUSED, or the state's own name, upper-case.
static func state_word(row: Dictionary) -> String:
    if bool(row.get("blocked", false)):
        return "REFUSED"
    var state := _text(row, "state").to_lower()
    if state == "finished":
        return "OK"
    if state == "active" or state == "pooled":
        return "LIVE"
    return state.to_upper() if state != "" else "-"

static func clock_text(unix_time: float, bias_seconds: int) -> String:
    var d := Time.get_time_dict_from_unix_time(int(unix_time) + bias_seconds)
    return "%02d:%02d:%02d" % [d["hour"], d["minute"], d["second"]]

# Newest first (smallest `ago`; rows without one keep their order after those with).
static func newest_first(log: Array) -> Array:
    var out := log.duplicate()
    out.sort_custom(func(a, b): return float(a.get("ago", 1.0e12)) < float(b.get("ago", 1.0e12)))
    return out

# The log rows of one host, from an answer that may hold every host's.
static func log_of(host: String, rows: Array) -> Array:
    var out := []
    for r in rows:
        if typeof(r) == TYPE_DICTIONARY and str(r.get("host", "")) == host:
            out.append(r)
    return out

# `HH:MM:SS <PORT> <STATE>`, newest first, at most 40.
static func log_lines(log: Array, bias_seconds: int) -> PackedStringArray:
    var out := PackedStringArray()
    for r in newest_first(log):
        if out.size() >= MAX_LOG_LINES:
            break
        var port := port_of(r)
        var stamp := clock_text(float(r["time"]), bias_seconds) if r.has("time") and r["time"] != null else "--:--:--"
        out.append(("%s %s %s" % [stamp, str(port) if port > 0 else "-", state_word(r)]).substr(0, 24))
    return out

# [{ "key": String, "label": String, "rows": Array }], busiest first, at most 12.
static func menu_of(log: Array) -> Array:
    var groups := {}
    for r in newest_first(log):
        var port := port_of(r)
        var tail := _text(r, "via")
        if tail == "":
            tail = _text(r, "source")
        var label := str(port) if port > 0 else "-"
        if tail != "":
            label += " " + tail.to_upper()
        if not groups.has(label):
            groups[label] = {"key": label, "label": label, "rows": []}
        groups[label]["rows"].append(r)
    var out: Array = groups.values()
    out.sort_custom(func(a, b):
        if a["rows"].size() != b["rows"].size():
            return a["rows"].size() > b["rows"].size()
        return a["label"] < b["label"])
    if out.size() > MAX_MENU_ITEMS:
        out.resize(MAX_MENU_ITEMS)
    return out

# The path of a URL, cut: "https://h.org/a/b?q=1" -> "/a/b?q=1".
static func path_of(url: String) -> String:
    var rest := url
    var scheme := rest.find("://")
    if scheme >= 0:
        rest = rest.substr(scheme + 3)
    var slash := rest.find("/")
    return rest.substr(slash) if slash >= 0 else "/"

# { "title": String, "caption": String, "blocked": bool } for one log row.
static func box_of(row: Dictionary, bias_seconds: int = 0) -> Dictionary:
    var url := _text(row, "url")
    var title: String
    if url != "":
        title = (_text(row, "method") + " " + path_of(url)).strip_edges()
    elif _text(row, "label") != "":
        title = _text(row, "label")
    elif row.has("time") and row["time"] != null:
        title = clock_text(float(row["time"]), bias_seconds)
    else:
        title = "-"
    title = title.to_upper().substr(0, TITLE_CHARS)
    var blocked := bool(row.get("blocked", false))
    var caption: String
    if blocked:
        caption = ("REFUSED " + _text(row, "rule")).strip_edges().to_upper()
    else:
        caption = "%s %s %s" % [state_word(row), format_bytes(float(row.get("sent", 0))), format_bytes(float(row.get("received", 0)))]
    return {"title": title, "caption": caption, "blocked": blocked}

# The header's totals line.
static func totals_of(row: Dictionary) -> String:
    var parts := PackedStringArray()
    parts.append("%d CONNECTIONS" % int(row.get("count", 0)))
    parts.append(format_bytes(float(row.get("sent", 0))) + " UP")
    parts.append(format_bytes(float(row.get("received", 0))) + " DOWN")
    if int(row.get("blocked", 0)) > 0:
        parts.append("%d REFUSED" % int(row.get("blocked", 0)))
    if bool(row.get("untunnelled", false)):
        parts.append("OUTSIDE THE TUNNEL")
    return " · ".join(parts)
