# Report Template (Typst)

A multi-page report with title page, table of contents, numbered headings, page headers, and milestone table.

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
