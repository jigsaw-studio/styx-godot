class_name GibsonFont
extends RefCounted

# A bitmap font drawn into an image once: 64 glyphs in an atlas of 8 columns by 8 rows
# of 8 x 10 pixel cells (64 x 80, L8, white on black); glyph g is at cell (g mod 8, g div 8).
#   0 space | 1-10 "0"-"9" | 11-36 "A"-"Z" | 37 "." 38 "-" 39 ":" |
#   40-53 "/" "_" "=" ">" "?" "%" "#" "[" "]" "(" ")" "+" "*" "," | 54-63 blank
# The first 39 shapes are the 6 x 7 sprites the Matrix windows use (pairs of numbers,
# the author's own); the other fourteen are drawn here as 5 x 7 pictures.

const CELL := Vector2i(8, 10)
const COLUMNS := 8
const PAGE_WIDTH := 24
const MAX_PAGE_ROWS := 64

# "0"-"9", "A"-"Z", ".", "-", ":" as (hi, lo) of a 6 x 7 bitmap.
const SPRITES := [
    [935221, 731292],
    [274497, 33308],
    [934929, 1116222],
    [934931, 1058972],
    [137380, 1302788],
    [2048263, 1058972],
    [401671, 1190044],
    [2032673, 66576],
    [935187, 1190044],
    [935187, 1581336],
    [935188, 780450],
    [1983767, 1190076],
    [935172, 133276],
    [1983764, 665788],
    [2048263, 1181758],
    [2048263, 1181728],
    [935173, 1714334],
    [1131799, 1714338],
    [921665, 33308],
    [66576, 665756],
    [1132870, 166178],
    [1065220, 133182],
    [1142100, 665762],
    [1140052, 1714338],
    [935188, 665756],
    [1983767, 1181728],
    [935188, 698650],
    [1983767, 1198242],
    [935171, 1058972],
    [2035777, 33288],
    [1131796, 665756],
    [1131796, 664840],
    [1131861, 699028],
    [1131681, 84130],
    [1131794, 1081864],
    [1968194, 133180],
    [0, 1560],
    [7, 1572864],
    [195, 1560]
]

const EXTRA_CHARS := "/_=>?%#[]()+*,"
const EXTRA := [
    ["....#", "....#", "...#.", "..#..", ".#...", "#....", "#...."],  # /
    [".....", ".....", ".....", ".....", ".....", ".....", "#####"],  # _
    [".....", ".....", "#####", ".....", "#####", ".....", "....."],  # =
    ["#....", ".#...", "..#..", "...#.", "..#..", ".#...", "#...."],  # >
    [".###.", "#...#", "....#", "...#.", "..#..", ".....", "..#.."],  # ?
    ["##..#", "##.#.", "...#.", "..#..", ".#...", ".#.##", "#..##"],  # %
    [".#.#.", ".#.#.", "#####", ".#.#.", "#####", ".#.#.", ".#.#."],  # #
    [".###.", ".#...", ".#...", ".#...", ".#...", ".#...", ".###."],  # [
    [".###.", "...#.", "...#.", "...#.", "...#.", "...#.", ".###."],  # ]
    ["...#.", "..#..", ".#...", ".#...", ".#...", "..#..", "...#."],  # (
    [".#...", "..#..", "...#.", "...#.", "...#.", "..#..", ".#..."],  # )
    [".....", "..#..", "..#..", "#####", "..#..", "..#..", "....."],  # +
    [".....", "#.#.#", ".###.", "#####", ".###.", "#.#.#", "....."],  # *
    [".....", ".....", ".....", ".....", ".##..", "..#..", ".#..."],  # ,
]

static var _atlas: ImageTexture = null

static func _sprite_lit(pair: Array, gx: int, gy: int) -> bool:
    var ux := gx
    var uy := 6 - gy
    if ux < 0 or ux >= 6 or uy < 0 or uy >= 7:
        return false
    var bit := (6 - ux) + uy * 6
    if bit >= 21:
        return ((int(pair[0]) >> (bit - 21)) & 1) == 1
    return ((int(pair[1]) >> bit) & 1) == 1

static func _origin(g: int) -> Vector2i:
    return Vector2i((g % COLUMNS) * CELL.x, (g / COLUMNS) * CELL.y)

static func atlas() -> ImageTexture:
    if _atlas != null:
        return _atlas
    var image := Image.create(COLUMNS * CELL.x, 8 * CELL.y, false, Image.FORMAT_L8)
    image.fill(Color.BLACK)
    # Sprite i is glyph i + 1: 0-9 -> 1-10, A-Z -> 11-36, "." "-" ":" -> 37-39.
    for i in range(SPRITES.size()):
        var origin := _origin(i + 1)
        for gy in range(CELL.y):
            for gx in range(CELL.x):
                if _sprite_lit(SPRITES[i], gx, gy):
                    image.set_pixel(origin.x + gx, origin.y + gy, Color.WHITE)
    for i in range(EXTRA.size()):
        var origin := _origin(40 + i)
        for row in range(7):
            var line: String = EXTRA[i][row]
            for col in range(5):
                if line[col] == "#":
                    image.set_pixel(origin.x + 1 + col, origin.y + row, Color.WHITE)
    _atlas = ImageTexture.create_from_image(image)
    return _atlas

# Upper-cases; an unknown character is the index of "_".
static func glyph_index(ch: String) -> int:
    var c := ch.to_upper()
    if c == " " or c == "":
        return 0
    var code := c.unicode_at(0)
    if code >= 48 and code <= 57:
        return code - 48 + 1
    if code >= 65 and code <= 90:
        return code - 65 + 11
    var simple := ".-:"
    var at := simple.find(c)
    if at >= 0:
        return 37 + at
    var extra := EXTRA_CHARS.find(c)
    if extra >= 0:
        return 40 + extra
    return 41

# A page as a texture: width 24, height = lines.size() (at most 64), R8, each pixel
# the glyph index (the shader reads it back as index / 255).
static func page_texture(lines: PackedStringArray) -> ImageTexture:
    var rows := clampi(lines.size(), 1, MAX_PAGE_ROWS)
    var bytes := PackedByteArray()
    bytes.resize(PAGE_WIDTH * rows)
    for r in range(rows):
        var line := lines[r] if r < lines.size() else ""
        for c in range(PAGE_WIDTH):
            bytes[r * PAGE_WIDTH + c] = glyph_index(line[c]) if c < line.length() else 0
    return ImageTexture.create_from_image(Image.create_from_data(PAGE_WIDTH, rows, false, Image.FORMAT_R8, bytes))
