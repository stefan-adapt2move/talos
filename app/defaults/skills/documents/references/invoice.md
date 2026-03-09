# Invoice Template (Typst)

A professional invoice with company header, line items table, tax calculation, and payment details.

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
    grid.hline(stroke: 1pt),
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
