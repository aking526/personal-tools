"""All I/O: SQLite, the folder walk, PDF reading, and HTTP resolvers.

The UI never touches this module's internals; it calls the functions here and
renders what comes back.
"""

import os
import sqlite3
import threading
import time
import xml.etree.ElementTree as ET
from pathlib import Path

import httpx
from pypdf import PdfReader

from .extract import (
    better_title,
    crossref_match,
    find_arxiv_id,
    find_doi,
    is_junk_title,
    largest_font_text,
    prettify_filename,
)

DB_PATH = Path.home() / "Library" / "Application Support" / "paper-catalog" / "index.db"

# Sources weak enough to re-attempt on the next refresh.
WEAK_SOURCES = ("local", "filename")

SCHEMA = """
CREATE TABLE IF NOT EXISTS folders (
  path TEXT PRIMARY KEY
);
CREATE TABLE IF NOT EXISTS papers (
  path      TEXT PRIMARY KEY,
  folder    TEXT NOT NULL REFERENCES folders(path) ON DELETE CASCADE,
  title     TEXT NOT NULL,
  authors   TEXT,
  year      INTEGER,
  doi       TEXT,
  arxiv_id  TEXT,
  source    TEXT NOT NULL,
  mtime     REAL NOT NULL,
  size      INTEGER NOT NULL,
  added     REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS papers_folder ON papers(folder);
"""


