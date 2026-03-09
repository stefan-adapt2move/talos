# Typst Templates

Ready-to-use Typst templates. Copy and adapt for your documents.

---

## Invoice

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

---

## Business Letter

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

---

## Report with Table of Contents

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
