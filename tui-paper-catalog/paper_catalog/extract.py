"""Pure heuristics for turning PDF bytes-derived text into paper metadata.

Every function here takes plain data and returns plain data. No disk, no
network — that keeps the whole module testable without a PDF present.
"""

import re
from difflib import SequenceMatcher
from pathlib import Path

DOI_RE = re.compile(r"\b10\.\d{4,9}/[-._;()/:A-Za-z0-9]+", re.IGNORECASE)
ARXIV_MODERN_RE = re.compile(r"arXiv:\s*(\d{4}\.\d{4,5})(?:v\d+)?", re.IGNORECASE)
ARXIV_LEGACY_RE = re.compile(
    r"arXiv:\s*([a-z-]+(?:\.[A-Z]{2})?/\d{7})(?:v\d+)?", re.IGNORECASE
)


def find_doi(text: str | None) -> str | None:
    """First DOI in `text`, with trailing sentence punctuation removed."""
    match = DOI_RE.search(text or "")
    if not match:
        return None
    return match.group(0).rstrip(".,;:)]}>")


def find_arxiv_id(text: str | None) -> str | None:
    """First arXiv identifier in `text`, modern or legacy form, version stripped."""
    text = text or ""
    match = ARXIV_MODERN_RE.search(text) or ARXIV_LEGACY_RE.search(text)
    return match.group(1) if match else None


JUNK_PREFIXES = (
    "microsoft word",
    "microsoft powerpoint",
    "untitled",
    "no title",
    "document1",
    "doc1",
)
JUNK_SUFFIXES = (".doc", ".docx", ".dvi", ".tex", ".pdf", ".ps", ".rtf", ".indd", ".qxd")


def is_junk_title(s: str | None) -> bool:
    """True when a PDF's /Title is producer garbage rather than a paper title.

    LaTeX with hyperref usually leaves /Title unset entirely; when it IS set,
    it is very often the source filename.
    """
    if not s:
        return True
    title = s.strip()
    if len(title) < 10:
        return True
    if " " not in title:
        return True
    low = title.lower()
    return low.startswith(JUNK_PREFIXES) or low.endswith(JUNK_SUFFIXES)


def prettify_filename(path: str) -> str:
    """Last-resort title: the filename stem, de-slugged."""
    stem = Path(path).stem
    stem = re.sub(r"[_\-]+", " ", stem)
    stem = re.sub(r"\s*\(\d+\)$", "", stem)       # "paper (1)"
    stem = re.sub(r"\s+copy$", "", stem, flags=re.IGNORECASE)
    stem = re.sub(r"\s+", " ", stem).strip()
    return stem or Path(path).name


def largest_font_text(spans: list[tuple[str, float, bool]]) -> str | None:
    """Title = the text set in the largest font on page 1.

    Rotated spans are dropped first: arXiv stamps its identifier vertically up
    the left margin at a LARGER size than the title, so it would otherwise win.
    """
    buckets: dict[float, str] = {}
    for text, size, rotated in spans:
        if rotated or not text.strip():
            continue
        buckets.setdefault(round(size, 1), "")
        buckets[round(size, 1)] += text
    if not buckets:
        return None
    winner = buckets[max(buckets)]
    return re.sub(r"\s+", " ", winner).strip() or None


SIMILARITY_THRESHOLD = 0.9
MIN_AUTHOR_HITS = 2
MIN_SURNAME_LEN = 3


def normalize(s: str | None) -> str:
    """Casefold and strip everything that is not alphanumeric."""
    return re.sub(r"[^a-z0-9]+", "", (s or "").lower())


def similarity(a: str | None, b: str | None) -> float:
    return SequenceMatcher(None, normalize(a), normalize(b)).ratio()


def crossref_match(
    cr_title: str | None,
    cr_authors: list[str],
    local_title: str | None,
    page_text: str | None,
) -> bool:
    """Gate for accepting a Crossref bibliographic-search hit.

    Similarity alone is not enough: Crossref's record for the Chord paper has
    its title truncated to "Chord", which scores 0.154 against the correct
    title. Author surnames appearing in the page text settle it instead.
    Surnames match on word boundaries only. Plain substring matching accepts
    wrong papers: "Chan" occurs inside "mechanism", "Han" inside "enhance".
    """
    if similarity(cr_title, local_title) >= SIMILARITY_THRESHOLD:
        return True
    haystack = page_text or ""
    hits = sum(
        1
        for author in set(cr_authors)          # dedupe: one name, one vote
        if author
        and len(author) >= MIN_SURNAME_LEN
        and re.search(rf"\b{re.escape(author)}\b", haystack, re.IGNORECASE)
    )
    return hits >= MIN_AUTHOR_HITS


def better_title(local: str | None, remote: str | None) -> str | None:
    """Prefer the longer title — Crossref records are sometimes truncated."""
    if not remote:
        return local
    if not local:
        return remote
    return remote if len(remote) > len(local) else local
