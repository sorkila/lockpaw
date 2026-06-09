# Lockpaw Design System

The single source of truth for how Lockpaw looks and moves — across the **app**
(lock screen, onboarding, settings), the **website**, and the **GitHub** presence.
Mirror these tokens into `Lockpaw/Utilities/Constants.swift` (Swift) and the website
`:root` (CSS). If a surface diverges from this doc, the surface is wrong.

> **Soul:** a calm guardian that breathes and pulses — quiet until it needs you.
> Near-black canvas, one teal accent, a metallic origami mascot, generous negative
> space, motion that breathes. Everything recedes so the mascot and the moment lead.

---

## 1. Color

Dark-first. One accent. Color is used as **signal**, never decoration.

### Surfaces (dark canvas)
| Token | Value | Use |
|---|---|---|
| `surface/canvas` | `#09090b` | App/web background base |
| `surface/lock` | `linear-gradient(#02010605 → #000 → #02010504)` | Lock-screen near-black (faint violet tint) |
| `surface/0` | `white @ 0.04` | Dimmest raised surface |
| `surface/1` | `white @ 0.06` | Default panel/card |
| `surface/2` | `white @ 0.09` | Hover / active panel |
| `hairline` | `white @ 0.08` | Borders, dividers (use 0.04–0.14 by emphasis) |

### Accent
| Token | Value | Use |
|---|---|---|
| `accent` (teal) | `#00D4AA` · `rgb(0,212,170)` | Primary brand: interactive text, glow, selection, focus |
| `accent-soft` | `teal @ 0.07–0.15` | Tinted fills behind teal text (bordered buttons, selected segment) |

### Signal (the proximity gradient — own this)
Lockpaw's distinctive idea: state reads as **distance to danger**, on one ramp.
| Token | Value | Meaning |
|---|---|---|
| `signal/safe` | teal `#00D4AA` | All good, work running |
| `signal/caution` | amber `#FF9F43` | Attention / warm accent |
| `signal/danger` | red `#FF3B30` | Auth failure, destructive, error |

`violet` and `success` exist in assets but are **unused** — keep out of new work
unless promoted here first.

### Text (on dark)
| Token | Opacity | Use |
|---|---|---|
| `text/primary` | white `0.55` | Lock-screen message, primary on dark |
| `text/secondary` | white `0.35` | Timer, secondary |
| `text/tertiary` | white `0.25` | Hints (chevron, "tap for help") |

(Settings/light mode use the native `labelColor` ramp; the opacities above are the
dark/lock-screen voice.)

---

## 2. Typography

**Decision — system font everywhere.** The app uses SF (correct for native). The
website should adopt the **system font stack** too, for one voice and a genuinely
"native Mac" feel. *(Inter is an acceptable alternative only if marketing wants
distinct branding — but the scale, weights, and tracking below are shared regardless.)*

Type whispers: light-to-regular weights, generous tracking, one element at a time.

| Role | Size | Weight | Tracking |
|---|---|---|---|
| Display (hero) | 28–34 | semibold | -0.5 |
| Title | 20–22 | semibold | 0 |
| Body | 15–16 | regular | 0.35 |
| Label | 13–14 | medium | 0.3 |
| Caption | 11–12 | light | 0.5 |
| Mono (timer, hotkey) | 12–18 | regular/semibold, monospaced | 0.5 |

---

## 3. Space & Radius

One ramp. No magic numbers.

- **Space:** `4 · 8 · 12 · 16 · 20 · 24 · 32 · 40`
- **Radius:** `xs 4 · sm 8 · md 12 · lg 20 · xl 40 · full 100`
  - Controls (checkbox, segment, recorder): `sm 8` outer / `6` inner
  - Buttons / panels: `8–12`

---

## 4. Motion — the signature

Motion is the moat. Two named, reusable signatures + a small curve set.

### The two signatures
- **The breath** — the idle heartbeat. A monotonic 12s-per-unit sine driving the
  mascot float, shadow, and ambient drift. Never resets (no snap). The website icon
  should breathe on the **same 12s cadence**.
- **The pulse** — the agent-glow: a bright teal full-screen bloom that ramps in fast
  (~0.45s), holds (~0.45s), and eases out slow (~1.6s). This is the brand's "it needs
  you" moment — feature it in the demo, the OG art, and echo it on press states.

### Canonical curves (use the same curve on app + web)
| Token | Cubic-bezier (CSS) | SwiftUI | Use |
|---|---|---|---|
| `ease-out` | `0.16, 1, 0.3, 1` | `.timingCurve(0.16,1,0.3,1, …)` | Entrances, reveals (expressive) |
| `ease-spring` | `0.34, 1.56, 0.64, 1` | `.spring(response:0.4, damping:0.75)` | Playful settle (icon, success) |
| `ease-micro` | `0.2, 0, 0, 1` | `.easeOut(…)` | Press / quick state |
| `ease-loop` | `0.45, 0, 0.55, 1` | `.easeInOut(…)` | Looping (glow out, breathing easing) |

### Durations
`quick 0.2 · standard 0.35 · gentle 0.5 · entrance 0.8 · glow-in 0.45 · glow-out 1.6`

### Choreography rules
- **Enter fast, settle slow.** Reveals use `ease-out`; exits are quieter.
- **Stagger** grouped reveals 40–60ms.
- **One thing moves at a time** — respect the quiet. Honor `prefers-reduced-motion` /
  `accessibilityReduceMotion` everywhere (already the rule in-app).

---

## 5. Elevation & light

Depth comes from **light, not boxes**. The mascot sits in a "pool of light":
- Teal glow shadow (`teal @ 0.15`, radius ~35, that breathes ±0.08 / ±8px).
- A soft black contact shadow (`black @ 0.15`, radius ~45, y 30).
- Background radial pools (teal + amber, very low opacity, heavy blur) drift on the breath.
Reuse these recipes rather than flat borders for "raised" feeling on dark surfaces.

---

## 6. Coherence checklist (the "aligned" test)

A surface is on-brand only if all are true:
- [ ] Same teal `#00D4AA`, same canvas `#09090b`, same hairline opacities.
- [ ] Same type scale / weights / tracking (and ideally font family).
- [ ] Uses the shared motion curves; expresses **breath** and/or **pulse**.
- [ ] Mascot (where shown) uses the pool-of-light treatment + breath.
- [ ] Key art (OG / README hero / website hero) is one image system.
