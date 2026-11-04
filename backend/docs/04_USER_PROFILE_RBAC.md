# 04 — User Profile, Roles, Permissions and Ownership

## Identity mapping

* `auth.users.id` (Supabase UUID) **is** `sitesense.users.user_id` (the local
  primary key). One verified identity → exactly one local row, enforced by
  the primary key; no password, hash or refresh token is ever stored locally
  (asserted by `test_database.py::test_no_password_or_token_columns_in_local_users`).
* Profiles are provisioned lazily on the first authenticated request
  (`get_or_create_from_supabase`), so a Supabase user who never called the
  API has no local row — safe and duplicate-free.
* `email` is unique locally and synced from the token; `email_verified` is
  **owned by Supabase** and mirrored one-way.
* Legacy tables `Final_Location_Analysis.sitewise_app.profiles` (Express API)
  and `fyp.users` are NOT authoritative for FastAPI auth; the Express stack
  remains in place for the current frontend. No automatic import of legacy
  accounts is performed.

## Field ownership

| Field | Owner | Mutable by user? |
|---|---|---|
| `email`, `email_verified` | Supabase Auth (mirrored locally) | No (via Supabase flows only) |
| `user_id` | Supabase identity | Never |
| `role`, `account_status` | Local `users` row (administrator-managed) | No (`403` on attempt) |
| `full_name`, `phone_number`, `profile_picture_url` | User (self-service PATCH) | Yes |

## Roles (actual values)

`user` (auto-provisioned default) · `entrepreneur` · `property_owner` ·
`agent` · `administrator`. Public registration may request only entrepreneur /
property_owner / agent; `administrator` is never publicly self-assignable
(domain constant `PUBLIC_REGISTRATION_ROLES` + server-side provisioning of
`user` only).

## Permissions matrix (enforced in `domain/rbac.py` + dependencies)

| Action | user | entrepreneur | property_owner | agent | administrator |
|---|---|---|---|---|---|
| Browse properties / statistics (public reads) | ✔ | ✔ | ✔ | ✔ | ✔ |
| Save / list own saved properties | ✔ | ✔ | ✔ | ✔ | ✔ |
| Read another user's saved list | ✗ | ✗ | ✗ | ✗ | ✔ |
| Create / update / delete **own** property listing | ✗ | ✗ | ✔ | ✗ | ✔ |
| Mutate arbitrary property listings | ✗ | ✗ | ✗ | ✗ | ✔ |
| Store / read own recommendation results | ✔* | ✔ | ✔ | ✔ | ✔ |
| Read another user's recommendation history | ✗ | ✗ | ✗ | ✗ | ✔ |
| Delete arbitrary recommendation results | ✗ | ✗ | ✗ | ✗ | ✔ |
| Create / update / delete virtual tours | ✗ | ✗ | ✔ | ✗ | ✔ |
| List all users / read any profile | ✗ | ✗ | ✗ | ✗ | ✔ |
| Change account status / roles | ✗ | ✗ | ✗ | ✗ | ✔ |

\* `user`-role accounts are active-authenticated but role-unassigned; the
role-gated business endpoints require the specific role.

## Agent verification

An agent role alone grants **no** listing-management rights (see matrix).
Professional verification requires an approval record that no database yet
has — tracked as a gap with a proposed migration in `06_DATABASE_INTEGRATION.md`.
