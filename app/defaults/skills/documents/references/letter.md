# Business Letter Template (Typst)

A formal business letter with sender line, recipient block, date, subject, and signature.

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
