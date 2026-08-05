"""Generate the README's box-drawn art with alignment guaranteed by construction.

The architecture diagram is painted onto a character grid at explicit coordinates,
so connectors line up because they are placed at the same column, not because
someone counted dashes correctly.

Only box-drawing characters and ASCII appear inside frames. Glyphs like U+2709 are
East Asian "ambiguous" or emoji-presented and render double-width in some fonts,
which breaks the frame for those readers.
"""

import pathlib
import unicodedata


def cols(text: str) -> int:
    return sum(
        0 if unicodedata.combining(c) else (2 if unicodedata.east_asian_width(c) in "WF" else 1)
        for c in text
    )


def pad(text: str, width: int) -> str:
    assert cols(text) <= width, f"{text!r} is {cols(text)} cols, max {width}"
    return text + " " * (width - cols(text))


def centred(text: str, width: int) -> str:
    left = (width - cols(text)) // 2
    return " " * left + text + " " * (width - cols(text) - left)


GLYPHS = {
    "I": [
        "██╗",
        "██║",
        "██║",
        "██║",
        "██║",
        "╚═╝",
    ],
    "A": [
        " █████╗ ",
        "██╔══██╗",
        "███████║",
        "██╔══██║",
        "██║  ██║",
        "╚═╝  ╚═╝",
    ],
    "V": [
        "██╗   ██╗",
        "██║   ██║",
        "██║   ██║",
        "╚██╗ ██╔╝",
        " ╚████╔╝ ",
        "  ╚═══╝  ",
    ],
    "R": [
        "██████╗ ",
        "██╔══██╗",
        "██████╔╝",
        "██╔══██╗",
        "██║  ██║",
        "╚═╝  ╚═╝",
    ],
    "C": [
        " ██████╗",
        "██╔════╝",
        "██║     ",
        "██║     ",
        "╚██████╗",
        " ╚═════╝",
    ],
    "-": [
        "      ",
        "      ",
        "█████╗",
        "╚════╝",
        "      ",
        "      ",
    ],
    "L": [
        "██╗     ",
        "██║     ",
        "██║     ",
        "██║     ",
        "███████╗",
        "╚══════╝",
    ],
    "E": [
        "███████╗",
        "██╔════╝",
        "█████╗  ",
        "██╔══╝  ",
        "███████╗",
        "╚══════╝",
    ],
    "N": [
        "███╗   ██╗",
        "████╗  ██║",
        "██╔██╗ ██║",
        "██║╚██╗██║",
        "██║ ╚████║",
        "╚═╝  ╚═══╝",
    ],
    "T": [
        "████████╗",
        "╚══██╔══╝",
        "   ██║   ",
        "   ██║   ",
        "   ██║   ",
        "   ╚═╝   ",
    ],
}



def wordmark(word: str = "CARAVAN", indent: int = 3) -> list[str]:
    """Compose the wordmark from fixed-width glyph blocks.

    Concatenating per-letter blocks makes misalignment impossible, rather than
    something to eyeball afterwards.

    Trailing spaces are deliberately **not** stripped. The wordmark lives inside
    `<div align="center">`, which GitHub renders as `text-align: center` — and a
    `<pre>` inherits that and centres *each line independently*. Ragged line lengths
    therefore shift rows relative to one another: strip the trailing spaces and the
    six-row block visibly staircases, because the letters `T` and `C` leave shorter
    tails on the lower rows. Equal-length rows centre identically.
    """
    for letter in word:
        widths = {len(row) for row in GLYPHS[letter]}
        assert len(widths) == 1, f"glyph {letter!r} has ragged rows: {widths}"
    rows = [" " * indent + "".join(GLYPHS[l][i] for l in word) for i in range(6)]
    assert len({len(r) for r in rows}) == 1, "rendered wordmark is ragged"
    return rows


# ---------------------------------------------------------------- UI mockup

LEFT, MID, RIGHT = 25, 46, 6
TOTAL = 1 + LEFT + 1 + MID + 1 + RIGHT + 1

TREE = [
    ("* Libera.Chat", ""),
    ("  |- #caravan", "*"),
    ("  |- #swift", ""),
    ("  `- >NickServ", ""),
    ("", ""),
    ("* soju (bouncer)", ""),
    ("  |- #ops", "o"),
    ("  `- #dev", ""),
]
LOG = [
    "[12:04:17] *** Joins: alice (~a@example.net)",
    "[12:04:22] <bob>   parser passes the corpus",
    "[12:04:31] <alice> all 66 cases?",
    "[12:04:36] * bob nods",
    "[12:04:41] -NickServ- You are now identified",
    "[12:05:02] *** eve is now known as evelyn",
    "",
    "",
]
NICKS = ["@ops", "@bob", "+eve", " ann", " joe", "", "", ""]


def mockup() -> list[str]:
    rows = []
    title = "┌─ Caravan "
    rows.append(title + "─" * (TOTAL - cols(title) - 1) + "┐")
    topic = " #caravan - a native macOS IRC client"
    rows.append("│" + " " * LEFT + "│" + pad(topic, MID + 1 + RIGHT) + "│")
    rows.append("│" + " " * LEFT + "├" + "─" * MID + "┬" + "─" * RIGHT + "┤")

    for index in range(8):
        name, mark = TREE[index]
        left = pad(" " + name, LEFT - 2) + pad(mark, 2) if name else " " * LEFT
        rows.append(
            "│" + pad(left, LEFT)
            + "│" + pad(" " + LOG[index], MID)
            + "│" + pad(" " + NICKS[index], RIGHT) + "│"
        )

    rows.append("├" + "─" * LEFT + "┴" + "─" * MID + "┴" + "─" * RIGHT + "┤")
    rows.append("│" + pad(" [#caravan] > /msg alice thanks!", TOTAL - 2) + "│")
    rows.append("└" + "─" * (TOTAL - 2) + "┘")

    for row in rows:
        assert cols(row) == TOTAL, f"{cols(row)} != {TOTAL}: {row!r}"
    return rows


