# Deliverables

Stakeholder documents derived from this repository, written in French and designed to be converted to Word **outside** this repository.

| File | Document | Audience |
|---|---|---|
| `DAT-Migration-BIOS-UEFI.md` | Dossier d'Architecture Technique (technical architecture document) | Architects, technical validation, project governance |
| `DEX-Migration-BIOS-UEFI.md` | Document d'Exploitation (operations runbook) | Operators, on-call N2/N3 |

## Why these are separate from `docs/`

`docs/` is the engineering documentation: it lives next to the code, is written in English, and cross-links freely between files. These two documents are **contractual deliverables** instead. They are:

- **Self-contained** — no relative links to repository files, because those become dead links the moment the document is converted to Word and circulated. Everything needed to read the document is inside it.
- **In French** — a DAT and a dossier d'exploitation are French deliverable formats addressed to French stakeholders and governance.
- **Structured for Word** — YAML front matter carries the title, author, table of contents and its French heading, so the conversion needs no extra flags.

They deliberately duplicate some content from `docs/`. That duplication is the point: a deliverable that only works while you have the repository checked out is not a deliverable.

## Converting to Word

Both files are plain Markdown with YAML front matter. No LaTeX, no HTML, no diagrams requiring a renderer — only headings, tables, lists, code blocks and block quotes, all of which map cleanly onto Word styles.

### With pandoc (recommended)

```bash
pandoc DAT-Migration-BIOS-UEFI.md -o DAT-Migration-BIOS-UEFI.docx \
  --toc --toc-depth=3 --number-sections
```

The table of contents, its French heading and the section numbering all come from the front matter, so the command stays the same for both documents.

> On a system whose locale is not UTF-8, run `export LANG=C.UTF-8` first. Passing accented text as a command-line argument on a POSIX locale corrupts it — which is exactly why the TOC title lives in the front matter rather than in a `--metadata` flag.

### Page breaks before each chapter

Pandoc drops LaTeX `\newpage` when producing Word, so these documents do not use it. To get a page break before every level-1 heading, generate a reference document and enable "page break before" on its *Heading 1* style:

```bash
pandoc --print-default-data-file reference.docx > reference.docx
# Open reference.docx in Word -> Styles -> Heading 1 -> Modify
#   -> Format -> Paragraph -> Line and Page Breaks -> tick "Page break before"
pandoc DAT-Migration-BIOS-UEFI.md -o DAT.docx --toc --number-sections \
  --reference-doc=reference.docx
```

The same reference document also lets you apply your organisation's fonts, colours and headers/footers in one place, for both deliverables at once.

### Without pandoc

Any Markdown-to-Word route works, since the files avoid renderer-specific syntax: paste into Word via a Markdown-aware editor, or use an online converter. Only the automatic table of contents and section numbering are lost — Word can regenerate both natively (References → Table of Contents).

## Before circulating

Both documents contain placeholders marked `*(à compléter)*` in their header tables — author, validator, approver, dates, change-ticket references. Fill these in before distribution.

The support dates and vendor tool availability quoted in the DAT were accurate when written and are sourced in the document itself. Re-verify them against the vendors before committing to a schedule.
