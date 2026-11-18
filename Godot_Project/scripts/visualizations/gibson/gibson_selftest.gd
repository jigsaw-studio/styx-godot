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

    # Links and sources.
    var link_rows := [
        {"source": "llm-auth", "target": "a.org", "count": 2}, {"source": "harness", "target": "a.org", "count": 5},
        {"source": "harness", "target": "gone.org", "count": 1}, {"source": "harness", "target": "b.org", "count": 1},
    ]
    var kept: Array = L.links_for(link_rows, [row("a.org"), row("b.org")])
    check(kept.size() == 3 and kept[0]["source"] == "llm-auth", "links to hosts without towers are dropped")
    check(L.sources_of(kept, "LOCAL") == ["harness", "llm-auth"], "sources, ascending, distinct")
    check(L.sources_of([], "LOCAL") == ["LOCAL"], "no links: the fallback source")
    var s17 := L.new_placement()
    var seventeen := []
    for i in range(17):
        seventeen.append("src%02d" % i)
    L.place(s17, [], seventeen)
    check(s17["home"]["src15"] == 15 and s17["home"]["src16"] == 15, "a 17th source shares lot 15")
    var s2 := L.new_placement()
    L.place(s2, [], ["harness", "llm-auth"])
    L.place(s2, [], ["harness", "llm-auth", "aaa"])
    check(s2["home"]["harness"] == 0 and s2["home"]["llm-auth"] == 1 and s2["home"]["aaa"] == 2, "sources keep their lots when another arrives")
    var from_hosts: Array = L.links_from_hosts([row("a.org", 4, 10, 20)], "LOCAL")
    check(from_hosts.size() == 1 and from_hosts[0]["source"] == "LOCAL" and from_hosts[0]["target"] == "a.org" and from_hosts[0]["count"] == 4, "one link per host from LOCAL")
    var busy := row("a.org")
    var quiet := row("b.org")
    quiet["last_seen_ago"] = 30
    var older := row("c.org")
    older["last_seen_ago"] = 600
    check(is_equal_approx(L.brightness_of(busy), 1.0) and is_equal_approx(L.brightness_of(quiet), 0.35) and L.brightness_of(older) == L.brightness_of(quiet), "brightness runs 0.35 to 1.0")
    check(L.car_interval({"count": 1, "last_seen_ago": 61, "open": 0}) < 0.0, "a link quiet over a minute sends none")
    check(L.car_interval({"count": 1, "last_seen_ago": 61, "open": 1}) > 0.0, "unless a connection is open")
    check(is_equal_approx(L.car_interval({"count": 0, "last_seen_ago": 0}), 6.0), "interval of an unseen link is 6 s")

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

    # Picking.
    var two := [
        {"min": Vector3(-1, 0, 4), "max": Vector3(1, 10, 6)},
        {"min": Vector3(-1, 0, 8), "max": Vector3(1, 10, 10)},
    ]
    check(L.pick_box(Vector3(0, 5, 0), Vector3(0, 0, 1), two) == 0, "pick_box: the nearer of two in line")
    check(L.pick_box(Vector3(0, 5, 20), Vector3(0, 0, -1), two) == 1, "pick_box: from the other side, the other is nearer")
    check(L.pick_box(Vector3(3, 5, 0), Vector3(0, 0, 1), two) == -1, "pick_box: a miss beside")
    check(L.pick_box(Vector3(0, 30, 5), Vector3(0, -1, 0), two) == 0, "pick_box: a hit from above")
    check(L.pick_box(Vector3(0, 5, 0), Vector3(0, 0, -1), two) == -1, "pick_box: boxes behind the ray are not hit")
    check(L.pick_rect(Vector3(0.5, 0.5, 3), Vector3(0, 0, -1), [Rect2(-1, -1, 1, 1), Rect2(0, 0, 1, 1)]) == 1, "pick_rect: the rectangle crossed")
    check(L.pick_rect(Vector3(5, 5, 3), Vector3(0, 0, -1), [Rect2(0, 0, 1, 1)]) == -1, "pick_rect: a miss")
    check(L.pick_rect(Vector3(0.5, 0.5, 3), Vector3(0, 0, 1), [Rect2(0, 0, 1, 1)]) == -1, "pick_rect: behind the ray")
    check(L.face_normal(Vector2(20, 3), Vector2(0, 0)) == Vector2(1, 0) and L.face_normal(Vector2(1, -9), Vector2(0, 0)) == Vector2(0, -1), "face_normal: the axis the viewer is further along")
    var fp: Dictionary = L.fly_pose(Vector2(10, 10), 2.0, 30.0, Vector2(10, 100))
    check(fp["eye"] == Vector3(10, 10, 20) and fp["target"] == Vector3(10, 10, 10), "fly_pose: 9 out from the face, at min(0.6 h, 10)")
    check(L.fly_pose(Vector2.ZERO, 2.0, 5.0, Vector2(-50, 0))["eye"].y == 3.0, "fly_pose: a short tower is looked at at 0.6 of its height")
    check(L.valid_host("api.github.com") and L.valid_host("[fe80::1]") and L.valid_host("10.0.0.1:80"), "valid_host: names and literals")
    check(not L.valid_host("a b") and not L.valid_host("a?b=1") and not L.valid_host("") and not L.valid_host("A.org") and not L.valid_host("x".repeat(256)), "valid_host: refuses what does not belong in a URL")

    # The log and the menu.
    var rows := [
        {"host": "a.org", "time": 100000, "ago": 30, "source": "harness", "via": "proxy", "port": 443, "sent": 100, "received": 2048, "state": "finished", "blocked": false, "rule": null, "method": "GET", "url": "https://a.org/path/0", "label": null},
        {"host": "a.org", "time": 100030, "ago": 0, "source": "harness", "via": "proxy", "port": 443, "sent": 0, "received": 0, "state": "active", "blocked": false, "rule": null, "method": null, "url": null, "label": "search"},
        {"host": "a.org", "time": 100010, "ago": 20, "source": "172.16.0.2", "via": "", "port": 80, "sent": 1, "received": 1, "state": "guard", "blocked": true, "rule": "builtin:ssrf-guard", "method": "GET", "url": "https://a.org/x", "label": null},
        {"host": "b.org", "time": 100000, "ago": 5, "port": 443, "state": "finished"},
        {"host": "a.org", "time": 100005, "ago": 25, "source": "harness", "via": "", "port": null, "sent": 0, "received": 0, "state": "closed", "blocked": false},
    ]
    check(L.log_of("a.org", rows).size() == 4, "log_of keeps one host's rows")
    var menu: Array = L.menu_of(L.log_of("a.org", rows))
    check(menu.size() == 3 and menu[0]["label"] == "443 PROXY" and menu[0]["rows"].size() == 2, "menu: busiest group first")
    check(menu[0]["rows"][0]["ago"] == 0, "menu: rows newest first")
    check(menu[1]["label"] == "- HARNESS" and menu[2]["label"] == "80 172.16.0.2", "menu: ties by label")
    var labels := []
    for g in menu:
        labels.append(g["label"])
    check(labels.has("80 172.16.0.2") and labels.has("- HARNESS"), "menu: the source stands in for an empty via, a missing port is -: %s" % [labels])
    var big_log := []
    for i in range(30):
        big_log.append({"host": "a.org", "ago": i, "via": "v%02d" % i, "port": 443})
    check(L.menu_of(big_log).size() == 12, "menu: at most 12 items")
    check(L.menu_of([]).is_empty(), "menu: an empty log, no items")
    var box: Dictionary = L.box_of(rows[0])
    check(box["title"] == "GET /PATH/0" and box["caption"] == "OK 100B 2.0K" and not box["blocked"], "box: method and path, state and bytes: %s" % [box])
    check(L.box_of(rows[1])["title"] == "SEARCH" and L.box_of(rows[1])["caption"].begins_with("LIVE"), "box: the label when there is no url")
    var refused: Dictionary = L.box_of(rows[2])
    check(refused["blocked"] and refused["caption"] == "REFUSED BUILTIN:SSRF-GUARD", "box: a refused row: %s" % [refused])
    check(L.box_of(rows[4], 3600)["title"] == "04:46:45", "box: the time when there is nothing else: %s" % [L.box_of(rows[4], 3600)])
    check(L.box_of({"url": "https://a.org/" + "p".repeat(40), "method": "GET"})["title"].length() == 22, "box: titles are cut to 22")
    check(L.path_of("https://h.org") == "/" and L.path_of("h.org/a?b=1") == "/a?b=1", "path_of")
    var lines: PackedStringArray = L.log_lines(L.log_of("a.org", rows), 0)
    check(lines == PackedStringArray(["03:47:10 443 LIVE", "03:46:50 80 REFUSED", "03:46:45 - CLOSED", "03:46:40 443 OK"]), "log lines, newest first: %s" % [lines])
    var long_log := []
    for i in range(100):
        long_log.append({"host": "a.org", "time": 1000 + i, "ago": i, "port": 443, "state": "finished"})
    check(L.log_lines(long_log, 0).size() == 40, "at most 40 log lines")
    var with_log: PackedStringArray = L.page_of(row("a.org", 2), L.log_lines(long_log, 0))
    check(with_log.size() <= GibsonFont.MAX_PAGE_ROWS and with_log[with_log.size() - 1] == "", "a page with a log fits the page texture")
    var seen_at := with_log.find("SEEN 0S AGO")
    check(seen_at > 0 and with_log[seen_at + 1].contains(":"), "the log follows SEEN")
    check(L.totals_of({"count": 14, "sent": 5217, "received": 90329, "blocked": 3, "untunnelled": true}) == "14 CONNECTIONS · 5.1K UP · 88.2K DOWN · 3 REFUSED · OUTSIDE THE TUNNEL", "totals line")

    # XR scale.
    var table: float = L.table_scale(40.0)
    check(is_equal_approx(table, 1.6 / 80.0), "table scale: 1.6 m across")
    check(L.scale_step(table, 0.0, 0.1, table) == table and L.scale_step(0.5, 0.1, 0.1, table) == 0.5, "scale_step: the dead zone changes nothing")
    check(is_equal_approx(L.scale_step(0.1, 1.0, 0.5, table), 0.1 * 1.4), "scale_step: up multiplies by 1 + 0.8 * value * delta")
    check(L.scale_step(0.9, 1.0, 1.0, table) == 1.0 and L.scale_step(table, -1.0, 0.5, table) == table, "scale_step: kept between table-top and life size")
    check(L.zoom_k(table, table) == 0.0 and L.zoom_k(1.0, table) == 1.0 and is_equal_approx(L.zoom_k((1.0 + table) / 2.0, table), 0.5), "zoom_k: 0 to 1")
    check(L.life_origin(Vector3(2, 1.7, -3)) == Vector3(2, 0.02, -3), "life_origin: under the viewer, 2 cm up")

    # Hash.
    var hv := L.hash01("x")
    check(hv >= 0.0 and hv < 1.0 and hv == L.hash01("x") and L.hash01("x") != L.hash01("y"), "hash01")

    print("gibson selftest: %d failure(s)" % failures)
    quit(1 if failures > 0 else 0)
