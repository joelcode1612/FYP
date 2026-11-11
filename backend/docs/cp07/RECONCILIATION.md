# CP07 reconciliation before implementation — 2026-11-11

Scope: bounded development in this FastAPI backend. Baseline branch `merge_main_jed`, HEAD `bd386a7c203ea3688ce4df3838570eda325f0734`. Existing dirty files and UC B4 work are preserved. No production release, migration, scientific acceptance or fielding is authorized.

## Authority and implementation matrix

Paths in this table are relative to `backend/`. Classifications concern the current checkout, not historical test claims.

| Component | Evidence / version / approval | Classification | Recommendation and trade-off |
|---|---|---|---|
| M2 instrument, answers, confirmation | `db/models/m2_schema.py`, `services/m2_service.py`, `services/confirmation_service.py`, `repositories/m2_repository.py`; immutable answer revisions and SHA256 snapshots. Instruments must have authoritative `AUTHORIZED` state. No questionnaire is seeded by integration. | IMPLEMENTED_UNVERIFIED before this run | REUSE repository/service and add authenticated confirmed-source retrieval. Verify on isolated schema clone. Existing confirmation still depends on unresolved BDJ authority. |
| Narrow BDJ | `src/sitewise/domain/bdj_rules.py`, `BDJ-EXPLICIT-FORMAT-0.1-CANDIDATE`, introduced by `0f3658a`; explicit service-format conflict only; 33-character identifier exceeds existing VARCHAR(32). | CONFLICTING_IMPLEMENTATIONS | ADAPT only after Owner selects exact adopted rules/version and schema disposition. Do not truncate version or substitute rules. |
| Broader BDJ | `src/sitewise/db/bdj_rules.py`, `BDJ-RULESET-0.2-CAND`, same introduction commit; five candidate detectors, explanatory notices, catalogue, stricter ambiguity suppression. `services/bdj_service.py` expects these symbols from the narrow domain module, causing import failure. | CONFLICTING_IMPLEMENTATIONS | Preserve both. Candidate provenance and Git presence are not Owner adoption. No verified adoption record located in inspected sources/history. |
| UC decision gateway | Existing untracked `repositories/uc_decision_gateway.py`; CP1 B2/B3/B4 stage-only V2 function `project1_uc.record_authenticated_entrepreneur_decision`; exact restricted role/database/port/major checks. | IMPLEMENTED_UNVERIFIED in current checkout | REUSE untouched gateway; connect authenticated API with dedicated restricted session. SQL owns ownership, source checks, idempotency and atomic M2+UC writes. |
| UC history | Existing seven-table `project1_uc` schema and canonical `m2_confirmed_uncertainties`; no current read API. Historical `services/uc_access.py` exists in Git history/artifacts, absent at HEAD. | DOCUMENTED_NOT_IMPLEMENTED for current HTTP bridge | ADAPT by reading owner-scoped existing records; never reimplement decision semantics. History is not QJ admission. Approved production read grants/interface remain unresolved. |
| BCB | External `BCB-V1-1.0.0-SANDBOX`, `business-context-package/1.0`, `BusinessContextBuilderV1.get_context`; CP00 V0.4 reconciliation describes purpose/identity/version pinning. No adopted target adapter or persisted context lookup found. | DOCUMENTED_NOT_IMPLEMENTED in target | ADAPT external builder when adoption is identified; CREATE only missing target adapters, not a second builder. Required behavior is substantially specified; adoption/storage authority missing. |
| QJ/QG | Security-role checkpoint V0.1 and workflow V1.1/V1.3 specify four routes, complete measurement contract, frozen drafting metadata and candidate-only outputs; no target implementation found. | DOCUMENTED_NOT_IMPLEMENTED | CREATE within existing services/ports once governing versions are confirmed. No need to restart behavioral design. Do not import synthetic Studio route selection as established research rules. |
| Shared LLM / durable attempt ledger | External execution/observability V0.1/V0.2 proposals; no live adapter, approved storage schema, registered engines or restart-safe ledger found. Backend `ModelLoader` is ML artifact loading, not this facility. | DOCUMENTED_NOT_IMPLEMENTED | CREATE shared infrastructure once storage/adoption is confirmed. Six-call ceiling is required by CP07, but cannot honestly claim restart-safe enforcement without approved durable storage. |
| Bank | No authoritative exact item/version/equivalence approval register located. Synthetic `SYN-QBANK-V1` is not authority. | SOURCE_NOT_FOUND for authority | ADAPT real steward interface when identified; withhold reuse/fielding meanwhile. Never activate Q01–Q13 by existence. |
| JWT / role enforcement | `dependencies.py`, `core/security.py`, local `users` role/status; asymmetric verifier, issuer/audience/expiry, entrepreneur dependency. | IMPLEMENTED_UNVERIFIED for this integration | REUSE. Test cryptographic verification with local test JWKS; this does not establish real Supabase-account credential acceptance. |
| States/audit | M2 revision/review/finding states exist. External `03_STATUS_AND_TRANSITION_CONTRACT.md` is proposed; no adopted shared workflow ledger located. | DOCUMENTED_NOT_IMPLEMENTED for shared axes | ADAPT local states without renaming. CP07 response describes read outcome only; does not persist invented scientific or Owner transitions. |
| Privacy / consent | V0.1 trust classes T0–T4, source text as data, minimum purpose disclosure, no raw secrets. Live provider disclosure consent/version/retention register not found. | DOCUMENTED_NOT_IMPLEMENTED for live disclosure gate | REUSE auth and minimum source reads. Zero cloud calls; no raw application source text in logs. Provider execution blocked pending disclosure/credentials/storage authority. |

