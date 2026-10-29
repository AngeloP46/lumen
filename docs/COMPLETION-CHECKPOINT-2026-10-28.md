# Completion checkpoint — SideStore0.1.782 published; tester file requested

Owner's latest direction: publish SideStore first, then supply the existing30-day tester IPA for manual GoogleDrive
sharing. Publication is done. Do not expand the review; finish the file delivery and the exact remaining HDR case.

## Authoritative release

- Personal#184 mergedfe0a94c6b5f6553cd1b8d68a50e0c99102d34614, sourced9c4064f4bb19b4a76ec8bbba01fbf3f8620810d.
- SideStore0.1.782 publish40791387290 success. Freshfeed/log/asset match356122572bytes,
  SHA2564f7f7307d51c6d938640687fadb4472a5ca92a991f9676a4f108912b5a9432e4.
- Shared sandbox#185 mergedbe2d8026f94ac37a3869efb68c5c94f0b77e26af, source82d808c. Bothconfigurations,
  policy/identity/four StoreKit40788980740 pass (sameapplication, laterprobe onlyactive whena test hook exists).
- Originalphotos/values/UI/Store/modelsettings kept. All saved recipes/history/paste useonecurrentrenderer;
  format3 exactJSONbackups preserved. No2,000photo run; noNetlify/AppStore submission.

## Verified evidence

- Full774enginequality1977 checks40783385204; fullUI96/96 40783388166, screenshots inspected.
- Current500focused40789795464 passes.12half-floatcheckpoints useexactly2IOSurfacebackings in25longbuilds;
 100runbuild452msMac, cachedreuse10ms, measuredfootprints564→max584→576MB, unchanged64MBgrowth bound.
-245imaging/Clarity/cache/thumbnail checks40788880285 pass. ActiveSharpenMasking retainsstrongedges and removes
 weakflatnoise;VignetteFeather/Roundness,2perspective4xref cases pass; actualrenders inspected.32RAWthumbjobs
 settle1230–1240MB. ThreecurrentUI export/mask/brightness checks40790759752 pass.
- Noncaching source/readback/export changespass24MPopen/detail/Subject/Heal/HDRexport29checks40788978399,
 peak5325MB, and12MPProRAW25checks40789265261, peak4245MB. Those narrowpasses are not fullrobustnessproof.

## Exact remaining failure (do not hide this behind green counts)

Native24MP run40789798207 aborts134 duringHDRencoding aftera largeHeal: source4496MB, virtualGPUOOM and
MPSmedian_3x3_r_float pipeline assertion at23:50:20. The new dimensions/gain-map inspection was NEVER REACHED.
Then the workflow crashhelper incorrectlylaunches the fullengine suite without the original --memory-export flag
underlldb; that passes2014checks, then bt failsbecauseprocessalreadyexited. This explains the unexpectedlylong
run and doesNOT make the originalnativeexportvalid. Do not call it an ImageIOinspectionhang.

1. Preserve crashdiagnostic args/mode so a narrowcrash can't silentlyrun15minunrelatedfullsuite again.
2. Fullnewengine/memory40790966338 was runninglastcheck; inspect terminalstate/artifacts before anyrestart.
3. Finish trueboundednativeHDRencode and reopenatfullsize withrealHDR/ISOgainmap. Samebudgets/dimensions/HDR;
 noSDR/resolutionfallback. DriverGPUOOM canbevariablebutisactualremainingevidence, notaphonecrashdiagnosis.
4. PhoneClarity/brush/Lens appearance and timing/memory needownerconfirmation; asyncquestionpending. Model
 denoise/inpaintingphotographiclimitsareinAI-VISUAL-REVIEW andthe summary; no blindmodelswaps planned.

## Tester delivery

Existing .github/workflows/tester-build.yml and Sources/TesterExpiry.swift implement the intended expiring build.
Workflow40792070982 dispatched AFTER verifiedSideStorepublication onfe0a94c,days30, run_number3.
Download artifactLumen-tester-ipa toLumenIPA/tester-2026-10-29/Lumen.ipa. Inspect embeddedInfo.plist for
LumenTesterExpires, com.example.lumen, actualversion/build and all4modelcoremldata.bin files; hash locally.
Expiryis30daysfromBUILD(calendarUTCdate), NOT30daysfromeachperson'sinstall. PersonalSideStore has no expiry.
Owner uploads toGoogleDrive manually; don'tupload/sendtoothers. Preserve prior tester-2026-10-26 file.

Rootworkspace isbrush-export-release-notes fromorigin/mainfe0a94c, no appsourceedits. A reviewsummary isuntracked
untilnotescommit. Sandbox workspace sandbox-brush-export has onlyunrelated MARKETING.md/LISTING.md localchanges;
neverstage them. Finalnotesgo throughdocsPRafter publication; no newpublish neededfordocs.
