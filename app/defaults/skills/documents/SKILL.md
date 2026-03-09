---
name: documents
description: Generate PDFs, DOCX files, and other documents using Typst, Pandoc, and Playwright.
---

# Document Generation

## Quick Reference

| Scenario | Tool | Command |
|----------|------|---------|
| PDF from scratch (invoices, letters, reports) | Typst | `typst compile doc.typ output.pdf` |
| Markdown to PDF | Pandoc + Typst | `pandoc input.md -o output.pdf --pdf-engine=typst` |
| Markdown to DOCX | Pandoc | `pandoc input.md -o output.docx` |
| HTML to PDF (complex web layouts) | Playwright | `browser_pdf_save` or scripted `page.pdf()` |
| Format conversion (DOCX, EPUB, HTML, etc.) | Pandoc | `pandoc input.X -o output.Y` |

Save all generated files to `~/output/`. Save reusable templates to `~/templates/`.

---

## Typst (Recommended for PDFs)

Typst is the primary tool for generating PDFs. It compiles `.typ` files to PDF with excellent typography, tables, and layout control.

### Basic Usage

```bash
typst compile document.typ ~/output/document.pdf
```

### Markup Syntax Reference

| Element | Syntax |
|---------|--------|
| Heading 1 | `= Heading` |
| Heading 2 | `== Heading` |
| Heading 3 | `=== Heading` |
| Bold | `*bold text*` |
| Italic | `_italic text_` |
| Link | `#link("https://example.com")[Label]` |
| Unordered list | `- Item` |
| Ordered list | `+ Item` |
| Code inline | `` `code` `` |
| Code block | `` ```lang ... ``` `` |
| Image | `#image("path.png", width: 50%)` |
| Page break | `#pagebreak()` |
| Horizontal rule | `#line(length: 100%)` |

### Page Setup

```typst
#set page(paper: "a4", margin: (x: 2cm, y: 2.5cm))
#set text(font: "Linux Libertine", size: 11pt, lang: "en")
#set par(justify: true, leading: 0.65em)
```

### Invoice Template

```typst
#set page(paper: "a4", margin: (x: 2cm, y: 2cm))
#set text(size: 10pt)

// --- Company header ---
#align(right)[
  *Acme Corp.* \
  123 Business Ave \
  San Francisco, CA 94102 \
  Phone: +1 415 555-0100 \
  billing\@acmecorp.com \
  Tax ID: US12-3456789
]

#v(1cm)

// --- Recipient ---
Example Industries Ltd. \
456 Client Street \
New York, NY 10001

#v(1cm)

// --- Invoice metadata ---
#grid(
  columns: (1fr, auto),
  align(left)[
    *Invoice*
  ],
  align(right)[
    Invoice No.: 2026-042 \
    Date: March 8, 2026 \
    Service period: February 2026
  ],
)

#v(0.5cm)
#line(length: 100%, stroke: 0.5pt)
#v(0.5cm)

Dear Sir or Madam,

please find below the charges for services rendered:

#v(0.5cm)

// --- Line items table ---
#table(
  columns: (auto, 1fr, auto, auto, auto),
  align: (center, left, right, right, right),
  stroke: none,
  inset: (x: 8pt, y: 6pt),
  table.header(
    table.hline(stroke: 0.5pt),
    [*No.*], [*Description*], [*Qty*], [*Unit Price*], [*Total*],
    table.hline(stroke: 0.5pt),
  ),
  [1], [Frontend Development], [40 hrs], [95.00 USD], [3,800.00 USD],
  [2], [API Integration], [16 hrs], [110.00 USD], [1,760.00 USD],
  [3], [Hosting & Maintenance (monthly)], [1], [250.00 USD], [250.00 USD],
  table.hline(stroke: 0.5pt),
)

// --- Totals ---
#align(right)[
  #grid(
    columns: (auto, 8em),
    row-gutter: 6pt,
    align: (left, right),
    [Subtotal:], [5,810.00 USD],
    [Tax (10%):], [581.00 USD],
    table.hline(stroke: 1pt),
    [*Total:*], [*6,391.00 USD*],
  )
]

#v(1cm)

Please transfer the amount within 14 days to the following account:

#v(0.3cm)
Account: 0532-0130-00 \
Routing: 037040044 \
Reference: INV-2026-042

#v(1cm)
Kind regards,

#v(1cm)
John Smith \
Managing Director
```

### Business Letter Template

```typst
#set page(paper: "a4", margin: (top: 3cm, bottom: 2.5cm, x: 2.5cm))
#set text(size: 11pt, lang: "en")
#set par(justify: true)

// --- Sender ---
#text(size: 8pt, fill: gray)[
  Acme Corp. · 123 Business Ave · San Francisco, CA 94102
]

#v(0.5cm)

// --- Recipient ---
Ms. Jane Doe \
Example Industries Ltd. \
456 Client Street \
New York, NY 10001

#v(1cm)

// --- Date ---
#align(right)[San Francisco, March 8, 2026]

#v(1cm)

// --- Subject ---
*Re: Proposal for Software Development*

#v(0.5cm)

Dear Ms. Doe,

thank you for your inquiry dated March 1, 2026. We are pleased to submit
the following proposal for the development of your web application.

The project includes the following deliverables:

- UI/UX design and prototyping
- Frontend development with React and TypeScript
- Backend API with Node.js
- Deployment and documentation

The estimated effort is 320 hours at a rate of 95.00 USD per hour (net).
The expected project duration is 8 weeks from contract signing.

This proposal is valid for 30 days. Please do not hesitate to reach out
if you have any questions.

#v(0.5cm)

Kind regards,

#v(1.5cm)

John Smith \
Managing Director
```

