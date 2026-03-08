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
#set text(font: "Linux Libertine", size: 11pt, lang: "de")
#set par(justify: true, leading: 0.65em)
```

### Invoice Template

```typst
#set page(paper: "a4", margin: (x: 2cm, y: 2cm))
#set text(size: 10pt)

// --- Company header ---
#align(right)[
  *Musterfirma GmbH* \
  Musterstraße 42 \
  70173 Stuttgart \
  Tel: +49 711 1234567 \
  info\@musterfirma.de \
  USt-IdNr.: DE123456789
]

#v(1cm)

// --- Recipient ---
Beispielkunde AG \
Kundenweg 7 \
80331 München

#v(1cm)

// --- Invoice metadata ---
#grid(
  columns: (1fr, auto),
  align(left)[
    *Rechnung*
  ],
  align(right)[
    Rechnungsnummer: 2026-042 \
    Datum: 08.03.2026 \
    Leistungszeitraum: Februar 2026
  ],
)

#v(0.5cm)
#line(length: 100%, stroke: 0.5pt)
#v(0.5cm)

Sehr geehrte Damen und Herren,

für die erbrachten Leistungen berechnen wir wie folgt:

#v(0.5cm)

// --- Line items table ---
#table(
  columns: (auto, 1fr, auto, auto, auto),
  align: (center, left, right, right, right),
  stroke: none,
  inset: (x: 8pt, y: 6pt),
  table.header(
    table.hline(stroke: 0.5pt),
    [*Pos.*], [*Beschreibung*], [*Menge*], [*Einzelpreis*], [*Gesamt*],
    table.hline(stroke: 0.5pt),
  ),
  [1], [Webentwicklung Frontend], [40 Std.], [95,00 EUR], [3.800,00 EUR],
  [2], [API-Integration], [16 Std.], [110,00 EUR], [1.760,00 EUR],
  [3], [Hosting & Wartung (monatl.)], [1], [250,00 EUR], [250,00 EUR],
  table.hline(stroke: 0.5pt),
)

// --- Totals ---
#align(right)[
  #grid(
    columns: (auto, 8em),
    row-gutter: 6pt,
    align: (left, right),
    [Nettobetrag:], [5.810,00 EUR],
    [USt. 19%:], [1.103,90 EUR],
    table.hline(stroke: 1pt),
    [*Gesamtbetrag:*], [*6.913,90 EUR*],
  )
]

#v(1cm)

Bitte überweisen Sie den Betrag innerhalb von 14 Tagen auf folgendes Konto:

#v(0.3cm)
IBAN: DE89 3704 0044 0532 0130 00 \
BIC: COBADEFFXXX \
Verwendungszweck: RE-2026-042

#v(1cm)
Mit freundlichen Grüßen

#v(1cm)
Max Mustermann \
Geschäftsführer
```

### Business Letter Template

```typst
#set page(paper: "a4", margin: (top: 3cm, bottom: 2.5cm, x: 2.5cm))
#set text(size: 11pt, lang: "de")
#set par(justify: true)

// --- Sender ---
#text(size: 8pt, fill: gray)[
  Musterfirma GmbH · Musterstraße 42 · 70173 Stuttgart
]

#v(0.5cm)

// --- Recipient ---
Frau \
Maria Beispiel \
Beispiel AG \
Beispielweg 1 \
80331 München

#v(1cm)

// --- Date ---
#align(right)[Stuttgart, 08.03.2026]

#v(1cm)

// --- Subject ---
*Betreff: Angebot für Softwareentwicklung*

#v(0.5cm)

Sehr geehrte Frau Beispiel,

vielen Dank für Ihre Anfrage vom 01.03.2026. Gerne unterbreiten wir Ihnen
folgendes Angebot für die Entwicklung Ihrer Webanwendung.

Das Projekt umfasst die folgenden Leistungen:

- Konzeption und Design der Benutzeroberfläche
- Frontend-Entwicklung mit React und TypeScript
- Backend-API mit Node.js
- Deployment und Dokumentation

Der geschätzte Aufwand beträgt 320 Stunden bei einem Stundensatz von 95,00 EUR
netto. Die voraussichtliche Projektlaufzeit beträgt 8 Wochen ab Auftragserteilung.

Dieses Angebot ist 30 Tage gültig. Für Rückfragen stehen wir Ihnen jederzeit
gerne zur Verfügung.

#v(0.5cm)

Mit freundlichen Grüßen

#v(1.5cm)

Max Mustermann \
Geschäftsführer
```

### Report Template

```typst
#set page(
  paper: "a4",
  margin: (x: 2.5cm, y: 2.5cm),
  header: context {
    if counter(page).get().first() > 1 [
      _Projektbericht Q1/2026_
      #h(1fr)
      #counter(page).display("1 / 1", both: true)
    ]
  },
)
#set text(size: 11pt, lang: "de")
#set heading(numbering: "1.1")
#set par(justify: true, leading: 0.65em)

// --- Title page ---
#v(4cm)
#align(center)[
  #text(size: 24pt, weight: "bold")[Projektbericht Q1/2026]

  #v(0.5cm)
  #text(size: 14pt, fill: gray)[Musterfirma GmbH]

  #v(0.3cm)
  #text(size: 12pt)[08. März 2026]
]

#pagebreak()

// --- Table of contents ---
#outline(title: "Inhaltsverzeichnis", indent: auto)

#pagebreak()

// --- Content ---
= Zusammenfassung

Dieses Dokument fasst die Ergebnisse des ersten Quartals zusammen. Die
wichtigsten Kennzahlen zeigen eine positive Entwicklung.

= Projektstatus

== Meilensteine

#table(
  columns: (1fr, auto, auto),
  align: (left, center, center),
  inset: 8pt,
  table.header(
    [*Meilenstein*], [*Geplant*], [*Status*],
  ),
  [MVP Release], [15.01.2026], [Abgeschlossen],
  [Beta Launch], [28.02.2026], [Abgeschlossen],
  [Public Launch], [31.03.2026], [In Arbeit],
)

== Technische Details

Die Architektur basiert auf einer Microservice-Struktur mit den folgenden
Komponenten:

+ API Gateway (Traefik)
+ Backend Services (Go, TypeScript)
+ Datenbank (PostgreSQL mit HA)
+ Monitoring (Prometheus + Grafana)

= Ausblick

Im zweiten Quartal konzentrieren wir uns auf:

- Skalierung der Infrastruktur
- Onboarding der ersten Kunden
- Erweiterung der API-Schnittstellen

= Anhang

Weitere Details auf Anfrage.
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
- **German locale**: For German documents, set `#set text(lang: "de")` in Typst to get correct hyphenation. Use `#set page(paper: "a4")` for standard European page size.
- **Fonts**: The container ships with standard system fonts. Typst also bundles its own fonts. To list available fonts: `typst fonts`.
