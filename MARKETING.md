# Lumen App Store + marketing: Angelo's decisions

Angelo set these on 18 October 2026. They replace older pricing notes elsewhere, such as
"≈£1/month + ≈£8/year" in `HANDOFF.md`. Ask Angelo before changing any of them.

## Pricing (Angelo's decision: keep it)
- £1.49/month, £9.99/year, £29.99 one-off (lifetime).
- Prices are low to win users first.
- Code still never hardcodes prices: they always come from the loaded StoreKit `Product`.

## Free vs Pro
- **Free:** light and colour edits, crop, built-in presets.
- **Pro:** curves, detail, masks, heal, lens blur.
- The goal is paying customers, not free-only users.

## Claims and comparisons
- Compare only against **Lightroom mobile, Photomator and Darkroom**, never desktop Lightroom.
- Don't claim "Lightroom-level" until it has been tested.
- RAW formats are all tested, so it's fine to say so. CI "RAW format matrix" opens, edits and exports Canon CR2 and CR3,
  Nikon NEF, Fuji RAF, Sony ARW and DNG on every sandbox push (passing, e.g. run 38803054702). Angelo has
  confirmed iPhone ProRAW works in Lumen on his phone (18 October).

## Goal
- A paying hobby (about £1,300 in year one), not a salary.

## Channels
- **Landing page:** https://lumen-raweditor.netlify.app/ (waitlist: 5 signups so far, plus a comparison
  table). Don't break the signup form. Source is in `landing-page\` in the parent folder. Don't
  deploy without Angelo's go-ahead.
- **Angelo can't make videos or market himself.** Claude writes the content and drafts; Angelo approves
  every post and email before it goes out.
- **TikTok:** the first 3 posts flopped (no hook, no sound, "building an app" framing). It is not the
  main channel.
- **Main plan:**
  1. Reddit: answer posts where people ask for a Lightroom alternative on iPhone. The r/SideProject post
     got caught by spam filters, so write helpful replies to people asking, not self-promo posts.
  2. Email small photography YouTubers and iPhone app sites, offering free Pro.
- **Press:** pitches to 9to5Mac and DIYPhotography are drafted in Angelo's Gmail. They are on hold
  until he pays Apple's $99 developer fee and TestFlight is ready.

## Outreach status (18 October)
- 13 pitch emails (9 small YouTubers, 4 iPhone news sites) are saved as Gmail drafts and **not sent**.
  They're waiting for TestFlight because they offer free Pro and a TestFlight invite.
- The contact list lives outside this public repo: `deliverables\outreach-list.md` in the parent folder.
  All 15 drafts (including the older 9to5Mac/DIYP ones, whose broken link is now fixed) name every tested format.
- Reddit can't be reached by Claude's own tools. It needs Claude in Chrome with Angelo signed in.

## Not wanted (product)
- Lens corrections, AI denoise, cloud sync, Smart fill.
