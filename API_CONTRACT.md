# API contract

Every RPC this frontend calls, extracted directly from `index.html` and
`admin.html`. This is the complete surface.

**A working implementation is now included** — see [`sql/`](sql/). Load the
three files in order and this frontend runs unmodified. The tables below stay
here as the spec, for anyone who wants to build their own backend instead.

Note the four draw functions (`xf_admin_draw_state`, `xf_admin_draw_next`,
`xf_admin_rehearse_state`, `xf_admin_rehearse_next`) are invoked through a
variable rather than a literal, so a naive grep for RPC names misses them.
There are **42** functions, not 38.

All calls are `POST` to `{SUPABASE_URL}/rest/v1/rpc/{name}` with a JSON body,
via the `window.rpc()` helper in `config.js`. Every function returns a single
`jsonb` object. The convention throughout is `{"ok": true, ...}` on success and
`{"ok": false, "error": "some_code"}` on failure — the frontend switches on
those error strings, so keep them stable and machine-readable, not prose.

`p_secret` / `p_password` are **not** in the tables below because the admin
console injects them into every admin call automatically. Assume every admin
function takes a password argument and verifies it server-side before doing
anything.

`xf_admin_import_renewals` expects rows shaped `{ic, months, name}`. Months
**replace**, never accumulate — every file must carry the cumulative total per
person, not the delta since the last import. That single rule is what makes
re-importing the same export a no-op instead of a disaster.

## Public — callable by anyone with the anon key (7)

These are reachable by any visitor. Validate everything; assume hostile input.

| RPC | Arguments the frontend sends |
|---|---|
| `xf_claim_repost` | `p_ic` |
| `xf_claim_social` | `p_handle`, `p_ic`, `p_platform` |
| `xf_login` | `p_ic` |
| `xf_me` | `p_ic` |
| `xf_my_serials` | `p_ic` |
| `xf_points` | _(none)_ |
| `xf_register` | `p_handle`, `p_ic`, `p_name`, `p_phone`, `p_platform` |

## Admin — password-gated (31)

| RPC | Arguments the frontend sends |
|---|---|
| `xf_admin_adjust_tickets` | `p_delta`, `p_participant_id`, `p_reason` |
| `xf_admin_adjustments` | _(none)_ |
| `xf_admin_check` | `p_secret` |
| `xf_admin_checkin_id` | `p_id`, `p_on` |
| `xf_admin_checkin_scan` | `p_on`, `p_qr` |
| `xf_admin_delete_participant` | `p_id`, `p_password`, `p_reason` |
| `xf_admin_disqualify` | `p_id`, `p_reason` |
| `xf_admin_edit_participant` | `p_handle`, `p_ic`, `p_id`, `p_name`, `p_password`, `p_phone`, `p_platform`, `p_reason` |
| `xf_admin_import_checkins` | `p_rows` |
| `xf_admin_import_renewals` | `p_allow_decrease`, `p_rows` |
| `xf_admin_ledger` | _(none)_ |
| `xf_admin_mark_claimed` | `p_participant_id`, `p_undo` |
| `xf_admin_match_ic` | `p_hashes` |
| `xf_admin_participants` | `p_limit`, `p_q` |
| `xf_admin_projection` | `p_checkin_max`, `p_checkin_pts`, `p_renewal_max`, `p_renewal_pts`, `p_repost_pts`, `p_social_pts` |
| `xf_admin_redraw` | `p_participant_id`, `p_reason` |
| `xf_admin_rehearse_reset` | _(none)_ |
| `xf_admin_reposts` | `p_status` |
| `xf_admin_reset_draw` | `p_confirm` |
| `xf_admin_review_repost` | `p_approve`, `p_id` |
| `xf_admin_set_password` | `p_new`, `p_secret` |
| `xf_admin_set_points` | `p_checkin_max`, `p_checkin_pts`, `p_renewal_max`, `p_renewal_pts`, `p_repost_pts`, `p_social_pts` |
| `xf_admin_set_poster` | `p_facebook`, `p_instagram` |
| `xf_admin_socials` | `p_platforms` |
| `xf_admin_stats` | _(none)_ |
| `xf_admin_today` | _(none)_ |
| `xf_admin_verify_scan` | `p_qr` |
| `xf_admin_voids` | _(none)_ |
| `xf_admin_winners` | _(none)_ |
| `xf_issue_tickets` | _(none)_ |
| `xf_rehearsal_results` | _(none)_ |

## Non-negotiable rules for the implementation

1. **Every admin function verifies the password itself.** The admin console is
   a static HTML file served publicly. It is not a security boundary. If a
   function trusts the caller because "only the console calls it", it is
   already broken.

2. **Never expose tables directly.** Revoke `anon` and `authenticated` on every
   table and enable Row Level Security. All access goes through these
   functions, which run `security definer`.

3. **Return error codes, not messages.** The frontend maps codes to translated
   strings in three languages. A prose error from the database will render raw
   to a customer.

4. **Rate-limit anything a stranger can call in a loop** — registration, login,
   and the admin password check especially.

5. **Do not store identity documents in plaintext.** Hash on arrival; keep the
   hash plus the last four characters for display. Recovering the original must
   be impossible, including for you.

6. **Make the draw itself dumb and auditable.** Pick uniformly at random from a
   table of issued ticket rows. Do not build a weighting layer, do not build an
   override, and log every pick with a timestamp. If a winner is ever
   questioned, the answer has to be a row someone can point at.
