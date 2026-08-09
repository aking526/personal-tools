"""Textual UI. Contains no parsing or HTTP logic — see index.py for those."""

import subprocess
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from pathlib import Path

from textual import events, work
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical
from textual.screen import ModalScreen
from textual.widgets import DataTable, Footer, Input, ListItem, ListView, Label, Static

from . import index as ix

YEAR_WIDTH, AUTHORS_WIDTH, MIN_COL_WIDTH = 6, 28, 10
COLUMNS = [("Title", "title", 60), ("Authors", "authors", AUTHORS_WIDTH), ("Year", "year", YEAR_WIDTH)]
ALL_FOLDERS = "\x00ALL"
RESOLVE_WORKERS = 4


class AddFolderScreen(ModalScreen[str | None]):
    """Prompt for a folder path. Returns the path, or None if cancelled."""

    CSS = "AddFolderScreen { align: center middle; } #box { width: 70; height: auto; border: thick $accent; padding: 1; background: $surface; }"
    BINDINGS = [Binding("escape", "cancel", "Cancel", priority=True)]

    def compose(self) -> ComposeResult:
        with Vertical(id="box"):
            yield Static("Folder to index (~ is expanded):")
            yield Input(placeholder="~/Papers", id="folder-path")

    def on_mount(self) -> None:
        self.query_one("#folder-path", Input).focus()

    def on_input_submitted(self, event: Input.Submitted) -> None:
        self.dismiss(event.value.strip() or None)

    def action_cancel(self) -> None:
        self.dismiss(None)


class PapersTable(DataTable):
    """Table that refits its columns whenever its own width changes.

    App-level `on_resize` fires before layout runs, so from there the table's
    region is still the previous one and the fit lands a frame late. The
    widget's own Resize event is the one that carries the current width.
    """

    def on_resize(self, event: events.Resize) -> None:
        self.app.fit_columns()


SORT_KEYS = [
    ("title", lambda r: (r["title"] or "").lower()),
    ("year", lambda r: -(r["year"] or 0)),
    ("added", lambda r: -(r["added"] or 0)),
    ("authors", lambda r: (r["authors"] or "").lower()),
]


