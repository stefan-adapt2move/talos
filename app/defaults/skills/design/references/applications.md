# Applications Reference

SaaS apps, dashboards, admin panels, tools, settings pages, data interfaces. This is where subtle layering defines craft.

---

## The Subtle Layering Principle

This is the backbone. When you look at Vercel's dashboard, you don't think "nice borders." You just understand the structure. When you look at Linear, you don't think "good elevation." You just know what's above what. The craft is invisible — that's how you know it's working.

---

## Surface Elevation

Surfaces stack. Build a numbered system:

```
Level 0: Base background (the app canvas)
Level 1: Cards, panels (slight lift from base)
Level 2: Dropdowns, popovers (floating above)
Level 3: Nested overlays, stacked popovers
Level 4: Highest elevation (rare)
```

Each jump: a few percentage points of lightness. You can barely see the difference in isolation. But when surfaces stack, hierarchy emerges.

**Key decisions:**
- **Sidebars:** Same background as canvas, not different. Different colors fragment visual space. A subtle border is enough separation.
- **Dropdowns:** One level above their parent. If both share the same level, the dropdown blends in and layering is lost.
- **Inputs:** Slightly darker than surroundings, not lighter. Inputs are "inset" — they receive content. Darker signals "type here" without heavy borders.

---

## Borders

Borders should disappear when you're not looking for them, but be findable when you need structure. Low-opacity rgba blends with the background — defines edges without demanding attention.

Build a progression:
- **Default** — standard separation
- **Subtle** — softer, background grouping
- **Strong** — emphasis, hover states
- **Stronger** — focus rings, maximum attention

**The squint test:** Blur your eyes. You should perceive hierarchy but nothing should jump out. No harsh lines. No jarring shifts. Just quiet structure.

---

## Card Layout Variation

A metric card doesn't have to look like a plan card doesn't have to look like a settings card. Design each card's internal structure for its specific content — but keep surface treatment consistent: same border weight, shadow depth, corner radius, padding scale.

Every pattern has infinite expressions. A metric display could be a hero number, sparkline, gauge, progress bar, comparison delta, or trend badge. Same sidebar + cards has infinite variations in proportion, spacing, and emphasis.

**Before building, ask:**
- What's the ONE thing users do most here?
- What products solve similar problems brilliantly? Study them.
- Why would this feel designed for its purpose, not templated?

---

## Navigation Context

Screens need grounding. A data table floating in space is a component demo, not a product.

- **Navigation** — sidebar or top nav showing where you are
- **Location indicator** — breadcrumbs, page title, active nav state
- **User context** — who's logged in, what workspace/org

Build navigation as part of the app, not a bolt-on wrapper.

---

## Controls

Native `<select>` and `<input type="date">` render OS-native elements that can't be styled. Build custom components:

- Custom select: trigger button + positioned dropdown
- Custom date picker: input + calendar popover
- Custom checkbox/radio: styled div with state management

Custom select triggers need `display: inline-flex` with `white-space: nowrap` to keep text and chevron aligned.

---

## Information Density

Density is a design decision, not a constant. Consider the user's context:

- **High density** — trading floors, developer tools, monitoring dashboards. Every pixel earns its place. Tight spacing, smaller type, more data visible.
- **Medium density** — most SaaS products. Balanced breathing room with functional depth.
- **Low density** — consumer apps, onboarding flows. Generous space, focused attention, progressive disclosure.

The right density comes from intent: who is the human, what are they doing, how often do they use this?

---

## Dark Mode

Dark interfaces have different needs:

- **Borders over shadows** — shadows barely register on dark backgrounds. Lean on borders.
- **Desaturate semantics** — success, warning, error colors often need slight desaturation on dark backgrounds.
- **Invert the hierarchy** — same system, different direction. Higher elevation = slightly lighter.
- **Watch contrast** — pure white text on pure black is harsh. Soften both ends.

---

## Avoid

- Harsh borders — if borders are the first thing you see, they're too strong
- Dramatic surface jumps — elevation changes should be whisper-quiet
- Different hues for different surfaces — same hue, shift only lightness
- Pure white cards on colored backgrounds
- Thick decorative borders
- Gradients for decoration — color should mean something
- Same sidebar width, same card grid, same metric boxes every time — this signals AI immediately