def connect(db_path=None) -> sqlite3.Connection:
    path = Path(db_path) if db_path else DB_PATH
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(path, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")   # required for the folder cascade
    return conn


def init_db(conn: sqlite3.Connection) -> None:
    conn.executescript(SCHEMA)
    conn.commit()


def add_folder(conn, path: str) -> None:
    conn.execute("INSERT OR IGNORE INTO folders (path) VALUES (?)", (str(path),))
    conn.commit()


def remove_folder(conn, path: str) -> None:
    conn.execute("DELETE FROM folders WHERE path = ?", (str(path),))
    conn.commit()


def list_folders(conn) -> list[str]:
    return [r["path"] for r in conn.execute("SELECT path FROM folders ORDER BY path")]


def list_papers(conn, folder: str | None = None) -> list[sqlite3.Row]:
    if folder:
        return list(conn.execute("SELECT * FROM papers WHERE folder = ?", (folder,)))
    return list(conn.execute("SELECT * FROM papers"))


def upsert_placeholder(conn, path, folder, title, mtime, size, added) -> bool:
    """Insert a row with a placeholder title. True if it needs resolving.

    The cache key is (path, mtime, size): an untouched file is never re-parsed.
    """
    row = conn.execute(
        "SELECT mtime, size FROM papers WHERE path = ?", (str(path),)
    ).fetchone()
    if row is not None and row["mtime"] == mtime and row["size"] == size:
        return False
    conn.execute(
        """INSERT INTO papers
                (path, folder, title, authors, year, doi, arxiv_id, source, mtime, size, added)
           VALUES (?, ?, ?, NULL, NULL, NULL, NULL, 'filename', ?, ?, ?)
           ON CONFLICT(path) DO UPDATE SET
                folder=excluded.folder, title=excluded.title, source='filename',
                mtime=excluded.mtime, size=excluded.size""",
        (str(path), str(folder), title, mtime, size, added),
    )
    conn.commit()
    return True


def save_resolution(conn, path, *, title, authors, year, doi, arxiv_id, source) -> None:
    conn.execute(
        """UPDATE papers
              SET title=?, authors=?, year=?, doi=?, arxiv_id=?, source=?
            WHERE path=?""",
        (title, authors, year, doi, arxiv_id, source, str(path)),
    )
    conn.commit()


def needs_resolution(conn) -> list[sqlite3.Row]:
    """Rows that landed on a weak rung and deserve another attempt."""
    marks = ",".join("?" * len(WEAK_SOURCES))
    return list(conn.execute(f"SELECT * FROM papers WHERE source IN ({marks})", WEAK_SOURCES))


def prune_missing(conn, folder: str, seen: set[str]) -> None:
    """Drop rows for files that no longer exist on disk."""
    existing = {r["path"] for r in conn.execute(
        "SELECT path FROM papers WHERE folder = ?", (str(folder),)
    )}
    gone = existing - {str(p) for p in seen}
    if gone:
        conn.executemany("DELETE FROM papers WHERE path = ?", [(p,) for p in gone])
        conn.commit()


ROTATION_EPSILON = 0.01


def pdf_spans(path, page_index: int = 0) -> list[tuple[str, float, bool]]:
    """Text spans on one page as (text, effective_font_size, rotated).

    pypdf hands the visitor the current transform matrix `tm`; a horizontal
    span has near-zero shear terms, and the arXiv margin stamp does not.
    """
    spans: list[tuple[str, float, bool]] = []

    def visitor(text, cm, tm, font_dict, font_size):
        if not text.strip() or font_size is None:
            return
        rotated = abs(tm[1]) > ROTATION_EPSILON or abs(tm[2]) > ROTATION_EPSILON
        scale = (tm[0] ** 2 + tm[1] ** 2) ** 0.5
        spans.append((text, font_size * scale, rotated))

    reader = PdfReader(str(path))
    if page_index < len(reader.pages):
        reader.pages[page_index].extract_text(visitor_text=visitor)
    return spans


def pdf_page_texts(path, max_pages: int = 2) -> list[str]:
    """Extracted text of the first `max_pages` pages, one string per page."""
    reader = PdfReader(str(path))
    return [p.extract_text() or "" for p in reader.pages[:max_pages]]


def pdf_metadata_title(path) -> str | None:
    """The /Title field, which LaTeX+hyperref usually leaves unset."""
    meta = PdfReader(str(path)).metadata
    return meta.title if meta else None


def resolve_offline(path) -> dict:
    """Rungs 3 and 4. Never raises — rung 4 always produces something.

    Everything fallible lives inside the try, including prettify_filename, so
    the never-raises contract is enforced by this function's own structure
    rather than by an assumption about another module.
    """
    result = {
        "title": str(path),        # literal fallback; cannot raise
        "authors": None,
        "year": None,
        "doi": None,
        "arxiv_id": None,
        "source": "filename",
        "page_text": "",
    }
    try:
        result["title"] = prettify_filename(str(path))
        pages = pdf_page_texts(path, 2)
        page1 = pages[0] if pages else ""
        result["page_text"] = page1              # the rung-2 gate reads page 1 only
        # A DOI can legitimately sit in a page-2 footer, and rung 1 now gates it.
        result["doi"] = find_doi("\n".join(pages))
        # arXiv stamps its own ID down page 1's margin; an ID found deeper in the
        # text is almost always a *citation* of some other paper.
        result["arxiv_id"] = find_arxiv_id(page1)

        meta_title = pdf_metadata_title(path)
        if not is_junk_title(meta_title):
            result["title"] = meta_title.strip()
            result["source"] = "local"
        else:
            font_title = largest_font_text(pdf_spans(path))
            if font_title and not is_junk_title(font_title):
                result["title"] = font_title
                result["source"] = "local"
    except Exception:
        # Encrypted, truncated, or malformed PDF. Rung 4 stands.
        pass
    return result


def contact_email(env_file=".env") -> str | None:
    """Contact address for the User-Agent, kept out of the repo.

    Crossref's polite pool wants one; without it requests still work, they just
    land in the public pool. Environment wins over the file so an installed copy
    needs no .env at all.
    """
    if email := os.environ.get("PAPER_CATALOG_EMAIL", "").strip():
        return email
    try:
        for line in Path(env_file).read_text().splitlines():
            key, _, value = line.partition("=")
            if key.strip() == "PAPER_CATALOG_EMAIL":
                return value.strip().strip("\"'") or None
    except OSError:
        pass
    return None


def user_agent() -> str:
    email = contact_email()
    return f"tui-paper-catalog/0.1 (mailto:{email})" if email else "tui-paper-catalog/0.1"


CROSSREF_TIMEOUT = 10.0
ARXIV_TIMEOUT = 20.0
ARXIV_URL = "https://export.arxiv.org/api/query"   # http:// returns 301
ATOM = {"a": "http://www.w3.org/2005/Atom"}

# arXiv rate-limits hard: bursts return "429 Rate exceeded" and stay angry for
# a while. Every arXiv call goes through this one lane.
ARXIV_MIN_INTERVAL = 3.0
_arxiv_lock = threading.Lock()
_arxiv_last = 0.0


def make_client() -> httpx.Client:
    return httpx.Client(headers={"User-Agent": user_agent()}, follow_redirects=True)


def _arxiv_throttle() -> None:
    """Serialize arXiv calls. Holding the lock across the sleep is the point."""
    global _arxiv_last
    with _arxiv_lock:
        wait = ARXIV_MIN_INTERVAL - (time.monotonic() - _arxiv_last)
        if wait > 0:
            time.sleep(wait)
        _arxiv_last = time.monotonic()


def _crossref_item_to_dict(item: dict) -> dict:
    title = (item.get("title") or [None])[0]
    authors = [a.get("family") for a in item.get("author", []) if a.get("family")]
    parts = (item.get("issued") or {}).get("date-parts") or [[None]]
    return {
        "title": title,
        "authors": authors,
        "year": parts[0][0] if parts and parts[0] else None,
        "doi": item.get("DOI"),
        "arxiv_id": None,
    }


def crossref_by_doi(client: httpx.Client, doi: str) -> dict | None:
    try:
        r = client.get(f"https://api.crossref.org/works/{doi}", timeout=CROSSREF_TIMEOUT)
        if r.status_code != 200:
            return None
        return _crossref_item_to_dict(r.json()["message"])
    except Exception:
        return None


def crossref_search(client: httpx.Client, title: str) -> dict | None:
    try:
        r = client.get(
            "https://api.crossref.org/works",
            params={"query.bibliographic": title, "rows": 1},
            timeout=CROSSREF_TIMEOUT,
        )
        if r.status_code != 200:
            return None
        items = r.json()["message"]["items"]
        return _crossref_item_to_dict(items[0]) if items else None
    except Exception:
        return None


def arxiv_by_id(client: httpx.Client, arxiv_id: str) -> dict | None:
    """One retry on 429; a second 429 falls through to the local rung."""
    for attempt in range(2):
        _arxiv_throttle()
        try:
            r = client.get(ARXIV_URL, params={"id_list": arxiv_id}, timeout=ARXIV_TIMEOUT)
        except Exception:
            return None
        if r.status_code == 429:
            if attempt == 0:
                time.sleep(ARXIV_MIN_INTERVAL * (attempt + 1) * 5)
            continue
        if r.status_code != 200:
            return None
        try:
            entry = ET.fromstring(r.text).find("a:entry", ATOM)
            if entry is None:
                return None
            return {
                "title": " ".join(entry.find("a:title", ATOM).text.split()),
                "authors": [a.find("a:name", ATOM).text for a in entry.findall("a:author", ATOM)],
                "year": int(entry.find("a:published", ATOM).text[:4]),
                "doi": None,
                "arxiv_id": arxiv_id,
            }
        except Exception:
            return None
    return None


def resolve(path, client: httpx.Client) -> dict:
    """The full four-rung ladder. Never raises."""
    local = resolve_offline(path)
    page_text = local.pop("page_text", "")
    remote, source = None, None

    if local["doi"]:                                        # rung 1
        hit = crossref_by_doi(client, local["doi"])
        # The DOI in the text may be a cited work's. Corroborate before trusting
        # it — an accepted wrong record is marked strong and never retried.
        if hit and crossref_match(hit["title"], hit["authors"], local["title"], page_text):
            remote, source = hit, "crossref"
    if remote is None and local["arxiv_id"]:                # rung 1
        remote, source = arxiv_by_id(client, local["arxiv_id"]), "arxiv"
    if remote is None and local["source"] == "local":       # rung 2
        hit = crossref_search(client, local["title"])
        if hit and crossref_match(hit["title"], hit["authors"], local["title"], page_text):
            remote, source = hit, "crossref"

    if remote is None:
        return local                                        # rungs 3 / 4 stand

    return {
        # Crossref records are sometimes truncated — keep the fuller title.
        "title": better_title(local["title"], remote["title"]),
        "authors": ", ".join(remote["authors"]) if remote["authors"] else None,
        "year": remote["year"],
        "doi": remote["doi"] or local["doi"],
        "arxiv_id": remote["arxiv_id"] or local["arxiv_id"],
        "source": source,
    }


def walk_pdfs(folder) -> list[Path]:
    """All PDFs under `folder`, recursively, skipping hidden directories."""
    root = Path(folder)
    if not root.is_dir():
        return []
    out = []
    for p in root.rglob("*.[pP][dD][fF]"):
        if any(part.startswith(".") for part in p.relative_to(root).parts):
            continue
        out.append(p)
    return out


def file_stats(path) -> tuple[float, int, float]:
    """(mtime, size, added). `added` is birthtime where macOS provides it."""
    st = Path(path).stat()
    return st.st_mtime, st.st_size, getattr(st, "st_birthtime", st.st_mtime)


def folder_readable(folder) -> bool:
    """True when the walk can be trusted to have seen the folder's real contents.

    An unmounted drive fails is_dir(); a permissions hiccup passes it but makes
    rglob return [] silently. Both must be distinguished from a folder the user
    genuinely emptied, or an empty walk would prune the whole index.
    """
    root = Path(folder)
    return root.is_dir() and os.access(root, os.R_OK | os.X_OK)


def scan(conn, folder) -> list[str]:
    """Sync one folder into the index. Returns paths that need resolution.

    Rows appear immediately with a filename placeholder so the table can
    populate before any parsing or network work happens.
    """
    readable = folder_readable(folder)
    found = walk_pdfs(folder) if readable else []
    stale: list[str] = []
    for path in found:
        try:
            mtime, size, added = file_stats(path)
        except OSError:
            continue
        if upsert_placeholder(
            conn, path, folder, prettify_filename(str(path)), mtime, size, added
        ):
            stale.append(str(path))
    if readable:
        # Never prune from an empty walk we cannot trust — that is how an
        # unmounted drive silently deletes a folder's entire index.
        prune_missing(conn, folder, {str(p) for p in found})
    # Weak rows from earlier runs get another chance (e.g. indexed offline).
    stale.extend(
        r["path"] for r in needs_resolution(conn)
        if r["folder"] == str(folder) and r["path"] not in stale
    )
    return stale
