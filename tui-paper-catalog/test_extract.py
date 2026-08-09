from paper_catalog.extract import find_doi, find_arxiv_id, is_junk_title, prettify_filename, largest_font_text


def test_find_doi_plain():
    assert find_doi("see 10.1145/383059.383071 for details") == "10.1145/383059.383071"


def test_find_doi_strips_trailing_punctuation():
    assert find_doi("doi:10.1145/383059.383071.") == "10.1145/383059.383071"
    assert find_doi("(10.1038/nature14539)") == "10.1038/nature14539"


def test_find_doi_absent():
    assert find_doi("no identifier here") is None
    assert find_doi("") is None
    assert find_doi(None) is None


def test_find_arxiv_id_modern():
    # Exact text pypdf extracts from the rotated margin stamp of 1706.03762.
    assert find_arxiv_id("arXiv:1706.03762v7  [cs.CL]  2 Aug 2023") == "1706.03762"


def test_find_arxiv_id_legacy():
    assert find_arxiv_id("arXiv:cs/0301001v1") == "cs/0301001"
    assert find_arxiv_id("arXiv:cs.NI/0301001") == "cs.NI/0301001"


def test_find_arxiv_id_absent():
    assert find_arxiv_id("10.1145/383059.383071") is None
    assert find_arxiv_id(None) is None


def test_is_junk_title_rejects_producer_garbage():
    assert is_junk_title("Microsoft Word - paper_final_v3.doc") is True
    assert is_junk_title("untitled document") is True
    assert is_junk_title("main.dvi") is True
    assert is_junk_title("") is True
    assert is_junk_title(None) is True
    assert is_junk_title("short") is True          # under 10 chars
    assert is_junk_title("nowhitespacetitle") is True


def test_is_junk_title_keeps_real_titles():
    assert is_junk_title("Attention Is All You Need") is False
    assert is_junk_title(
        "Chord: A Scalable Peer-to-peer Lookup Service for Internet Applications"
    ) is False


def test_prettify_filename():
    assert prettify_filename("/p/attention_is_all_you_need.pdf") == "attention is all you need"
    assert prettify_filename("/p/chord-sigcomm01.pdf") == "chord sigcomm01"
    assert prettify_filename("/p/paper (1).pdf") == "paper"
    assert prettify_filename("/p/paper copy.pdf") == "paper"


def test_largest_font_text_picks_title():
    # Measured from the real 1706.03762 PDF. The 20.0pt span is the rotated
    # arXiv margin stamp, which is LARGER than the title and must be skipped.
    spans = [
        ("arXiv:1706.03762v7  [cs.CL]  2 Aug 2023", 20.0, True),
        ("Attention Is All You Need", 17.2, False),
        ("Provided proper attribution is provided, Google hereby grants", 12.0, False),
        ("Ashish Vaswani", 10.0, False),
    ]
    assert largest_font_text(spans) == "Attention Is All You Need"


def test_largest_font_text_joins_wrapped_title():
    spans = [
        ("Chord: A Scalable Peer-to-peer Lookup Service for Internet\n", 17.9, False),
        ("Applications", 17.9, False),
        ("Ion Stoica, Robert Morris", 12.0, False),
    ]
    assert largest_font_text(spans) == (
        "Chord: A Scalable Peer-to-peer Lookup Service for Internet Applications"
    )


def test_largest_font_text_empty():
    assert largest_font_text([]) is None
    assert largest_font_text([("stamp", 20.0, True)]) is None


from paper_catalog.extract import normalize, similarity, crossref_match, better_title

CHORD_FULL = "Chord: A Scalable Peer-to-peer Lookup Service for Internet Applications"
CHORD_AUTHORS = ["Stoica", "Morris", "Karger", "Kaashoek", "Balakrishnan"]
CHORD_PAGE = (
    "Chord: A Scalable Peer-to-peer Lookup Service for Internet Applications\n"
    "Ion Stoica, Robert Morris, David Karger, M. Frans Kaashoek, Hari Balakrishnan\n"
    "MIT Laboratory for Computer Science"
)


def test_normalize():
    assert normalize("Attention Is All You Need!") == "attentionisallyouneed"
    assert normalize(None) == ""


def test_similarity_identical_and_different():
    assert similarity("Attention Is All You Need", "attention is all you need!") == 1.0
    assert similarity("Chord", CHORD_FULL) < 0.3


def test_crossref_match_accepts_on_high_similarity():
    assert crossref_match("Attention Is All You Need", [], "Attention is all you need", "") is True


def test_crossref_match_accepts_truncated_record_via_authors():
    # Crossref's real record for this paper has the title truncated to "Chord",
    # scoring 0.154 against the correct title. Author corroboration saves it.
    assert similarity("Chord", CHORD_FULL) < 0.9
    assert crossref_match("Chord", CHORD_AUTHORS, CHORD_FULL, CHORD_PAGE) is True


def test_crossref_match_rejects_wrong_paper():
    assert crossref_match(
        "A Totally Different Paper About Databases",
        ["Codd", "Date"],
        CHORD_FULL,
        CHORD_PAGE,
    ) is False


def test_crossref_match_needs_two_authors():
    assert crossref_match("Chord", ["Stoica"], CHORD_FULL, CHORD_PAGE) is False


def test_crossref_match_rejects_surnames_inside_common_words():
    # Substring matching would accept this: "chan" sits inside "mechanism"
    # and "han" inside "enhance". Word boundaries are what make the gate safe.
    assert crossref_match(
        "A Totally Unrelated Database Paper",
        ["Chan", "Han"],
        CHORD_FULL,
        "We enhance the lookup mechanism to reduce latency.",
    ) is False


def test_better_title_keeps_the_longer():
    assert better_title(CHORD_FULL, "Chord") == CHORD_FULL
    assert better_title("Chord", CHORD_FULL) == CHORD_FULL
    assert better_title(None, "Chord") == "Chord"
    assert better_title("Chord", None) == "Chord"
