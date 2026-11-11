# Applied restrictions and responsibilities at this checkpoint

R01–R10 names below are traced to `Project1_Studio/docs/APPLIED_RULES_AND_WORKFLOW.md` V1.1. That standalone package is a behavioral reference, not adopted backend infrastructure. CP07 preserves established backend contracts and does not pretend every old demonstration control has been integrated.

| Rule | Backend behavior now | Coverage / remaining work |
|---|---|---|
| R01 Server-owned sources | Existing cryptographically verified identity and local role/status; owner-scoped PostgreSQL reads; explicit current revision and confirmation; strict decision payload rejects actor and approval fields | VERIFIED source bridge; tenant/purpose/BCB grants still required downstream |
| R02 Key/destination | No cloud adapter, no key loading or provider request added | NOT_IMPLEMENTED for live execution; no paid/free-provider claim or fallback |
| R03 Local access | Default-off stage guard before profile sync; existing bearer-JWT FastAPI architecture retained | Stage guard verified. Standalone Studio CSRF/Host mechanism was not copied into the established API; no public deployment authorization |
| R04 Schema/source validation | Actual snapshot digest, instrument/revision and exact answer references/values checked; UC payload types/actions/length/extra fields validated | VERIFIED for source/UC edge only; QJ/QG schema, semantic/source validation absent |
| R05 Analytical freedom | Both BDJ candidates preserved pending adoption | NOT_EXECUTED; no claim of model discovery quality |
| R06 Responsibilities | M2 owns source facts; existing UC function owns decisions and atomic persistence; history read does not become objective creation or BCB | VERIFIED in bounded tests; BDJ/BCB/QJ/QG integration unresolved |
| R07 Finite work | No model execution path or retry loop added | Six-attempt durable enforcement NOT_IMPLEMENTED. Zero calls does not establish a working attempt ledger |
| R08 Idempotency | Existing UC function exact-event replay survives fresh database connection; changed payload rejected | VERIFIED for UC decisions at SQL layer. Shared workflow/model idempotency remains NOT_IMPLEMENTED |
| R09 No model authority | No scientific, publication, fielding or report action exposed; returned downstream handoff is false | VERIFIED source/history responses and strict UC body. No model output tested |
| R10 Scientific discipline | Fixture approval, JSON pass, JWT validity and successful engineering tests explicitly do not imply scientific validity or Owner authorization | All scientific/fielding/report acceptance remains pending/not authorized |

Injection-like text in the synthetic M2-04 fixture is preserved as source data, never executed or promoted into authority. This is a boundary test, not a claim of complete injection detection or live-model resistance.

Entrepreneur confirms intention through authenticated UC decisions. The database function enforces ownership/currentness/version/idempotency/transaction semantics. Business Understanding should explain concerns without forcing objectives. BDJ proposes findings; BCB assembles permitted context; QJ assesses method; the bank steward controls equivalence/approval; QG drafts under frozen measurement; independent reviewers assess science; Owner authorizes exact versions; fielding and report admission remain separate authorities. Missing code should fill these roles within the current monolith after its authority is pinned.
