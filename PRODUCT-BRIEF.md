# Lumen product brief

Owner-confirmed direction, 14 October 2026. Read with AGENTS.md and CLAUDE.md.

## What we are designing

Lumen is an **iPhone/iOS photo editor**, built around **RAW photography**, with the
goal of becoming a **cheaper alternative to Lightroom**. It should provide useful,
high-quality editing with a clear, comfortable mobile interface.

## Who it is for

Photographers who shoot camera RAW and want to edit on their iPhone without paying
Lightroom-level prices. Angelo's Sony A9 photos are important real examples, not
the limit of the intended audience. iPhone ProRAW photographers are included too.

## Camera and file coverage

- Design for all popular camera brands: Sony, Canon, Nikon, Fujifilm, Panasonic,
  OM System/Olympus, Pentax, Leica and others, plus iPhone.
- Camera RAW and iPhone ProRAW are the primary use cases; JPEG and HEIC remain useful.
- Use shared image/metadata paths wherever possible. Do not make ordinary features
  depend on Sony-specific tags, lenses, scenes or example photos.
- Specific RAW-model support depends on Apple's decoder. Test representative formats
  and report unsupported files honestly; brand coverage is a goal, not a claim that
  every camera model has been tested or supported.
- Prefer standard EXIF/TIFF for photo information. Missing metadata must stay missing;
  never invent camera settings, dates, lens names or measured depth distances.

## Product and interface priorities

- Keep the photo prominent, controls readable and touch targets comfortable.
- Editing, masking, crop, colour and export should work predictably on real RAW files.
- Lightroom is a reference for useful workflow, not a requirement to copy every feature.
- Follow docs/UI-PRINCIPLES.md and the owner's explicit feature choices in CLAUDE.md.
- Use plain, specific copy and explain limits without empty quality claims.

## Distribution and pricing

- The owner's personal main/SideStore app stays fully unlocked: no paywall,
  subscription, watermark or payment restrictions.
- App Store product/pricing work stays in Lumen-Sandbox. A cheaper Lightroom
  alternative is the direction; do not infer a final price or charging model.
- Shared editor improvements belong in both builds. Never copy sandbox payment or
  watermark code into personal main.

Update this brief when Angelo changes the product direction. Keep build procedures,
test evidence and current handoffs in CLAUDE.md/HANDOFF.md rather than duplicating them.
