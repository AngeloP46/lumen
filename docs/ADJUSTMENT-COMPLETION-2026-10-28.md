# Remaining adjustment completion batch

Candidate branch `adjustment-quality-completion`, baseline `c2472cb`. Owner authorized continuing fixes, reviews,
agents, personal SideStore publication and shared sandbox parity. The liked layout remains intact.

## Implemented candidates and meaningful checks

- Brush paint/erase always uses stored per-run feathering, so a distant different-feather stroke cannot reinterpret
  earlier boundaries. Checkpoints bound temporary graphs and a final <=1024px R8 raster is cached. Existing same-
  feather paint/erase edge appearance can change to the consistent soft-eraser convention; saved numbers stay.
  Regressions cover remote-stroke invariance, checkpoint boundaries, undo/redo, mask/developed pixels and1024/4096px.
  Benchmarks include1/20/100runs, cached reuse and repeated replacements.
- Lens Blur keeps a manually tapped plane sharp even without segmentation, while far textured planes still blur.
  A shared production initializer and baseline-aware monotone selection correction keep Refine entry unchanged;
  Near/Far, brush Add/Subtract and opacity remain effective. HDR now averages RGB radiance before reconstructing
  gains, rather than independently averaging correlated SDR/gain fields. B&W uses a scalar ratio so it stays
  monochrome. Missing required HDR kernels explicitly fail HDR export. No extra blur chain is added.
- Grain has source-relative cell size throughout its slider. The cubic lattice field is integrated over the pixel
  footprint, rather than enlarging small grains to a fixed preview floor or point-sampling aliases. Both octaves
  are filtered. Work is bounded and ultra-subpixel fields fade below1/32pixel; ordinary640px+thumbs retain the range.
  Preview-versus2x-export averaging invariants, finite/range/dead-travel checks and full1600px timing test actual code.
  This follows standard [texture filtering principles](https://pbr-book.org/4ed/Textures_and_Materials/Texture_Sampling_and_Antialiasing),
  with an independent analytic integral of the existing cubic noise field. It is not a film-emulsion simulation.
- Vignette normalizes distance by the selected shape's corner radius, eliminating aspect-dependent Midpoint dead
  ranges. Amount/sign conventions stay. Wide/portrait/square corner tests cover both signs and several midpoints.
- Saved Heal patches/masks must be present, structurally complete and dimension/owner compatible before export.
  Valid old no-owner assets remain supported. Missing/corrupt patches cannot silently export original pixels.
  People search distinguishes successful empty from unavailable/decode/detection failure and preserves useful
  successful fallback masks and prior selections; cancellation cannot clear an unrelated active Heal.
- Library work queues IDs only, one active render/recipe/lease, visible priority, four-item yield and pressure
  backoff. Starts pause in editor/background; generations prevent pending basic/deleted work overwriting refined
  results. Basic thumbnails omit unprepared dependent automatic adjustments and Lens Blur; unchanged editor close
  refines from its existing ready preview. Revision4 basic/refined filenames atomically persist each result;
  earlier JPEGs stay visible until replacement. No whole-library launch filesystem scan or2,000-photo stress run.
- Geometry/resampling is compared against4x analytic slanted-detail references through actual crop/turn/mirror/
  straighten paths. This expands quality evidence without replacing Core Image's resampler blindly.
- Source-analysis and Subject autorelease pools plus work-item editor/AI queues bound temporary lifetimes. The
  failing memory limits stay unchanged. The memory test now measures whole-step peaks without resets at substeps.

## Validation gate

All candidates require Mac compile, new rendered assertions, visual output inspection and appropriate UI checks.
Memory must be rerun on the actual24MP RAW and ProRAW sequences; candidate pools are not a measured fix yet.
Independent agents reviewed brush, Lens, grain/vignette and Heal/state interactions, finding an additional wide-
manual-focus bypass and active-Heal cancellation interaction before validation. The scheduler review is ongoing.

After passing checks, publish personal main through protected PR, verify fresh SideStore feed/log/asset, then
merge shared sandbox after OFF/ON/export-policy/StoreKit checks. Record exact versions/runs here. PhoneGPUspeed,
phone memory and original-image photographic judgement remain evidence only the owner's testing can supply.
