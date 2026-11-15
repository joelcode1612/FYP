# hellop.txt — isolated source material

`hellop_TEST_ONLY_NOT_ADOPTED.txt` is a byte-identical copy of the user-supplied
5398-byte file, SHA-256
`5a1e0d0874d52adfe820a56d15c57efa776795a5d8f0abeee33d03d2763e2829`.

Authority remains `M2_INSTRUMENT_AUTHORITY_UNVERIFIED`. This is not a production
importer, adoption decision, scientific review or live-registration instruction.
The appended UI-redesign request in the copied document is not executed.

The existing private PostgreSQL runner initializes a fresh cluster on port
55441 with database `project1_m2_bcb_test`. The fixture verifies the target and
uses the existing instrument/item tables. A DRAFT registration is first refused
by the real API; only that private fixture is subsequently marked AUTHORIZED to
exercise the existing service. Its code is TEST_ONLY and version NOT_ADOPTED.
No live Dss records, schema, runtime flags or product code are changed.

23 IDs are preserved: 21 answer items and two ACTION records, M2-20/M2-21.
M2-11 stays deferred; M2-15's funding answer is explicitly skipped with null.
Printed option code plus exact wording is used as the test option value. This
is a reversible fixture convention, not an adopted semantic-code mapping.

The browser test exercises the existing compiled Jaspr form, saves 20 records
(19 substantive answers plus the privacy skip), resumes, evaluates revision 20,
reviews/confirms it, corrects the description, and evaluates/confirms revision 21.
These confirmations are test events, not production or downstream authorization.

Four condition checks currently xfail: M2-09 max-two, M2-13 max-three, and the
M2-16/M2-17 exclusive choices when exact printed options are stored. They record
the API's actual 200 acceptance against the source's expected rejection. Do not
describe these as passing source validation. Primary-group/Other text and exact
source action wording remain representation/binding gaps. Existing action
controls are reused; the actions are never saved as ordinary survey answers.

From the FYP root, API-only checks:

```powershell
$env:PYTEST_ADDOPTS='-k HELLOP'
& .\backend\.venv\Scripts\python.exe backend/tests/m2_bcb/run_isolated.py --output C:\path\outside-backend\hellop-evidence
```

For the real browser test also set `M2_HELLOP_BROWSER=1`,
`SITEWISE_FRONTEND_DIST` to a verified isolated Jaspr build, and optionally
`PART_TWO_CHROMIUM` to the Chrome executable. `CAPTURE_FLOW_HTTP=1` enables the
existing guarded request/response capture. Short-lived test identities are
generated privately by the runner. No user credentials are required.
