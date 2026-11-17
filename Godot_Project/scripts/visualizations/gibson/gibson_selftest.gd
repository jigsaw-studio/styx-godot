extends SceneTree

# Checks of GibsonLayout. Run from Godot_Project:
#   "$GODOT" --headless --path . --script res://scripts/visualizations/gibson/gibson_selftest.gd

var failures := 0

func check(ok: bool, what: String) -> void:
    if not ok:
        failures += 1
        print("FAIL: ", what)

func row(host: String, count: int = 1, sent: int = 0, received: int = 0, block: String = "") -> Dictionary:
    return {
        "host": host, "block": block if block != "" else GibsonLayout.block_of(host), "ports": [443],
        "sent": sent, "received": received, "count": count, "open": 0, "blocked": 0,
        "untunnelled": false, "scope": "", "first_seen_ago": 0, "last_seen_ago": 0,
        "clients": [], "tools": [], "services": [],
    }

func _init() -> void:
    var L := GibsonLayout

    # The spiral.
    var vectors := {
        0: Vector2i(0, 0), 1: Vector2i(1, 0), 2: Vector2i(1, 1), 3: Vector2i(0, 1),
        4: Vector2i(-1, 1), 5: Vector2i(-1, 0), 6: Vector2i(-1, -1), 7: Vector2i(0, -1),
        8: Vector2i(1, -1), 9: Vector2i(2, -1), 12: Vector2i(2, 2), 13: Vector2i(1, 2),
        16: Vector2i(-2, 2), 17: Vector2i(-2, 1), 20: Vector2i(-2, -2), 21: Vector2i(-1, -2),
        24: Vector2i(2, -2),
    }
    for i in vectors:
        check(L.spiral(i) == vectors[i], "spiral(%d) = %s, wanted %s" % [i, L.spiral(i), vectors[i]])
    var seen := {}
    var distinct := true
    for i in range(200):
        var s: Vector2i = L.spiral(i)
        if seen.has(s):
            distinct = false
        seen[s] = true
    check(distinct, "spiral gives 200 distinct slots")

    # Addresses.
    check(L.split_address("a.b:443") == ["a.b", 443], "split a.b:443")
    check(L.split_address("a.b") == ["a.b", -1], "split a.b")
    check(L.split_address("10.0.0.1:80") == ["10.0.0.1", 80], "split 10.0.0.1:80")
    check(L.split_address("fe80::1") == ["fe80::1", -1], "split fe80::1")
    check(L.split_address("[fe80::1]:443") == ["fe80::1", 443], "split [fe80::1]:443")
    check(L.split_address("A.B:443") == ["a.b", 443], "split lower-cases")

    # Blocks.
    check(L.block_of("165.1.213.8") == "165.1.0.0/16", "block of an IPv4 literal")
    check(L.block_of("api.github.com") == "github.com", "block of api.github.com")
    check(L.block_of("www.bbc.co.uk") == "bbc.co.uk", "block of www.bbc.co.uk")
    check(L.block_of("localhost") == "localhost", "block of localhost")
    check(L.block_of("a.b.example.com") == "example.com", "block of a.b.example.com")
    check(L.block_of("fe80::1") == "fe80::1", "block of an IPv6 literal")
    check(L.is_private_ipv4("172.31.0.1") and not L.is_private_ipv4("172.32.0.1"), "172.16/12 edge")
    check(L.is_private_ipv4("192.168.1.1") and L.is_private_ipv4("169.254.169.254") and L.is_private_ipv4("10.1.2.3"), "private ranges")
    check(not L.is_private_ipv4("api.github.com") and not L.is_private_ipv4("165.1.213.8"), "not private")

    # Matrix rows -> host rows.
    var merged := L.hosts_from_matrix([
        {"address": "x.org:443", "sent": 10, "received": 100, "count": 3, "blocked": 0, "untunnelled": false},
        {"address": "x.org:80", "sent": 5, "received": 50, "count": 2, "blocked": 1, "untunnelled": true},
        {"address": "10.0.0.12:22", "count": 9},
        {"address": "y.org", "count": 3},
    ])
    check(merged.size() == 3, "hosts_from_matrix merges ports into 3 hosts")
    check(merged[0]["host"] == "10.0.0.12" and merged[0]["scope"] == "lan", "busiest first, private is lan")
    check(merged[1]["host"] == "x.org" and merged[1]["count"] == 5 and merged[1]["sent"] == 15 and merged[1]["received"] == 150, "x.org numbers add")
    check(merged[1]["ports"] == [80, 443] and merged[1]["untunnelled"] == true and merged[1]["blocked"] == 1, "x.org ports and flags")
    check(merged[2]["host"] == "y.org" and merged[2]["ports"] == [], "ties by host, no port")
    var many := []
    for i in range(200):
        many.append({"address": "h%d.example.org:443" % i, "count": 1})
    check(L.hosts_from_matrix(many).size() == L.MAX_TOWERS, "cut to MAX_TOWERS")
    check(L.hosts_from_matrix([]).is_empty(), "empty in, empty out")

    # Tone.
    var t := row("a.org", 4)
    check(L.tone_of(t) == "normal", "tone normal")
    t["blocked"] = 4
    t["untunnelled"] = true
    check(L.tone_of(t) == "blocked", "tone blocked beats untunnelled")
    t["blocked"] = 2
    check(L.tone_of(t) == "untunnelled", "tone untunnelled")
    t["untunnelled"] = false
    t["scope"] = "lan"
    check(L.tone_of(t) == "local", "tone local")
    t["scope"] = "tunnelled"
    check(L.tone_of(t) == "normal", "partly refused is still normal")

    # Placement.
    var p := L.new_placement()
    var hs := [row("a.github.com", 9), row("b.github.com", 8), row("c.example.org", 7)]
    L.place(p, hs, [])
    check(p["blocks"]["github.com"] == 1 and p["blocks"]["example.org"] == 2, "first block gets slot 1")
    check(p["home"] == {"LOCAL": 5}, "no sources: LOCAL on lot 5")
    check(p["lots"]["a.github.com"]["lot"] == 0 and p["lots"]["b.github.com"]["lot"] == 1, "lots fill from 0")
    var before: Dictionary = p["lots"]["b.github.com"].duplicate()
    hs[1]["count"] = 99
    hs.reverse()
    L.place(p, hs, ["LOCAL"])
    check(p["lots"]["b.github.com"] == before, "a host that stays keeps its lot")
    # A 17th host of one block opens #2.
    var q := L.new_placement()
    var big := []
    for i in range(17):
        big.append(row("h%02d.big.org" % i, 100 - i))
    L.place(q, big, [])
    check(q["lots"]["h16.big.org"]["block"] == "big.org#2" and q["blocks"].has("big.org#2") and q["blocks"]["big.org#2"] == 2, "17th host opens #2")
    # A host that leaves frees its lot for the next.
    var freed := big.slice(0, 17)
    freed.remove_at(3)
    freed.append(row("late.big.org", 1))
    L.place(q, freed, [])
    check(q["lots"]["late.big.org"] == {"block": "big.org", "lot": 3}, "a freed lot is reused")
    check(not q["lots"].has("h03.big.org"), "the host that left is gone")
    # A block with no hosts gives up its slot.
    L.place(p, [row("a.github.com", 9)], ["LOCAL"])
    check(not p["blocks"].has("example.org") and p["blocks"].has("github.com"), "an empty block gives up its slot")
    L.place(p, [row("a.github.com", 9), row("z.new.org", 1)], ["LOCAL"])
    check(p["blocks"]["new.org"] == 2, "a freed slot is taken again")
    # Sources.
    var r := L.new_placement()
    L.place(r, [], ["harness", "llm-auth"])
    check(r["home"] == {"harness": 0, "llm-auth": 1}, "sources take the lowest lots in order")
    var pos: Vector2 = L.chip_position(r, "llm-auth")
    check(is_equal_approx(pos.x, (1 - 1.5) * 3.0) and is_equal_approx(pos.y, -4.5), "chip position of lot 1")
    var tp: Vector2 = L.tower_position(p, "a.github.com")
    check(is_equal_approx(tp.x, 16.0 + (0 - 1.5) * 3.0) and is_equal_approx(tp.y, (0 - 1.5) * 3.0), "tower position of slot 1 lot 0")

    # Sizes.
    var sized := L.tower_sizes([row("a.org", 100, 1000, 9000), row("b.org", 1, 10, 0), row("c.org", 3, 0, 0)])
    for h in sized.values():
        check(h["height"] >= 2.0 and h["height"] <= 36.0 and h["side"] >= 1.2 and h["side"] <= 2.0, "size within bounds: %s" % [h])
    check(is_equal_approx(sized["a.org"]["height"], 36.0) and is_equal_approx(sized["a.org"]["side"], 2.0), "the largest is 36 by 2.0")
    var by_count := L.tower_sizes([row("a.org", 100), row("b.org", 10)])
    check(by_count["a.org"]["height"] > by_count["b.org"]["height"], "counts size towers when all bytes are 0")
    check(L.tower_sizes([]).is_empty(), "no hosts, no sizes")
    check(L.tower_sizes([row("z.org", 0)])["z.org"]["height"] == 2.0, "vmax 0 gives the lowest tower")

    # Routes.
    var routes := [
        [Vector2(-4.5, -4.5), Vector2(17.5, -3.0)],
        [Vector2(1.5, 1.5), Vector2(-40.0, 37.5)],
        [Vector2(-1.5, 4.5), Vector2(-1.5, 4.5)],
    ]
    for pair in routes:
        var path: PackedVector2Array = L.route_of(pair[0], pair[1])
        var axis := true
        for i in range(path.size() - 1):
            if path[i].x != path[i + 1].x and path[i].y != path[i + 1].y:
                axis = false
            if path[i] == path[i + 1]:
                axis = false
        check(axis and path[0] == pair[0] and path[path.size() - 1] == pair[1], "route %s is axis-aligned from end to end: %s" % [pair, path])

    # Words and pages.
    check(L.format_bytes(512) == "512B" and L.format_bytes(5217) == "5.1K" and L.format_bytes(2.0 * 1024 * 1024) == "2.0M", "format_bytes")
    check(L.format_ago(3) == "3S" and L.format_ago(240) == "4M" and L.format_ago(7300) == "2H" and L.format_ago(5 * 86400) == "5D", "format_ago")
    var page_row := row("a-very-long-host-name-that-wraps.example.org", 14, 5217, 90329)
    page_row["open"] = 1
    page_row["blocked"] = 3
    page_row["scope"] = "tunnelled"
    page_row["services"] = ["proxy"]
    page_row["tools"] = ["web_fetch"]
    page_row["clients"] = ["harness"]
    var page: PackedStringArray = L.page_of(page_row)
    var ok := page.size() > 10
    for line in page:
        if line != line.to_upper() or line.length() > 24:
            ok = false
    check(ok, "page lines are upper-case and at most 24 characters: %s" % [page])
    check(page.has("REFUSED 3") and page.has("OPEN 1") and page.has("UP 5.1K") and page.has("VIA PROXY") and page.has("TOOL WEB_FETCH") and page.has("FROM HARNESS") and page.has("SCOPE TUNNELLED"), "page holds the lines")
    var plain: PackedStringArray = L.page_of(row("b.org", 2))
    check(not plain.has("OPEN 0") and not "REFUSED 0" in plain and plain[plain.size() - 1] == "", "page leaves out what is absent")

    # Hash.
    var hv := L.hash01("x")
    check(hv >= 0.0 and hv < 1.0 and hv == L.hash01("x") and L.hash01("x") != L.hash01("y"), "hash01")

    print("gibson selftest: %d failure(s)" % failures)
    quit(1 if failures > 0 else 0)
