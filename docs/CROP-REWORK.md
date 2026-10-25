# Crop rework (25 Oct 2026)

Angelo's ask: the crop tool has the features but is not fun or intuitive; dragging corners is hard because other UI covers
the edges; every other app lets you zoom the photo itself; does Fill frame crop away more than the black bits?

## What other apps do (research, 25 Oct)
Sources: Adobe's Lightroom mobile and Classic help pages (crop, straighten, Constrain to Image), Apple's Photos help and
iPhone how-tos (iMore, MacRumors, TechRadar, How-To Geek), Snapseed's help, Apple's Pixelmator Pro iPad help, PicTapGo's
help, Photomator reviews (AppleInsider, iDownloadBlog, Chris Wright), Adobe community threads on Lightroom crop behaviour,
Google Photos 2026 crop-tool notes, a leancrew.com post on iOS Photos cropping, a Drupal and a Mozilla bug on touch
crop handles.

| | Lightroom (mobile / Classic) | Apple Photos | Snapseed / PicTapGo | Photomator / Pixelmator |
|---|---|---|---|---|
| Photo vs frame | the photo moves behind a frame that stays centred on screen | pinch and drag the **photo**; frame can also be dragged by its corners and edges | pinch resizes the frame at the same ratio (Snapseed); pinch and drag move the photo (PicTapGo) | crop box with handles; the photo can be dragged and pinched |
| Straighten | angle wheel -45 to 45, **Auto** | **dial** under the photo, -45 to 45; Vertical and Horizontal beside it | rotate wheel / swipe | ruler under the photo, **Auto Straighten** (detects the horizon) |
| Empty edges | the crop box cannot leave the photo (**Constrain to Image**); it shrinks as you rotate | the crop shrinks as you rotate, and zoom in is automatic | crops to the picture | box stays inside the photo |
| Aspect | list of ratios + lock icon; orientation swap | ratio button, lock | chips | presets |
| Overlays | thirds, golden, diagonal etc. | thirds while dragging | thirds | seven guides |

Pain points users report (leancrew on Photos; Adobe community; bug trackers):
- The picture rescaling on screen **while** you drag a handle moves the opposite corner by accident. Rescale only after
  you let go, and never move a corner you are not touching.
- Dragging an edge works and a corner drifts: edge and corner grab areas must both be big (Apple's guidance is 44 pt).
- Handles on a photo that reaches the screen edge are covered by buttons and the system's edge gestures: leave a margin.
- Dragging a frame that is already full width or full height is hard: zooming in first is the workaround people use.
- Edge dragging is invisible: show bars on the edges as well as corners.

## What Lumen did and why it felt average
- Only the frame moved. The photo could not be zoomed or panned under it, which is how every other app is used.
- The photo filled the screen, so corners sat under the top buttons, the histogram and the system's edge swipe.
- Grab areas were 34 pt, the frame resized by the finger's position (not by how far it moved), and the picture was
  never rescaled so a small frame was a small target.
- The straighten slider sat below the icon row; no dial.

## Does Fill frame crop more than needed? Yes, a little.
Measured with a simulation of the same maths (3:2 photo; "kept" = share of the photo's area left):

| edit | Lumen today | best possible, same shape | best, any shape |
|---|---|---|---|
| straighten 3° | 86 % | 86 % | 89 % |
| straighten 8° | 70 % | 70 % | 75 % |
| vertical +40 | 83 % | 84 % | 90 % |
| vertical +40 and straighten 3° (Fill frame on) | **71 %** (the two zooms multiply; the figure Lumen keeps is lower than the 79 % shown for the centred case) | 83 % | 84 % |
| horizontal -30 and straighten -2° | ~68 % | 87 % | 90 % |

Three causes: (1) Fill frame zooms about the **centre** only, so a lopsided perspective loses more than if the frame could
slide; (2) the straighten zoom and the Fill frame zoom are computed separately and multiply; (3) the crop frame is stored
as a share of the straighten-zoomed picture, so a wide or tall crop cannot use the corners that are still real photo.
Straighten alone with the photo's own shape is already the best possible.

## Plan
**Batch 1 (interaction, no change to how a crop is stored)**
1. The crop is shown on a stage with a margin (no corner under a button, none within the system's swipe zone).
2. The frame stays large on screen: after a resize the picture zooms so the frame fills the stage (animated, like Photos).
   The picture is never rescaled while a finger is on a handle.
3. Pinch anywhere zooms the **photo** under the frame; one finger inside the frame moves the photo. Corner and edge handles
   have 48 pt grab areas that reach outside the frame; edge bars are drawn; dragging by distance moved, not finger position.
4. Straighten becomes a ruler dial with ticks and a haptic click each degree, Auto beside it, double-tap resets.
5. Panel: aspect chips, dial, then the icon row; the histogram is hidden while cropping.

**Batch 2 (geometry, fixes the "crops more than needed" answer)**
Constrain to Image done properly: the valid area is the straightened and transformed photo (a convex quadrilateral);
the crop is a rectangle that must stay inside it. The default and Fill frame become the largest rectangle of the chosen
shape that fits, positioned anywhere; a freely shaped crop can reach any corner that is still real photo; straighten and
perspective changes shrink or slide the crop only as much as needed, and it grows back if the angle is reduced. Old edits are
converted once. Needs a logic test of the fit maths and engine tests of the output size.
