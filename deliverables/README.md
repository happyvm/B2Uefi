# Deliverables

Stakeholder documents derived from this repository, designed to be converted to Word **outside** this repository.

| File | Document | Audience |
|---|---|---|
| `DAT-Migration-BIOS-UEFI.md` | Technical Architecture Document | Architects, technical validation, project governance |
| `DEX-Migration-BIOS-UEFI.md` | Operations Runbook | Operators, L2/L3 on-call |

The `DAT-` and `DEX-` filename prefixes and the `DAT-B2UEFI-001` / `DEX-B2UEFI-001` reference codes are kept as stable document identifiers.

## Why these are separate from `docs/`

`docs/` is the engineering documentation: it lives next to the code and cross-links freely between files. These two documents are **contractual deliverables** instead. They are:

- **Self-contained** — no relative links to repository files, because those become dead links the moment the document is converted to Word and circulated. Everything needed to read the document is inside it.
- **Structured for Word** — YAML front matter carries the title, author, table of contents and its heading, so the conversion needs no extra flags.

They deliberately duplicate some content from `docs/`. That duplication is the point: a deliverable that only works while you have the repository checked out is not a deliverable.

## Converting to Word

Both files are plain Markdown with YAML front matter. No LaTeX, no HTML, no diagrams requiring a renderer — only headings, tables, lists, code blocks and block quotes, all of which map cleanly onto Word styles.

### With pandoc (recommended)

```bash
pandoc DAT-Migration-BIOS-UEFI.md -o DAT-Migration-BIOS-UEFI.docx \
  --toc --toc-depth=3 --number-sections
```

The table of contents, its heading and the section numbering all come from the front matter, so the command stays the same for both documents.

> On a system whose locale is not UTF-8, run `export LANG=C.UTF-8` first. Passing non-ASCII text as a command-line argument under a POSIX locale corrupts it — which is why the TOC title lives in the front matter rather than in a `--metadata` flag.

### Page breaks before each chapter

Pandoc drops LaTeX `\newpage` when producing Word, so these documents do not use it. To get a page break before every level-1 heading, generate a reference document and enable "page break before" on its *Heading 1* style:

```bash
pandoc --print-default-data-file reference.docx > reference.docx
# Open reference.docx in Word -> Styles -> Heading 1 -> Modify
#   -> Format -> Paragraph -> Line and Page Breaks -> tick "Page break before"
pandoc DAT-Migration-BIOS-UEFI.md -o DAT.docx --toc --number-sections \
  --reference-doc=reference.docx
```

The same reference document also lets you apply your organization's fonts, colors and headers/footers in one place, for both deliverables at once.

### Without pandoc

Any Markdown-to-Word route works, since the files avoid renderer-specific syntax: paste into Word via a Markdown-aware editor, or use an online converter. Only the automatic table of contents and section numbering are lost — Word can regenerate both natively (References → Table of Contents).

## Before circulating

Both documents contain placeholders marked `*(to be completed)*` in their header tables — author, validator, approver, dates, change-ticket references. Fill these in before distribution.

The support dates and vendor tool availability quoted in the DAT were accurate when written and are sourced in the document itself. Re-verify them against the vendors before committing to a schedule.
