# Grok handover: Lockpaw 1.6 mascot art

Twelve images for Lockpaw 1.6: four supporter mascots and eight seasonal skins. The house style and checklist are in [`mascot-style.md`](mascot-style.md). This file is the ready-to-run version.

**How to run.** From the repo root:

```bash
cd ~/Repositories/Lockpaw
grok "$(sed -n '/^## Paste this into Grok/,/^## One prompt per image/p' docs/grok-handover.md)"
```

Or open `grok` and paste the section below. If you'd rather go one image at a time, use the prompts under "One prompt per image".

When the images are done, tell Claude the folder (default `~/Desktop/lockpaw-art`). Claude checks scale against the Dog and Cat, adds them to the asset catalog and builds.

---

## Paste this into Grok

You are making 12 PNG images for Lockpaw, a macOS app whose lock screen shows a mascot animal. The images must match two existing mascots exactly in style. Look at them first:

- `Lockpaw/Resources/Assets.xcassets/Mascot.imageset/Mascot.png` (the dog)
- `Lockpaw/Resources/Assets.xcassets/MascotCat.imageset/MascotCat.png` (the cat)

Both are about 1400 × 1130 px, transparent background, one animal in side profile facing left, built from large flat frosted-glass panels lit from inside in teal #00D4AA and amber #FF9F43, with thin glowing bevelled edges.

Generate each image below with your image generation tool and save it to `~/Desktop/lockpaw-art/` with **exactly** the file name given (create the folder). Rules for every image:

1. Side profile facing **left**, whole body in frame with a margin on every side, subject about 85% of the image height, centred.
2. Only teal #00D4AA and amber #FF9F43 light in near-black glass. No other colours. Nothing red.
3. Background **transparent**. If your tool can't do transparency, use pure black #000000 and say so at the end.
4. Landscape, about 5:4 (or 3:2 if that's the closest your tool offers).
5. No text, no logo, no floor, no shadow, no outline stroke around the figure.
6. For the 8 seasonal images, start from the existing dog or cat image as the reference (image-to-image or edit). Keep the same figure, pose, panels and colours, and only add the accessory.

After saving, list the 12 files with their pixel sizes, say which (if any) have a black background instead of transparency, and flag any image that broke a rule so it can be redone.

### Supporter mascots (generate from text)

Every prompt starts with this base:

> A minimalist low-poly origami sculpture made of frosted translucent glass panels, side profile view facing left, full body standing, large simple flat planes with thin glowing bevelled edges, near-black glass lit from within by soft teal (#00D4AA) and warm amber (#FF9F43) gradients, faint frosted grain texture, glowing teal rim light along the edges, no fur detail, no shadow, no floor, isolated on a transparent background, centered, product render, high detail, 5:4 landscape.

| File | Subject (append to the base) |
|---|---|
| `MascotFox.png` | Subject: a fox, pointed upright ears, slim snout, long bushy tail held low and curving behind, tail tip panel in amber. |
| `MascotOwl.png` | Subject: an owl perched upright on nothing, body in profile facing left with the head turned slightly towards the viewer, large round eye disc in teal, folded wings as two big panels, short tail, small ear tufts. |
| `MascotRedPanda.png` | Subject: a red panda walking, rounded ears, short snout, long thick tail with ring bands drawn as alternating teal and amber panels. |
| `MascotBunny.png` | Subject: a rabbit sitting upright on its haunches, long ears straight up, round body, small round tail, front paws down. |

### Seasonal skins (edit the existing dog and cat)

For each: use the reference image, keep the exact same figure, pose, panels and colours, and only add the accessory, made from the same frosted glass in the same two colours. Transparent background.

| File | Reference | Add |
|---|---|---|
| `Mascot-halloween.png` | dog | a small pointed witch hat tilted on the head, and a carved pumpkin at the front paws, both as frosted glass panels, the pumpkin glowing amber from inside |
| `MascotCat-halloween.png` | cat | a small pointed witch hat tilted on the head, and a carved pumpkin at the front paws, both as frosted glass panels, the pumpkin glowing amber from inside |
| `Mascot-winter.png` | dog | a knitted scarf wrapped once around the neck with one end hanging, and a few small glass snowflakes floating around the head |
| `MascotCat-winter.png` | cat | a knitted scarf wrapped once around the neck with one end hanging, and a few small glass snowflakes floating around the head |
| `Mascot-lunarnewyear.png` | dog | a small round paper lantern hanging from the mouth, glowing amber, with a tassel |
| `MascotCat-lunarnewyear.png` | cat | a small round paper lantern hanging beside the raised tail, glowing amber, with a tassel |
| `Mascot-midsummer.png` | dog | a Swedish midsummer flower crown (a wreath of small flowers and leaves) on the head, the flowers as tiny teal and amber glass petals |
| `MascotCat-midsummer.png` | cat | a Swedish midsummer flower crown (a wreath of small flowers and leaves) on the head, the flowers as tiny teal and amber glass petals |

## One prompt per image

Copy one block at a time into Grok (chat or Imagine) and save the result under the file name in the heading.

### MascotFox.png
```
A minimalist low-poly origami sculpture made of frosted translucent glass panels, side profile view facing left, full body standing, large simple flat planes with thin glowing bevelled edges, near-black glass lit from within by soft teal (#00D4AA) and warm amber (#FF9F43) gradients, faint frosted grain texture, glowing teal rim light along the edges, no fur detail, no shadow, no floor, isolated on a transparent background, centered, product render, high detail, 5:4 landscape. Subject: a fox, pointed upright ears, slim snout, long bushy tail held low and curving behind, tail tip panel in amber.
```

### MascotOwl.png
```
A minimalist low-poly origami sculpture made of frosted translucent glass panels, side profile view facing left, full body standing, large simple flat planes with thin glowing bevelled edges, near-black glass lit from within by soft teal (#00D4AA) and warm amber (#FF9F43) gradients, faint frosted grain texture, glowing teal rim light along the edges, no fur detail, no shadow, no floor, isolated on a transparent background, centered, product render, high detail, 5:4 landscape. Subject: an owl perched upright on nothing, body in profile facing left with the head turned slightly towards the viewer, large round eye disc in teal, folded wings as two big panels, short tail, small ear tufts.
```

### MascotRedPanda.png
```
A minimalist low-poly origami sculpture made of frosted translucent glass panels, side profile view facing left, full body standing, large simple flat planes with thin glowing bevelled edges, near-black glass lit from within by soft teal (#00D4AA) and warm amber (#FF9F43) gradients, faint frosted grain texture, glowing teal rim light along the edges, no fur detail, no shadow, no floor, isolated on a transparent background, centered, product render, high detail, 5:4 landscape. Subject: a red panda walking, rounded ears, short snout, long thick tail with ring bands drawn as alternating teal and amber panels.
```

### MascotBunny.png
```
A minimalist low-poly origami sculpture made of frosted translucent glass panels, side profile view facing left, full body standing, large simple flat planes with thin glowing bevelled edges, near-black glass lit from within by soft teal (#00D4AA) and warm amber (#FF9F43) gradients, faint frosted grain texture, glowing teal rim light along the edges, no fur detail, no shadow, no floor, isolated on a transparent background, centered, product render, high detail, 5:4 landscape. Subject: a rabbit sitting upright on its haunches, long ears straight up, round body, small round tail, front paws down.
```

### Seasonal skins (attach the reference image to each)

Attach `Lockpaw/Resources/Assets.xcassets/Mascot.imageset/Mascot.png` for the dog files and `…/MascotCat.imageset/MascotCat.png` for the cat files, then:

```
Keep this exact figure, pose, panels and colours. Only add: <ACCESSORY>. The accessory is made of the same frosted translucent glass panels with thin glowing bevelled edges, lit only in teal (#00D4AA) and amber (#FF9F43). No other colours. Transparent background, no floor, no shadow.
```

| File | `<ACCESSORY>` |
|---|---|
| `Mascot-halloween.png` / `MascotCat-halloween.png` | a small pointed witch hat tilted on the head, and a carved pumpkin at the front paws glowing amber from inside |
| `Mascot-winter.png` / `MascotCat-winter.png` | a knitted scarf wrapped once around the neck with one end hanging, and a few small glass snowflakes floating around the head |
| `Mascot-lunarnewyear.png` | a small round paper lantern hanging from the mouth, glowing amber, with a tassel |
| `MascotCat-lunarnewyear.png` | a small round paper lantern hanging beside the raised tail, glowing amber, with a tassel |
| `Mascot-midsummer.png` / `MascotCat-midsummer.png` | a Swedish midsummer flower crown on the head, the flowers as tiny teal and amber glass petals |
