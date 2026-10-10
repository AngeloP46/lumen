# Lumen UI principles (check every UI change against these)

Written 2026-10-10 from research into Lightroom mobile, Photomator, Darkroom and Apple's HIG.
If a requested change breaks one of these, say so to the owner and suggest the version that doesn't.

## 1. The photo comes first
- The photo is the brightest, biggest thing on screen. Chrome is near-black greys (`Theme`), never colourful.
- Colour in the UI only means something: accent = active tool / value changed from default; red = destructive; green = saved/exported.
- Never let a change shrink the photo or make it jump. Switching tools must not move or resize the photo (`sharesHeight`).
- Overlays (histogram, badges) are small, semi-transparent and never take touches (`allowsHitTesting(false)`).

## 2. Fewest taps to the slider
- Lightroom's 2023 redesign cut on-screen tool options from 15 to 5 because scrolling through many was overwhelming.
- Opening a tool should show sliders straight away, ready to drag (no "tap a tile, then a slider appears").
- Tool bar order follows the editing flow, left to right: start tools left, finishing/advanced tools right (Presets last).
- Keep 8 or fewer tools visible. Anything new goes inside an existing tool or the ⋯ menu, not a 9th button.

## 3. One-handed, thumb reach
- Everything used while editing lives in the bottom third. Top buttons are for occasional actions (back, undo, export, menu).
- Touch targets at least 44 × 44 pt (Apple HIG), even if the drawn thing is smaller (use `contentShape`).

## 4. Sliders behave the same everywhere
- Relative drag (finger anywhere on the row moves the value from where it is, no jumping to the touch).
- Double-tap or tap the value = reset that slider. Haptic tick when crossing zero/default and at the ends.
- Value shown live while dragging. Changed sliders show the accent colour, untouched ones grey.
- A vertical swipe scrolls the list; only a sideways first movement grabs the slider.

## 5. Gestures over buttons, but never hidden-only
- Press and hold = original. Pinch = zoom. Double-tap photo = zoom to that spot. Tap photo = hide chrome.
- Two-finger tap = undo, three-finger tap = redo (Photomator does this; Lumen doesn't yet: candidate).
- Every gesture-only action also needs a visible route (button or menu) for when it's forgotten.

## 6. Don't break what's tested
- Keep accessibility identifiers (`slider-<name>`, `tool-<name>`, `panel`, `photo`…): the 38 UI tests depend on them.
- Any gesture or layout change gets a UI test. Check screenshots from the `screenshots`/`uitest` artifacts before merging.
- Owner's stated "don't want" list (CLAUDE.md) still holds: no healing, lens corrections, Upright, AI denoise, Generative Remove, cloud sync.

## Sources
- Lightroom mobile new editor (Adobe, 2023): https://blog.adobe.com/en/publish/2023/07/26/adobe-photoshop-lightroom-has-new-mobile-interface-make-editing-even-easier-on-go
- Lightroom mobile sliders: https://www.lightroomqueen.com/lightroom-mobile-editing-global-sliders/
- Photomator gestures: https://support.pixelmator.com/photomator-user-guide/get-started/basic-gestures
- Darkroom UI breakdown: https://blakecrosley.com/guides/design/darkroom
- Darkroom haptics: https://darkroom.co/blog/2017-07-haptic-feedback
