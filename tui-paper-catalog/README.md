# tui-paper-catalog

A terminal browser for folders full of research PDFs. Instead of
`2103.00020v1.pdf` you see **"Learning Transferable Visual Models From Natural
Language Supervision"**, with authors and year, and you can filter by title as
you type.

Your files are never renamed, moved, or modified. The index is a separate
SQLite database.

```
┌─ All (312) ──┬─ filter: attention ─────────────────────────────────────────┐
│  Papers (128)│ Title                              Authors            Year  │
│  Reading (41)│ Attention Is All You Need          Vaswani, Shazeer…  2017  │
│  Archive (14)│ Neural Machine Translation by Jo…  Bahdanau, Cho…     2014  │
└──────────────┴──────────────────────────────────────────────────────────────┘
```

## Requirements

macOS, Python 3.11+. (Opening a paper uses Preview, and the database lives in
`~/Library/Application Support`.)

## Install

With [uv](https://docs.astral.sh/uv/):

```sh
uv tool install .
paper-catalog
```

Or run it from a clone without installing:

```sh
uv run paper-catalog
```

### Optional: a contact address

Crossref runs a "polite pool" that gives better service to requests carrying a
contact email. To use it, copy `.env.example` to `.env` and put yours in:

```sh
cp .env.example .env
```

Or set `PAPER_CATALOG_EMAIL` in your environment, which takes precedence.
Leave it unset and lookups still work — they just use the public pool.

## Usage

Press <kbd>ctrl+n</kbd> and give it a folder — `~/Papers`, an iCloud folder, a
mounted drive. It walks the folder recursively for PDFs, shows them
immediately under their filenames, then fills in real titles in the background
as they resolve. Add as many folders as you like; the sidebar counts each one.

| Key | Action |
| --- | --- |
| type anything | filter by title or author |
| <kbd>↑</kbd> <kbd>↓</kbd> | move through papers |
| <kbd>enter</kbd> | open the paper in Preview |
| <kbd>tab</kbd> | show/hide details (folder, filename, date added) |
| <kbd>esc</kbd> | clear the filter |
| <kbd>ctrl+↑</kbd> <kbd>ctrl+↓</kbd> | switch folder in the sidebar |
| <kbd>ctrl+o</kbd> | cycle sort: title → year → date added → authors |
| <kbd>ctrl+n</kbd> | add a folder |
| <kbd>ctrl+x</kbd> | remove the selected folder from the index |
| <kbd>ctrl+r</kbd> | rescan every folder |
| <kbd>ctrl+q</kbd> | quit |

<kbd>ctrl+x</kbd> removes a folder from the *index* only. Nothing on disk is
touched.

## How titles are found

Each PDF goes down a ladder and stops at the first rung that gives a
trustworthy answer:

1. **A DOI or arXiv ID printed in the paper** → looked up on
   [Crossref](https://www.crossref.org/) or [arXiv](https://arxiv.org/).
   Because the ID in the text might belong to a *cited* paper, the returned
   record has to corroborate against the PDF's own text before it's accepted.
2. **A title read out of the PDF** → searched on Crossref, again only accepted
   if it corroborates.
3. **The PDF itself** — its metadata title, or the largest text on page 1.
4. **The filename**, tidied up.

Rungs 3 and 4 are marked as weak and retried on the next <kbd>ctrl+r</kbd>, so
papers indexed while offline get a proper title later. Files that haven't
changed are never re-read.

## Where things live

- Index: `~/Library/Application Support/paper-catalog/index.db`
- Delete that file to start over. Your PDFs are unaffected.

## Notes

- Only Crossref and arXiv are contacted, and only for papers that need
  resolving. arXiv requests are throttled to stay inside its rate limit.
- An unreachable folder (unmounted drive, revoked permission) greys out in the
  sidebar and its rows are kept rather than deleted.
- Encrypted or malformed PDFs fall back to the filename instead of failing.

## Development

```sh
uv run pytest
```