# ------------------------------------------------------------- architecture

class Grid:
    def __init__(self, width: int, height: int) -> None:
        self.cells = [[" "] * width for _ in range(height)]

    def put(self, row: int, col: int, text: str) -> None:
        for offset, char in enumerate(text):
            self.cells[row][col + offset] = char

    def box(self, row: int, col: int, inner: int, height: int) -> None:
        self.put(row, col, "┌" + "─" * inner + "┐")
        for r in range(row + 1, row + 1 + height):
            self.put(r, col, "│")
            self.put(r, col + inner + 1, "│")
        self.put(row + 1 + height, col, "└" + "─" * inner + "┘")

    def render(self) -> list[str]:
        return ["".join(r).rstrip() for r in self.cells]


def architecture() -> list[str]:
    grid = Grid(84, 32)

    inner, left = 27, 22
    centre = left + 1 + inner // 2  # column of the vertical stem

    stack = [
        ("App", "SwiftUI shell", "NSTextView scrollback", "AppKit where it counts"),
        ("IRCSession", "registration, ISUPPORT,", "actor - event stream", "state machine, events"),
        ("IRCTransport", "NWConnection, TLS,", "actor - line framing", "send queue, reconnect"),
    ]
    annotation_col = left + inner + 4

    row = 0
    for index, (title, note1, sub, note2) in enumerate(stack):
        grid.box(row, left, inner, 2)
        grid.put(row + 1, left + 1, centred(title, inner))
        grid.put(row + 1, annotation_col, note1)
        grid.put(row + 2, left + 1, centred(sub, inner))
        grid.put(row + 2, annotation_col, note2)
        if index > 0:
            grid.put(row, centre, "▼")  # incoming arrow on the top edge
        if index < len(stack) - 1:
            grid.put(row + 3, centre, "┬")
            grid.put(row + 4, centre, "│")
        row += 5

    # Bus from IRCTransport down to two children.
    bus_top = row - 2
    grid.put(bus_top, centre, "┬")
    grid.put(bus_top + 1, centre, "│")

    li, ri = 19, 23
    lcol, rcol = 8, 48
    lcentre, rcentre = lcol + 1 + li // 2, rcol + 1 + ri // 2

    bus = bus_top + 2
    grid.put(bus, lcentre, "┌" + "─" * (rcentre - lcentre - 1) + "┐")
    grid.put(bus, centre, "┴")
    grid.put(bus + 1, lcentre, "│")
    grid.put(bus + 1, rcentre, "│")

    child = bus + 2
    grid.box(child, lcol, li, 5)
    grid.box(child, rcol, ri, 5)
    grid.put(child, lcentre, "▼")
    grid.put(child, rcentre, "▼")

    grid.put(child + 1, lcol + 1, centred("Diagnostics", li))
    grid.put(child + 1, rcol + 1, centred("IRCProtocol", ri))
    for offset, (a, b) in enumerate(
        [("os.Logger", "parse - serialize"),
         ("Redactor", "IRCv3 tags - masks"),
         ("TraceBuffer", "casemapping"),
         ("Signposts", "")],
        start=2,
    ):
        grid.put(child + offset, lcol + 2, a)
        grid.put(child + offset, rcol + 2, b)

    grid.put(child + 7, lcol, centred("Darwin-only", li + 2))
    grid.put(child + 7, rcol, centred("pure · builds on Linux", ri + 2))

    rows = grid.render()
    while rows and not rows[-1]:
        rows.pop()

    # Connectors must sit in the same column as what they connect to.
    assert rows[bus][centre] == "┴"
    assert rows[child][lcentre] == "▼" and rows[child][rcentre] == "▼"
    assert rows[bus][lcentre] == "┌" and rows[bus][rcentre] == "┐"
    return rows


BLOCKS = {
    "wordmark": wordmark,
    "mockup": lambda: mockup() + ["    * highlight    o activity"],
    "architecture": architecture,
}


def splice(text: str, name: str, body: list[str]) -> str:
    """Replace the fenced block between the sentinels for `name`."""
    open_tag, close_tag = f"<!-- art:{name} -->", f"<!-- /art:{name} -->"
    start, end = text.index(open_tag) + len(open_tag), text.index(close_tag)
    return text[:start] + "\n\n```\n" + "\n".join(body) + "\n```\n\n" + text[end:]


if __name__ == "__main__":
    import sys

    readme = pathlib.Path(__file__).resolve().parent.parent / "README.md"
    original = readme.read_text()
    updated = original
    for name, build in BLOCKS.items():
        updated = splice(updated, name, build())

    if "--check" in sys.argv:
        if updated != original:
            print(
                "README ASCII art does not match the generator. Run:\n"
                "    python3 Scripts/render-readme-art.py\n"
                "If you did not touch the art, check for stripped trailing whitespace: the\n"
                "wordmark rows must stay equal length or the centred <pre> staircases.",
                file=sys.stderr,
            )
            sys.exit(1)
        print("README ASCII art matches the generator")
    else:
        readme.write_text(updated)
        print("README ASCII art regenerated")