### Report Template

```typst
#set page(
  paper: "a4",
  margin: (x: 2.5cm, y: 2.5cm),
  header: context {
    if counter(page).get().first() > 1 [
      _Project Report Q1/2026_
      #h(1fr)
      #counter(page).display("1 / 1", both: true)
    ]
  },
)
#set text(size: 11pt, lang: "en")
#set heading(numbering: "1.1")
#set par(justify: true, leading: 0.65em)

// --- Title page ---
#v(4cm)
#align(center)[
  #text(size: 24pt, weight: "bold")[Project Report Q1/2026]

  #v(0.5cm)
  #text(size: 14pt, fill: gray)[Acme Corp.]

  #v(0.3cm)
  #text(size: 12pt)[March 8, 2026]
]

#pagebreak()

// --- Table of contents ---
#outline(title: "Table of Contents", indent: auto)

#pagebreak()

// --- Content ---
= Executive Summary

This document summarizes the results of the first quarter. Key metrics
show a positive trend across all project areas.

= Project Status

== Milestones

#table(
  columns: (1fr, auto, auto),
  align: (left, center, center),
  inset: 8pt,
  table.header(
    [*Milestone*], [*Target Date*], [*Status*],
  ),
  [MVP Release], [Jan 15, 2026], [Completed],
  [Beta Launch], [Feb 28, 2026], [Completed],
  [Public Launch], [Mar 31, 2026], [In Progress],
)

== Technical Architecture

The architecture is based on a microservice design with the following
components:

+ API Gateway (Traefik)
+ Backend Services (Go, TypeScript)
+ Database (PostgreSQL with HA)
+ Monitoring (Prometheus + Grafana)

= Outlook

In the second quarter we will focus on:

- Scaling the infrastructure
- Onboarding the first customers
- Expanding the API surface

= Appendix

Further details available upon request.
```

---

## Pandoc (Format Conversion)

Pandoc converts between document formats. Most useful for Markdown to DOCX or using Markdown as a simpler input for PDFs.

### Markdown to PDF (via Typst)

```bash
pandoc input.md -o ~/output/document.pdf --pdf-engine=typst
```

With custom Typst template:

```bash
pandoc input.md -o ~/output/document.pdf --pdf-engine=typst --template=~/templates/report.typst
```

### Markdown to DOCX

```bash
pandoc input.md -o ~/output/document.docx
```

With a reference document for styling (fonts, heading styles, margins):

```bash
pandoc input.md -o ~/output/document.docx --reference-doc=~/templates/reference.docx
```

To create a reference doc, generate a default one and edit it in a word processor:

```bash
pandoc -o ~/templates/reference.docx --print-default-data-file reference.docx
```

### Other Useful Conversions

```bash
# DOCX to Markdown
pandoc input.docx -o output.md

# Markdown to HTML
pandoc input.md -o output.html --standalone

# HTML to Markdown
pandoc input.html -o output.md

# EPUB generation
pandoc input.md -o output.epub --metadata title="My Book"
```

---

## Playwright (HTML to PDF)

For complex layouts that need CSS styling or rendering of web content, use the Playwright browser (already installed).

### Using the MCP Tool

The simplest approach for single pages:

```
browser_navigate(url="file:///home/atlas/output/report.html")
browser_pdf_save(filename="report.pdf")
```

### Scripted Approach

For more control, write a quick Node.js script:

```javascript
// ~/helpers/html-to-pdf.mjs
import { chromium } from 'playwright';

const [input, output] = process.argv.slice(2);
const browser = await chromium.launch();
const page = await browser.newPage();
await page.goto(`file://${input}`, { waitUntil: 'networkidle' });
await page.pdf({
  path: output,
  format: 'A4',
  margin: { top: '2cm', bottom: '2cm', left: '2cm', right: '2cm' },
  printBackground: true,
});
await browser.close();
```

```bash
node ~/helpers/html-to-pdf.mjs /home/atlas/output/report.html /home/atlas/output/report.pdf
```

---

## Best Practices

- **Output directory**: Always save generated files to `~/output/` so they can be easily shared or attached.
- **Templates**: Save reusable `.typ` templates to `~/templates/` for consistent formatting across documents.
- **Typst first**: Prefer Typst for PDF generation. It is fast, produces high-quality output, and has a simple syntax. Use Pandoc mainly for format conversion or when the source is already Markdown. Use Playwright only when CSS rendering fidelity matters.
- **Localization**: Set `#set text(lang: "de")` (or other language code) in Typst for correct hyphenation. Use `#set page(paper: "a4")` for standard European page size, or `"us-letter"` for US.
- **Fonts**: The container ships with standard system fonts. Typst also bundles its own fonts. To list available fonts: `typst fonts`.
