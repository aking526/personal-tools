import shutil
from pathlib import Path

import pytest
from paper_catalog import index as ix


@pytest.fixture
def conn(tmp_path):
    c = ix.connect(tmp_path / "t.db")
    ix.init_db(c)
    yield c
    c.close()


def test_folder_crud(conn):
    ix.add_folder(conn, "/papers/net")
    ix.add_folder(conn, "/papers/ml")
    ix.add_folder(conn, "/papers/net")               # idempotent
    assert ix.list_folders(conn) == ["/papers/ml", "/papers/net"]
    ix.remove_folder(conn, "/papers/ml")
    assert ix.list_folders(conn) == ["/papers/net"]


def test_upsert_placeholder_reports_new_and_changed(conn):
    ix.add_folder(conn, "/papers")
    assert ix.upsert_placeholder(conn, "/papers/a.pdf", "/papers", "a", 100.0, 5, 90.0) is True
    # Unchanged (path, mtime, size) -> cached, no re-resolution.
    assert ix.upsert_placeholder(conn, "/papers/a.pdf", "/papers", "a", 100.0, 5, 90.0) is False
    # Changed mtime -> stale.
    assert ix.upsert_placeholder(conn, "/papers/a.pdf", "/papers", "a", 200.0, 5, 90.0) is True
    # Changed size -> stale.
    assert ix.upsert_placeholder(conn, "/papers/a.pdf", "/papers", "a", 200.0, 9, 90.0) is True


def test_upsert_placeholder_resets_source_on_change(conn):
    """A changed file must re-enter the queue however strong its old source.

    This is the cache-invalidation heart of the app: without the reset, an
    edited PDF keeps a stale title forever.
    """
    ix.add_folder(conn, "/papers")
    ix.upsert_placeholder(conn, "/papers/a.pdf", "/papers", "a", 100.0, 5, 90.0)
    ix.save_resolution(
        conn, "/papers/a.pdf", title="Attention Is All You Need",
        authors="Vaswani", year=2017, doi=None, arxiv_id="1706.03762", source="arxiv",
    )
    assert ix.needs_resolution(conn) == []          # strong source: not queued
    ix.upsert_placeholder(conn, "/papers/a.pdf", "/papers", "a", 200.0, 5, 90.0)
    row = ix.list_papers(conn)[0]
    assert row["source"] == "filename"              # reset, not left as 'arxiv'
    assert row["title"] == "a"                      # placeholder restored
    assert [r["path"] for r in ix.needs_resolution(conn)] == ["/papers/a.pdf"]


def test_save_resolution_and_list(conn):
    ix.add_folder(conn, "/papers")
    ix.upsert_placeholder(conn, "/papers/a.pdf", "/papers", "a", 1.0, 5, 1.0)
    ix.save_resolution(
        conn, "/papers/a.pdf",
        title="Attention Is All You Need", authors="Vaswani, Shazeer",
        year=2017, doi=None, arxiv_id="1706.03762", source="arxiv",
    )
    row = ix.list_papers(conn)[0]
    assert row["title"] == "Attention Is All You Need"
    assert row["year"] == 2017
    assert row["source"] == "arxiv"


def test_needs_resolution_selects_weak_sources_only(conn):
    ix.add_folder(conn, "/papers")
    for name, source in [("a", "arxiv"), ("b", "local"), ("c", "filename"), ("d", "crossref")]:
        ix.upsert_placeholder(conn, f"/papers/{name}.pdf", "/papers", name, 1.0, 5, 1.0)
        ix.save_resolution(
            conn, f"/papers/{name}.pdf", title=name, authors=None,
            year=None, doi=None, arxiv_id=None, source=source,
        )
    assert sorted(r["path"] for r in ix.needs_resolution(conn)) == [
        "/papers/b.pdf", "/papers/c.pdf",
    ]


def test_prune_missing(conn):
    ix.add_folder(conn, "/papers")
    for name in ("a", "b"):
        ix.upsert_placeholder(conn, f"/papers/{name}.pdf", "/papers", name, 1.0, 5, 1.0)
    ix.prune_missing(conn, "/papers", {"/papers/a.pdf"})
    assert [r["path"] for r in ix.list_papers(conn)] == ["/papers/a.pdf"]


def test_list_papers_filters_by_folder(conn):
    ix.add_folder(conn, "/net")
    ix.add_folder(conn, "/ml")
    ix.upsert_placeholder(conn, "/net/a.pdf", "/net", "a", 1.0, 5, 1.0)
    ix.upsert_placeholder(conn, "/ml/b.pdf", "/ml", "b", 1.0, 5, 1.0)
    assert [r["path"] for r in ix.list_papers(conn, folder="/net")] == ["/net/a.pdf"]
    assert len(ix.list_papers(conn)) == 2