## Search boundary and supporting evidence

Inspected current backend/shared_logic, relevant Git history/file inventories (including all refs), CP00 V0.4 and G2 V0.5 reconciliation, UC migration-review package and recorded staging schema snapshots, master workflow proposal, security-role checkpoint V0.1, and existing standalone Studio material. `git log --all --name-only -- backend` finds UC adapters/history but no BCB/QJ/QG/shared-LLM source names; current content searches likewise find no canonical implementations. Negative evidence is bounded to these sources, not proof no implementation exists elsewhere.

Both BDJ files were introduced at `0f3658a9948d9ac3540a1a5e486cf47e55506d22` (candidate/default-off lane). CP00/G2 traced narrow content to the original M2 patch and broader content to the Phase3 correctness candidate; neither supplied verified adoption. No ruleset was selected in this change.

Exact external BCB implementation located and inspected: `C:/Users/HP/Documents/Codex/2026-11-08/referenced-chatgpt-conversation-this-is-an-2/outputs/PROJECT1_BUSINESS_CONTEXT_BUILDER_V1_0_0/backend/src/sitewise/services/business_context_v1.py`; port in sibling `ports/business_context_v1_port.py`; behavioral and authorization contract in that package's `docs/INTERFACE_CONTRACT.md`. It requires independently owned tenant/concept/GEO/purpose/source grants, not just M2 answers. This is an existing candidate implementation with missing live adapters/adoption, not a missing BCB design.

Git history also locates `src/sitewise/services/uc_access.py` in stash/index commit `e7cbf469f869608ae64e2066935573252e8de6e7`; it is a small owner/currentness guard, not a UC read service. It is absent at current HEAD. No stash was restored or changed.

After this run, the new M2 retrieval and UC history HTTP bridges are IMPLEMENTED_VERIFIED only for controlled PostgreSQL schema-clone/test-JWT coverage. The untouched UC decision gateway is wired but successful HTTP persistence remains IMPLEMENTED_UNVERIFIED: existing approved ports were occupied and the private high-port target is deliberately denied. The underlying existing UC function was independently exercised through a real restricted login on the private clone. See ACCEPTANCE.md for exact distinctions.

## Independent work authorized now

Add a separately default-off, staging-only CP07 HTTP bridge using existing JWT, M2 service/repository and untouched UC decision gateway. Retrieve and verify actual persisted confirmation/answer versions; expose existing UC history without treating M2-17 or findings as objectives. Use isolated PostgreSQL schema snapshots and synthetic controlled records only. No migration execution against Dss, schema change, new M2/UC domain service, BCB replacement or LLM runtime.

## Decisions needed

1. Exact BDJ ruleset adoption/version and 33-character/schema conflict disposition.
2. BCB sandbox adoption or canonical source path plus purpose authorization contract.
3. Governing adopted QJ/QG versions, bank approval owner/register and drafting authorization.
4. Approved durable model/audit storage, privacy/disclosure and retention contract. Then implement the missing shared code within this monolith.
5. Production UC read permissions/interface and deployment authorization remain separate from the verified staging function contract.
