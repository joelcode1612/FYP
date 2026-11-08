# Project1 customer questionnaire — Flutter UI prototype

A runnable, self-contained mobile project using **MVVM + Riverpod**. Includes the welcome/consent screen, adaptive Q01–Q13 flow, Q05 concept card and selected-option styling, editable review, and local submission confirmation. EN/BM toggles preserve the session. All text is draft wording; BM requires bilingual review.

This is **MOCK-UI-1**, for synthetic walkthroughs. It is not an approved survey, scientific instrument, production router, or fielding release. No backend or database is called. Use invented responses only.

## Run

Verified toolchain: Flutter 3.44.6 stable / Dart 3.12.2 on Windows. Android SDK/JDK setup is needed for an Android build. iOS requires macOS and Xcode.

Unzip the project, open a terminal in `project1_customer_mobile` (the folder containing this README and `pubspec.yaml`), then:

```sh
flutter pub get
flutter devices
flutter run -d <device-id>
```

For a browser preview: `flutter run -d chrome`. For Android: start an emulator or connect a device with USB debugging, then run the command above. The Android launcher name is **Project1 Demo**.

```sh
flutter analyze
flutter test --reporter expanded
flutter build apk --debug
flutter build web --release
```

The APK is written to `build/app/outputs/flutter-apk/app-debug.apk`. For the device integration test:

```sh
flutter test integration_test/app_test.dart -d <android-device-id>
```

The ZIP includes the lockfile and Android, iOS, and web scaffolding. It excludes local SDK paths, caches and build outputs. Release signing is the Flutter template's debug configuration; distribution signing is not set up. See `docs/VERIFICATION.md` for the checks actually completed on this delivery. iOS scaffolding does not establish iOS build verification.

## Walkthrough

1. Read the demo details, enable consent, and start. The Start button is disabled until consent is selected. Participation can be withdrawn and the whole session cleared.
2. Choose an affiliation in Q01 for the longer mock route; choose Rarely, Never or Not sure for the two-item route. Q02 is always asked after Q01. Q02 never adds an eligibility threshold.
3. Q04 = 0 occasions / cannot remember / refusal excludes Q08. A positive purchase band includes it. Q09 can still appear when Q04 is zero; it asks hypothetical future occasions.
4. Q06 allows up to three selections, with exclusive terminal options. Q10 has three clearly synthetic feature rows and requires a separate rating for each. Refusal is available per feature. No combined feature score is calculated.
5. Q11–Q13 are optional. Press Skip or continue without a selection; no response is invented. Review distinguishes answered, optional skipped, unvisited, outside-route and previously displayed/excluded items. Expand sections to inspect actual answers or edit them.
6. Submission displays a **local-only** confirmation. No server upload or durable save happens. Clear/reset erases answers, consent and exposure history; language and demo setup are retained. Browser refresh/app process termination also clears the in-memory session.

Before starting, expand **Demo setup** to disable synthetic concept/menu/offer/occasion/feature fixtures or optional questions. These switches mean fixture availability, not approval. Setup is frozen after the session starts; clear the session to change it.

## Architecture

```text
lib/
  main.dart                          ProviderScope bootstrap
  data/questionnaire_repository.dart Bundled questions and synthetic stimuli
  model/question.dart               Typed options, local text, answers, config
  model/mock_routing.dart            Pure deterministic demo routing
  model/questionnaire_state.dart     Immutable state and summary derivations
  viewmodel/questionnaire_viewmodel.dart
                                     Riverpod Notifier and user intents
  view/                              Screens and reusable controls
test/                                Routing, state, source-code and UI tests
integration_test/                    Real-device Flutter UI walkthrough
docs/                                Reference, provenance and verification
artifacts/                           Rendered evidence from verification
```

Views watch `questionnaireProvider` and send intents to its `Notifier`; they do not own separate answer copies. Switching language, going back, and editing from review use the same shared session. No code generation or `.g.dart` files are needed. This uses Riverpod's documented [Notifier/ProviderScope approach](https://riverpod.dev/docs/concepts2/providers).

When upstream choices change, the ViewModel recomputes the route and clears answers/skips for questions excluded from it. It retains exposure history so review can say a question was previously shown. Re-entering that route does not restore the old answer. Required missing values and unvisited items block submission.