def test_removing_folder_cascades_to_papers(conn):
    ix.add_folder(conn, "/net")
    ix.upsert_placeholder(conn, "/net/a.pdf", "/net", "a", 1.0, 5, 1.0)
    ix.remove_folder(conn, "/net")
    assert ix.list_papers(conn) == []


def test_scan_keeps_rows_when_folder_unreachable(conn, tmp_path):
    """An unmounted drive must not wipe a folder's index.

    walk_pdfs returns [] for an unreachable root, and pruning on that empty
    result would delete every row the folder has.
    """
    folder = tmp_path / "papers"
    folder.mkdir()
    (folder / "a.pdf").write_bytes(b"%PDF-1.4 placeholder")
    ix.add_folder(conn, str(folder))
    assert len(ix.scan(conn, str(folder))) == 1
    assert len(ix.list_papers(conn)) == 1

    shutil.rmtree(folder)                       # drive unmounts
    ix.scan(conn, str(folder))
    assert len(ix.list_papers(conn)) == 1       # rows retained, not pruned


def test_scan_prunes_when_folder_is_genuinely_empty(conn, tmp_path):
    """The retention guard must not stop real deletions from pruning."""
    folder = tmp_path / "papers"
    folder.mkdir()
    pdf = folder / "a.pdf"
    pdf.write_bytes(b"%PDF-1.4 placeholder")
    ix.add_folder(conn, str(folder))
    ix.scan(conn, str(folder))

    pdf.unlink()                                # folder still readable
    ix.scan(conn, str(folder))
    assert ix.list_papers(conn) == []           # pruned, as it should be


def test_walk_pdfs_finds_all_case_variants_recursively(tmp_path):
    """Regression guard for Fix 1: rglob("*.pdf") alone misses B.PDF on POSIX."""
    (tmp_path / "a.pdf").write_bytes(b"")
    (tmp_path / "B.PDF").write_bytes(b"")
    (tmp_path / "sub").mkdir()
    (tmp_path / "sub" / "deep.pdf").write_bytes(b"")
    (tmp_path / ".hidden").mkdir()
    (tmp_path / ".hidden" / "x.pdf").write_bytes(b"")
    (tmp_path / "notes.txt").write_bytes(b"")

    found = {p.relative_to(tmp_path) for p in ix.walk_pdfs(tmp_path)}
    assert found == {Path("a.pdf"), Path("B.PDF"), Path("sub/deep.pdf")}


# --- resolve() ladder, offline against real PDFs, network stubbed ----------
#
# resolve(path, client) takes the HTTP client as a plain parameter, so a
# stub client exercises every rung with no network. The offline half (rungs
# 3/4) needs real PDF bytes though - pypdf's text/font extraction isn't worth
# hand-rolling a fixture for - so these reuse the two PDFs already fetched
# for manual verification. If they're not present (e.g. a fresh checkout
# with no network access), skip rather than fail the suite.

PI_CHECK = Path("/tmp/pi-check")
ATTN_PDF = PI_CHECK / "attn.pdf"
CHORD_PDF = PI_CHECK / "chord.pdf"

requires_test_pdfs = pytest.mark.skipif(
    not (ATTN_PDF.exists() and CHORD_PDF.exists()),
    reason="fixture PDFs missing at /tmp/pi-check (see task notes to re-download)",
)


class StubResponse:
    def __init__(self, status_code=200, json_data=None, text=""):
        self.status_code = status_code
        self._json = json_data
        self.text = text

    def json(self):
        return self._json


class StubClient:
    """Fake httpx.Client for resolve()'s three resolvers. No network."""

    def __init__(self, doi=None, search=None, arxiv=None):
        self.doi_response = doi
        self.search_response = search
        self.arxiv_response = arxiv
        self.calls: list[str] = []

    def get(self, url, params=None, timeout=None):
        self.calls.append(url)
        if url == "https://api.crossref.org/works" and self.search_response is not None:
            return self.search_response
        if url.startswith("https://api.crossref.org/works/") and self.doi_response is not None:
            return self.doi_response
        if url == ix.ARXIV_URL and self.arxiv_response is not None:
            return self.arxiv_response
        return StubResponse(status_code=404)


def crossref_work(title, authors, year, doi="10.1/x"):
    return {
        "title": [title],
        "author": [{"family": a} for a in authors],
        "issued": {"date-parts": [[year]]},
        "DOI": doi,
    }


def crossref_message(title, authors, year, doi="10.1/x"):
    """Response body for the single-work DOI lookup (crossref_by_doi)."""
    return {"message": crossref_work(title, authors, year, doi)}


