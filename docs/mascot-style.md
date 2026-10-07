# Lockpaw mascot style

Notes for making a mascot that sits next to the Dog and Cat on the lock screen, whether you're adding a bundled one or making your own for the Custom slot. These are also the briefs behind the 1.6 supporter mascots and seasonal skins.

## The house style

- **Subject:** one animal, seen fully from the side (profile), standing, facing **left**, whole body in frame with a little margin. Calm and alert, not cute-cartoon.
- **Construction:** flat, frosted-glass panels, like a folded-paper (origami) figure made of translucent acrylic. A few large, simple planes, no fur and no fine detail. Each panel has a thin bright bevel along its edge.
- **Colour:** near-black glass lit from inside by two colours only: **teal #00D4AA** (cool side, edges, head) and **amber #FF9F43** (warm patches on the belly, chest and the far legs). Soft gradients inside each panel and a faint frosted grain.
- **Light:** glowing edges, gentle inner light, no cast shadow, no floor, no environment.
- **Background:** pure black, or better, transparent (PNG with alpha). The app floats the figure in its own glow, so any backdrop shows as a box.
- **Format:** PNG, about **1400 × 1130 px** (landscape, roughly 5:4), subject centred, about 85% of the height.
- **Don'ts:** no text, no logo, no outline stroke around the whole figure, no extra colours (the glow on the lock screen is teal/amber/red and means something), no drop shadow, no 3/4 view.

## Shared prompt base

Use this as the start of every prompt, then add the subject line:

> A minimalist low-poly origami sculpture made of frosted translucent glass panels, side profile view facing left, full body standing, large simple flat planes with thin glowing bevelled edges, near-black glass lit from within by soft teal (#00D4AA) and warm amber (#FF9F43) gradients, faint frosted grain texture, glowing teal rim light along the edges, no fur detail, no shadow, no floor, isolated on a pure black background, centered, product render, high detail, 5:4 landscape

## Supporter mascots (asset names in brackets)

1. **Fox** (`MascotFox`): *…subject:* a fox, pointed upright ears, slim snout, long bushy tail held low and curving behind, tail tip panel in amber.
2. **Owl** (`MascotOwl`): *…subject:* an owl perched upright on nothing, body turned in profile facing left with the head turned slightly towards the viewer, large round eye disc in teal, folded wings as two big panels, short tail, small ear tufts. *(The one exception to strict profile: owls read better with the face visible.)*
3. **Red panda** (`MascotRedPanda`): *…subject:* a red panda walking, rounded ears, short snout, long thick tail with ring bands drawn as alternating teal and amber panels.
4. **Bunny** (`MascotBunny`): *…subject:* a rabbit sitting upright on its haunches, long ears straight up, round body, small round tail, front paws down.

## Seasonal skins (Dog and Cat)

Give Grok the **existing** `Mascot.png` (dog) or `MascotCat.png` (cat) as the reference image, plus: *"Keep the exact same figure, pose, panels and colours. Only add:"*, then the line below. The accessory is made from the same frosted glass in the same two colours. No new colours.

| Season | Asset names | Add |
|---|---|---|
| Halloween | `Mascot-halloween`, `MascotCat-halloween` | a small pointed witch hat tilted on the head, and a carved pumpkin at the front paws, both as frosted glass panels, pumpkin glowing amber from inside |
| Winter holidays | `Mascot-winter`, `MascotCat-winter` | a knitted scarf wrapped once around the neck with one end hanging, and a few small glass snowflakes floating around the head |
| Lunar New Year | `Mascot-lunarnewyear`, `MascotCat-lunarnewyear` | a small round paper lantern hanging from the mouth (dog) or beside the raised tail (cat), glowing amber, with a tassel |
| Midsummer | `Mascot-midsummer`, `MascotCat-midsummer` | a Swedish midsummer flower crown (wreath of small flowers and leaves) on the head, flowers as tiny teal and amber glass petals |

## Checklist before it ships

- [ ] Same scale as Dog/Cat when shown side by side (head height, body length).
- [ ] Facing left, standing, full body, margin on all sides.
- [ ] Only teal and amber; nothing reads as red.
- [ ] Transparent background (or pure black that masks cleanly).
- [ ] Looks right at 200 px wide (the Settings preview) and at full size on a dark screen.
- [ ] Dropped into `Lockpaw/Resources/Assets.xcassets/<AssetName>.imageset/` with a `Contents.json` like `MascotCat.imageset`'s. The app picks it up by name: supporter mascots appear in Settings once their asset exists, and seasonal skins fall back to the plain mascot when theirs is missing.