class PaperIndexerApp(App):
    CSS = """
    #sidebar { width: 24; border-right: solid $panel; }
    #filter { border: none; }
    DataTable { height: 1fr; }
    #details { height: auto; padding: 0 1; border-top: solid $panel; background: $boost; }
    .unreachable { text-style: dim; }
    """

    # priority=True is what makes these fire while the Input holds focus.
    BINDINGS = [
        Binding("up", "cursor_up", "Up", show=False, priority=True),
        Binding("down", "cursor_down", "Down", show=False, priority=True),
        Binding("enter", "open_paper", "Open", priority=True),
        Binding("tab", "toggle_details", "Details", priority=True),
        Binding("escape", "clear_filter", "Clear", priority=True),
        Binding("ctrl+up", "folder_prev", "Prev folder", show=False, priority=True),
        Binding("ctrl+down", "folder_next", "Next folder", show=False, priority=True),
        Binding("ctrl+o", "cycle_sort", "Sort", priority=True),
        Binding("ctrl+q", "quit", "Quit", priority=True),
        Binding("ctrl+n", "add_folder", "Add folder", priority=True),
        Binding("ctrl+x", "remove_folder", "Remove folder", priority=True),
        Binding("ctrl+r", "refresh", "Refresh", priority=True),
    ]

    def __init__(self, db_path=None):
        super().__init__()
        self.conn = ix.connect(db_path)
        ix.init_db(self.conn)
        self.papers: dict[str, dict] = {}      # path -> row dict
        self.displayed: set[str] = set()       # paths currently in the table
        self.row_order: list[str] = []         # table row index -> path
        self.folder_paths: list[str] = [ALL_FOLDERS]
        self.folder = ALL_FOLDERS
        self.sort_index = 0

    def check_action(self, action: str, parameters: tuple[object, ...]) -> bool | None:
        """Disable every App-level binding while a modal owns the screen.

        Textual checks the App's priority bindings BEFORE a pushed screen sees
        the key, and App-level query_one resolves against the background
        screen. So without this, Enter and Escape never reach AddFolderScreen
        (open_paper/clear_filter swallow them first, leaving the dialog stuck
        open), and ctrl+x would delete the folder selected behind the dialog —
        invisible, unconfirmed index loss.
        """
        return None if len(self.screen_stack) > 1 else True

    def compose(self) -> ComposeResult:
        with Horizontal():
            yield ListView(id="sidebar")
            with Vertical():
                yield Input(placeholder="filter…", id="filter")
                yield PapersTable(id="papers", cursor_type="row")
                yield Static(id="details")
        yield Footer()

    def on_mount(self) -> None:
        table = self.query_one("#papers", DataTable)
        for label, key, width in COLUMNS:
            table.add_column(label, key=key, width=width)
        self.query_one("#details", Static).display = False
        self.reload_folders()
        self.reload_papers()
        self.query_one("#filter", Input).focus()
        self.action_refresh()

    # --- data -------------------------------------------------------------

    def reload_folders(self) -> None:
        view = self.query_one("#sidebar", ListView)
        view.clear()
        counts = {}
        for row in ix.list_papers(self.conn):
            counts[row["folder"]] = counts.get(row["folder"], 0) + 1
        total = sum(counts.values())
        # No widget id: selection is tracked by ListView.index (see step_folder /
        # on_list_view_selected), and view.clear() above only *schedules* removal
        # of the old items rather than removing them synchronously — a fixed id
        # here would collide with the still-registered old widget whenever
        # reload_folders() runs again before that removal has flushed.
        view.append(ListItem(Label(f"All ({total})")))
        for folder in ix.list_folders(self.conn):
            name = folder.rstrip("/").split("/")[-1] or folder
            label = f"{name} ({counts.get(folder, 0)})"
            # Unreachable (e.g. external drive unmounted) greys out; rows are kept.
            css = "" if ix.folder_readable(folder) else "unreachable"
            view.append(ListItem(Label(label), classes=css))
        self.folder_paths = [ALL_FOLDERS] + ix.list_folders(self.conn)

    def reload_papers(self) -> None:
        folder = None if self.folder == ALL_FOLDERS else self.folder
        self.papers = {r["path"]: dict(r) for r in ix.list_papers(self.conn, folder)}
        self.render_table()

    def render_table(self) -> None:
        """Rebuild the table from `self.papers`, honouring the active filter."""
        table = self.query_one("#papers", DataTable)
        needle = self.query_one("#filter", Input).value.strip().lower()
        table.clear()
        self.displayed = set()
        self.row_order = []
        rows = sorted(self.papers.values(), key=SORT_KEYS[self.sort_index][1])
        for row in rows:
            hay = f"{row['title'] or ''} {row['authors'] or ''}".lower()
            if needle and needle not in hay:
                continue
            table.add_row(*self.cells(row), key=row["path"])
            self.displayed.add(row["path"])
            self.row_order.append(row["path"])   # row index -> path, for selection

    def cells(self, row: dict) -> list[str]:
        return [row["title"] or "", row["authors"] or "", str(row["year"] or "")]

    def update_details(self) -> None:
        """Fill the details pane for the highlighted row. No-op while hidden."""
        pane = self.query_one("#details", Static)
        if not pane.display:
            return
        path = self.selected_path()
        row = self.papers.get(path) if path else None
        if not path or row is None:
            pane.update("")
            return
        added = "—"
        if row.get("added"):
            added = datetime.fromtimestamp(row["added"]).strftime("%Y-%m-%d %H:%M")
        pane.update(
            f"[$text-muted]Folder  [/]  {row['folder']}\n"
            f"[$text-muted]Filename[/]  {Path(path).name}\n"
            f"[$text-muted]Added   [/]  {added}"
        )

    def fit_columns(self) -> None:
        """Give Title the leftover width so the table never scrolls sideways.

        Fixed widths that overrun the window earn DataTable a horizontal
        scrollbar: a blue-on-black bar wedged above the footer that reads as
        chrome but is really just columns falling off the edge.
        """
        table = self.query_one("#papers", DataTable)
        if "title" not in table.columns:      # a resize can land before on_mount
            return
        avail = table.scrollable_content_region.width - 2 * table.cell_padding * len(COLUMNS)
        # Authors takes a third of the non-Year space, capped; Title absorbs the rest.
        authors = min(AUTHORS_WIDTH, max(MIN_COL_WIDTH, (avail - YEAR_WIDTH) // 3))
        want = {"year": YEAR_WIDTH, "authors": authors,
                "title": max(MIN_COL_WIDTH, avail - YEAR_WIDTH - authors)}
        if any(table.columns[k].width != w for k, w in want.items()):
            for k, w in want.items():
                table.columns[k].width = w
            # No public setter recomputes the virtual size after a width change.
            table._update_dimensions(table.rows.keys())

    # --- actions ------------------------------------------------------------

    def on_input_changed(self, event: Input.Changed) -> None:
        if event.input.id == "filter":
            self.render_table()

    def action_cursor_up(self) -> None:
        table = self.query_one("#papers", DataTable)
        table.move_cursor(row=max(0, table.cursor_row - 1))

    def action_cursor_down(self) -> None:
        table = self.query_one("#papers", DataTable)
        table.move_cursor(row=min(table.row_count - 1, table.cursor_row + 1))

    def action_toggle_details(self) -> None:
        pane = self.query_one("#details", Static)
        pane.display = not pane.display
        self.update_details()

    def on_data_table_row_highlighted(self, event: DataTable.RowHighlighted) -> None:
        self.update_details()

    def action_clear_filter(self) -> None:
        self.query_one("#filter", Input).value = ""

    def action_cycle_sort(self) -> None:
        self.sort_index = (self.sort_index + 1) % len(SORT_KEYS)
        self.notify(f"Sorted by {SORT_KEYS[self.sort_index][0]}")
        self.render_table()

    def selected_path(self) -> str | None:
        """`row_order` is maintained by render_table, so no DataTable key lookup."""
        table = self.query_one("#papers", DataTable)
        if 0 <= table.cursor_row < len(self.row_order):
            return self.row_order[table.cursor_row]
        return None

    def action_open_paper(self) -> None:
        path = self.selected_path()
        if not path:
            return
        if not Path(path).exists():
            self.notify(f"File is gone: {Path(path).name}", severity="warning")
            self.papers.pop(path, None)
            self.render_table()
            return
        subprocess.run(["open", "-a", "Preview", path], check=False)

    def action_folder_prev(self) -> None:
        self.step_folder(-1)

    def action_folder_next(self) -> None:
        self.step_folder(1)

    def step_folder(self, delta: int) -> None:
        if not self.folder_paths:
            return
        i = self.folder_paths.index(self.folder) if self.folder in self.folder_paths else 0
        i = max(0, min(len(self.folder_paths) - 1, i + delta))
        self.folder = self.folder_paths[i]
        self.query_one("#sidebar", ListView).index = i
        self.reload_papers()

    def on_list_view_selected(self, event: ListView.Selected) -> None:
        index = self.query_one("#sidebar", ListView).index or 0
        if index < len(self.folder_paths):
            self.folder = self.folder_paths[index]
            self.reload_papers()

    # --- folder management + background resolution --------------------------

    def action_add_folder(self) -> None:
        def added(raw: str | None) -> None:
            if not raw:
                return
            path = Path(raw).expanduser().resolve()
            if not path.is_dir():
                self.notify(f"Not a folder: {path}", severity="error")
                return
            ix.add_folder(self.conn, str(path))
            # action_refresh() below does its own reload_folders() + reload_papers();
            # calling reload_folders() here too would race its still-pending
            # ListView.clear() and crash with DuplicateIds on the "f-all" item.
            self.action_refresh()

        self.push_screen(AddFolderScreen(), added)

    def action_remove_folder(self) -> None:
        if self.folder == ALL_FOLDERS:
            self.notify("Select a folder first (ctrl+down)", severity="warning")
            return
        name = self.folder
        ix.remove_folder(self.conn, self.folder)     # index only; files untouched
        self.folder = ALL_FOLDERS
        self.reload_folders()
        self.reload_papers()
        self.notify(f"Removed {name} from the index. Files untouched.")

    def action_refresh(self) -> None:
        folders = ix.list_folders(self.conn)
        if not folders:
            self.notify("No folders yet — press ctrl+n to add one.")
            return
        stale: list[str] = []
        for folder in folders:
            if not ix.folder_readable(folder):
                # Same predicate scan() uses, so the sidebar's dimming and the
                # scan's prune guard can never disagree about "unreachable".
                self.notify(f"Unreachable, keeping rows: {folder}", severity="warning")
                continue
            stale.extend(ix.scan(self.conn, folder))
        self.reload_folders()
        self.reload_papers()
        if stale:
            self.notify(f"Resolving {len(stale)} paper(s)…")
            self.resolve_worker(stale)

    @work(thread=True, exclusive=True, group="resolve")
    def resolve_worker(self, paths: list[str]) -> None:
        """Resolve titles off the UI thread, pushing each result back as it lands."""
        client = ix.make_client()
        try:
            with ThreadPoolExecutor(max_workers=RESOLVE_WORKERS) as pool:
                for path, result in zip(paths, pool.map(lambda p: ix.resolve(p, client), paths)):
                    self.call_from_thread(self.apply_resolution, path, result)
        finally:
            client.close()

    def apply_resolution(self, path: str, result: dict) -> None:
        ix.save_resolution(
            self.conn, path,
            title=result["title"], authors=result["authors"], year=result["year"],
            doi=result["doi"], arxiv_id=result["arxiv_id"], source=result["source"],
        )
        row = self.papers.get(path)
        if row is None:
            return
        row.update(result)
        if path in self.displayed:
            table = self.query_one("#papers", DataTable)
            for value, (_, key, _) in zip(self.cells(row), COLUMNS):
                table.update_cell(path, key, value)


def main() -> None:
    PaperIndexerApp().run()


if __name__ == "__main__":
    main()