def crossref_search_result(title, authors, year, doi="10.1/x"):
    """Response body for the bibliographic search (crossref_search) - a
    message.items[] wrapper, not the flat single-work shape the DOI endpoint
    returns."""
    return {"message": {"items": [crossref_work(title, authors, year, doi)]}}


@requires_test_pdfs
def test_resolve_rung2_crossref_search_success():
    hit = crossref_search_result(
        "Chord: A Scalable Peer-to-peer Lookup Service for Internet Applications",
        ["Stoica", "Morris", "Karger", "Kaashoek", "Balakrishnan"],
        2001,
    )
    client = StubClient(search=StubResponse(json_data=hit))
    result = ix.resolve(CHORD_PDF, client)
    assert result["source"] == "crossref"
    assert result["authors"] == "Stoica, Morris, Karger, Kaashoek, Balakrishnan"
    assert result["year"] == 2001


@requires_test_pdfs
def test_resolve_better_title_keeps_longer_local_title_on_truncated_record():
    """Crossref's real record for Chord truncates the title to just 'Chord'."""
    hit = crossref_search_result("Chord", ["Stoica", "Morris", "Karger", "Kaashoek"], 2001)
    client = StubClient(search=StubResponse(json_data=hit))
    result = ix.resolve(CHORD_PDF, client)
    assert result["source"] == "crossref"          # matched via author corroboration
    assert result["title"] == (
        "Chord: A Scalable Peer-to-peer Lookup Service for Internet Applications"
    )
    assert result["authors"] == "Stoica, Morris, Karger, Kaashoek"
    assert result["year"] == 2001


def test_resolve_rung2_skipped_unless_local_source_is_local(monkeypatch):
    monkeypatch.setattr(ix, "resolve_offline", lambda path: {
        "title": "some file", "authors": None, "year": None,
        "doi": None, "arxiv_id": None, "source": "filename", "page_text": "",
    })
    client = StubClient(search=StubResponse(json_data=crossref_message("some file", ["X", "Y"], 1999)))
    result = ix.resolve("/fake/path.pdf", client)
    assert client.calls == []                       # rung 2 never attempted
    assert result["source"] == "filename"


@requires_test_pdfs
def test_resolve_never_raises_when_every_call_fails(monkeypatch):
    monkeypatch.setattr(ix, "_arxiv_throttle", lambda: None)   # no real sleep in tests

    class DeadClient:
        def get(self, *a, **k):
            raise ConnectionError("no network")

    result = ix.resolve(ATTN_PDF, DeadClient())      # must not raise
    assert result["source"] == "local"
    assert result["title"] == "Attention Is All You Need"


@requires_test_pdfs
def test_resolve_rung1_doi_gate_rejects_mismatched_record(monkeypatch):
    """A DOI in the body text can be a cited work's, not the paper's own.

    Fix 4's regression guard: chord.pdf has no embedded DOI, so find_doi is
    monkeypatched to simulate one being found (e.g. in a footnote). The
    Crossref record it "resolves" to belongs to an unrelated paper, so the
    gate must reject it and leave the row on rung 3 rather than accepting
    wrong metadata under a strong source.
    """
    monkeypatch.setattr(ix, "find_doi", lambda text: "10.9999/wrong-citation")
    bad_hit = crossref_message("Some Unrelated Paper", ["Nobody", "Anonymous"], 1990)
    empty_search = {"message": {"items": []}}
    client = StubClient(
        doi=StubResponse(json_data=bad_hit),
        search=StubResponse(json_data=empty_search),
    )
    result = ix.resolve(CHORD_PDF, client)
    assert result["source"] == "local"               # rejected: rung 3 stands
    assert any(c.endswith("10.9999/wrong-citation") for c in client.calls)


def test_contact_email_env_wins_then_file_then_nothing(tmp_path, monkeypatch):
    env_file = tmp_path / ".env"
    env_file.write_text('# comment\nPAPER_CATALOG_EMAIL="file@example.com"\nOTHER=x\n')
    monkeypatch.setenv("PAPER_CATALOG_EMAIL", "env@example.com")
    assert ix.contact_email(env_file) == "env@example.com"
    monkeypatch.delenv("PAPER_CATALOG_EMAIL")
    assert ix.contact_email(env_file) == "file@example.com"      # quotes stripped
    assert ix.contact_email(tmp_path / "missing") is None        # no file, no crash
    monkeypatch.setenv("PAPER_CATALOG_EMAIL", "env@example.com")
    assert ix.user_agent() == "tui-paper-catalog/0.1 (mailto:env@example.com)"
    monkeypatch.setattr(ix, "contact_email", lambda *a: None)
    assert ix.user_agent() == "tui-paper-catalog/0.1"                 # no address, no mailto