Progress is resolved questions / current mock route length (answers or explicitly skipped optional items). **Shown** counts unique displayed question identities currently on the route. **Answered** requires a complete structured response and includes uncertainty/refusal choices; it is not a substantive-valid count. A partially rated Q10 counts as incomplete. No I/Q/S/A/V scientific denominators or analytical report are implemented.

Default route with Q01 = LIVE and Q04 = ZERO: **12 shown, 9 answered, 3 optional skipped** if the three optional questions are skipped. With Q04 = ONE: **13 shown, 10 answered, 3 optional skipped**. With Q01 = NEVER: **2 shown, 2 answered**. Other fixture configurations shorten routes. The bank always has 13 identities, not 13 required answers for every person.

## Demo routing, not authorization

| Questions | MOCK-UI-1 presentation |
| --- | --- |
| Q01, Q02 | Always, with Q02 after Q01 |
| Q03 | Mock affiliation + synthetic concept |
| Q04 | Mock affiliation |
| Q05 | Mock affiliation + synthetic concept |
| Q06 | Mock affiliation + synthetic concept + demo menu |
| Q07 | Mock affiliation + synthetic concept + exact demo offer |
| Q08 | Mock affiliation + Q04 positive purchase band |
| Q09 | Mock affiliation + synthetic concept + occasion module; independent of Q04 |
| Q10 | Mock affiliation + synthetic concept + synthetic feature bank |
| Q11 | Optional module + mock affiliation + synthetic concept |
| Q12 | Optional module + mock affiliation |
| Q13 | Optional module + mock affiliation + synthetic concept + defined demo offer |

Affiliation codes are LIVE, WORK, STUDY, RUN_BUSINESS, VISIT_PURPOSE, PASS_THROUGH. The screen behavior is a demonstration, not a valid eligibility definition. Q01 mutually exclusive selections clear incompatible selections as proposed in the referenced conversation. This differs from the frozen contract's older terminal-wins treatment of conflicting raw payloads. This app does not modify or activate that contract or any backend candidate.

## Provenance and design

The owning workspace was verified before edits at `C:\Users\HP\OneDrive\Desktop\sport-marketplace\FYP`, branch `codex/cust03-backend-candidate-20261107`. This project was added as a separate subfolder; it is not registered in the Dart workspace and does not replace the existing Sitewise app or modify its backend.

Question IDs and option-code sets trace to `backend/src/sitewise/customer_contracts/reference/CUST_RECOVERY_20261027/CUST03_CORRECTED_QUESTIONNAIRE_AND_ROUTING_CONTRACT.json`, SHA-256 `ec2b5494ecf82447076e0d7a2bfb57599a24f049bbcc925a9ecbea6e833bce59`. A small documentary excerpt is in `docs/source_catalogue_excerpt.json`; automated tests compare every option-code set against it. This is traceability, not validation.

`docs/design_reference.png` is the three-screen image recovered from the referenced conversation (the original `/mnt/data` path was unavailable on this Windows host). The navy/blue cards, bilingual controls, welcome layout, Q05 badge, radio rows, progress bar and review sections follow it. Wording, progress and section grouping were adjusted to avoid inaccurate “13 of 13 completed” claims and incorrect grouping of occasions/features as spending.

`assets/cafe_hero.png` is generated artwork, not a photo of a real proposed business. Built-in image generation prompt: “Use case: photorealistic-natural. Asset type: bundled background photo for a Flutter customer questionnaire welcome screen. Wide landscape composition. A white ceramic cappuccino cup with elegant heart latte art on a white saucer on the right side of a light oak cafe table, small croissant behind, soft bright neutral neighborhood cafe window in background. Natural daylight, realistic photography, soft navy and cream friendly atmosphere. Keep left half mostly pale and uncluttered for navy title overlay. No text, logos, people or UI. Save a landscape image.”

## Limitations

- No scientific acceptance, Owner adoption, authorized concept/menu/offer/feature bank, ethics approval, or human EN/BM pretesting is established. The synthetic stimulus details and closed “another category/occasion” options are proposals.
- This app deliberately uses its own mock route. It has no C0/C1 integration, fielding release gate, production API, authentication, persistence, analytics, report renderer or per-question result graphs. The deliverable is questionnaire UI code.
- Q13 follows the screenshot's later price-expectation placement after Q07's visible exact price. That can anchor expectations; do not interpret these demo answers as unbiased pricing evidence. Presentation/ordering and scales need review.
- Physical-device and iOS behavior need separate checks. Widget rendering and an Android emulator cannot prove accessibility, scientific validity or translation quality. No live data should be entered.
