---
name: ga4-custom-dimension
description: |
  Register a Google Analytics 4 custom dimension from the command line, so an
  event parameter Firebase already collects becomes reportable. Handles the two
  routes that look right and are not — GA4 MCP servers are read-only, and
  default application-default credentials lack the Analytics scope — by minting
  a scoped token for a service account without touching ADC. Use when a GA4
  query rejects a parameter with "is not a valid dimension", when a release is
  about to start emitting a new event param, or when the user says "register a
  custom dimension", "make this param reportable", or invokes
  /ga4-custom-dimension.
allowed-tools:
  - Bash
  - AskUserQuestion
---

# GA4 custom dimension

A parameter Firebase collects is **not reportable** until it is registered as a
GA4 custom dimension. Until then the Data API rejects it:

```
400 Field customEvent:<name> is not a valid dimension
```

Registered parameters return 200.

## Register before the release, not after

**Custom dimensions never backfill.** Every event sent before registration
reports as `(not set)` for that dimension, permanently — registering later fixes
reporting from that moment forward and recovers nothing.

So this runs *ahead of* the release that starts emitting the parameter. Batching
it with the code change loses the early data, which is usually the data anyone
wanted: the first days of a rollout.

Where a change adds a new event parameter, say so and offer to register it now.

## Two routes that look right and are not

**GA4 MCP servers are read-only.** They expose `get_*` and `run_*` only. There
is no create call, so the whole registration path is HTTP.

**Default credentials fail with a scope error.** A user ADC typically carries
`cloud-platform`, which does *not* cover Analytics:

```
403 PERMISSION_DENIED: Request had insufficient authentication scopes
```

Do **not** re-authenticate ADC to fix this. Mint a scoped token instead.

## What you need

| | |
|---|---|
| `gcloud` | authenticated, with a credentialed service account — or Service Account Token Creator on one to impersonate |
| A GA4 property ID | numeric, from the GA4 admin UI or `properties/<id>` in any Data API call |
| `curl` | or any HTTP client; a PowerShell form is given below |

The service account needs Editor on the GA4 property, granted in GA4 Admin →
Property Access Management by adding its email. A GCP IAM role grants nothing
here, so granting one and still getting a `403` is the usual first wrong turn.
**A service account named `*-reader` may still hold write access** — the name is
not the role. Step 2's read does not settle it: any role down to Viewer can read
a property, so a `200` there says the identity reaches the property and the scope
is good, and nothing about Editor. Write access is not testable without writing,
so a `403` on step 3 is the first sign that this grant is missing — "When it
fails" says what to do about it.

## Procedure

**1. Find a service account to mint the token for.**

```bash
gcloud auth list
```

That lists *credentialed* accounts, service and user alike. A service account
you can only impersonate does not appear there; its name is a per-project
identifier, as are the property id and project id the blocks below need. Ask for
any of the three you do not have rather than guessing.

**Two things govern every block below.** `--scopes` on `print-access-token` mints
an Analytics-scoped token *without* modifying ADC, which is what makes this safe
on a machine whose ADC is set up for something else. And **keep each block to one
shell invocation**: agent shells commonly do not carry environment variables
between calls, so a token minted in one call and used in the next sends an empty
`Authorization` header and the API answers `401 UNAUTHENTICATED` — which reads as
a credentials problem when the credentials were fine.

**2. Check what step 3 is about to write.** The property id is a bare number, so
a stale one from another project looks exactly like the right one — and nothing
step 3 writes can be undone. Read the property back, and put the name it returns
to the user:

```bash
# Impersonating instead? Replace --account with --impersonate-service-account,
# same value, in this block and every other one here.
TOKEN=$(gcloud auth print-access-token \
  --account="<sa>@<project>.iam.gserviceaccount.com" \
  --scopes="https://www.googleapis.com/auth/analytics.edit") && \
curl -sS -w "\nHTTP %{http_code}\n" \
  "https://analyticsadmin.googleapis.com/v1beta/properties/<propertyId>" \
  -H "Authorization: Bearer $TOKEN"
```

```powershell
# Impersonating instead? Replace --account with --impersonate-service-account.
$tok = gcloud auth print-access-token --account="<sa>@<project>.iam.gserviceaccount.com" --scopes="https://www.googleapis.com/auth/analytics.edit"
Invoke-RestMethod -Headers @{ Authorization = "Bearer $tok" } -Uri "https://analyticsadmin.googleapis.com/v1beta/properties/<propertyId>"
```

**Go on to step 3 only when the call returned the property and the user has
confirmed all three of these**, which is everything step 3 writes that cannot be
changed afterwards:

| | |
|---|---|
| the property | `displayName` from the response, not the number you sent |
| `parameterName` | exactly as the app emits it, read off the analytics call site in the code — `Immutable`, and pre-release there is nowhere else to check it |
| `scope` | `EVENT`, `USER` or `ITEM`, matching how the parameter is sent — also `Immutable` |

None of those judgements is yours to make, and **none of the three fails
loudly**. A property you can reach but did not mean returns `200` and takes the
write; so do a wrong `parameterName` and a wrong `scope`, on a dimension that
then reports `(not set)` for ever. A name you have never seen reads as plausible
either way, which is what the confirmation is for.

**Anything else stops here** — an error, or anything the user does not confirm.
Say what came back and ask. The PowerShell form prints no status line and throws
on a 4xx, so there what came back is the error it raises. A `403` is the
ambiguous one: a property that does not exist, one this identity cannot see, a
missing scope, and an API that is not enabled all return it, and none of them
tells you the id is right.

**3. Create the dimension.**

```bash
# Impersonating instead? Replace --account with --impersonate-service-account,
# same value, in this block and every other one here.
TOKEN=$(gcloud auth print-access-token \
  --account="<sa>@<project>.iam.gserviceaccount.com" \
  --scopes="https://www.googleapis.com/auth/analytics.edit") && \
curl -sS -w "\nHTTP %{http_code}\n" -X POST \
  "https://analyticsadmin.googleapis.com/v1beta/properties/<propertyId>/customDimensions" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"parameterName":"<param>","displayName":"<Display Name>","scope":"<EVENT|USER|ITEM>"}'
```

`displayName` is what appears in reports and is one of the fields you can change
afterwards: max 82 characters, alphanumeric plus space and underscore, starting
with a letter.

```powershell
# Impersonating instead? Replace --account with --impersonate-service-account.
$tok = gcloud auth print-access-token --account="<sa>@<project>.iam.gserviceaccount.com" --scopes="https://www.googleapis.com/auth/analytics.edit"
$body = @{ parameterName = "<param>"; displayName = "<Display Name>"; scope = "<EVENT|USER|ITEM>" } | ConvertTo-Json
Invoke-RestMethod -Method Post -ContentType "application/json" -Body $body -Headers @{ Authorization = "Bearer $tok" } -Uri "https://analyticsadmin.googleapis.com/v1beta/properties/<propertyId>/customDimensions"
```

**4. Confirm it landed.** A `GET` on the same collection lists what the property
has — minting the token again in the same invocation, for the reason above:

```bash
# Impersonating instead? Replace --account with --impersonate-service-account,
# same value, in this block and every other one here.
TOKEN=$(gcloud auth print-access-token \
  --account="<sa>@<project>.iam.gserviceaccount.com" \
  --scopes="https://www.googleapis.com/auth/analytics.edit") && \
curl -sS -w "\nHTTP %{http_code}\n" \
  "https://analyticsadmin.googleapis.com/v1beta/properties/<propertyId>/customDimensions?pageSize=200" \
  -H "Authorization: Bearer $TOKEN"
```

```powershell
# Impersonating instead? Replace --account with --impersonate-service-account.
$tok = gcloud auth print-access-token --account="<sa>@<project>.iam.gserviceaccount.com" --scopes="https://www.googleapis.com/auth/analytics.edit"
Invoke-RestMethod -Headers @{ Authorization = "Bearer $tok" } -Uri "https://analyticsadmin.googleapis.com/v1beta/properties/<propertyId>/customDimensions?pageSize=200" | Select-Object -ExpandProperty customDimensions | Format-Table parameterName, displayName, scope
```

Look for the `parameterName` you just registered in that list. A `nextPageToken`
in the response means the list is truncated, and a missing name proves nothing
until you have fetched the rest.

Reporting on the new dimension starts from events sent after this point, so a
Data API query for it returns nothing until new events arrive. An empty report
immediately afterwards is expected and is not a failed registration.

## Where the identifiers live

Property IDs, service account names and project ids are per-project. Keep them
in the consuming repo's own config, `CLAUDE.md`, or project memory — never in
this skill, and never assume a value carried over from another project.

None of it can be taken back. A wrong property id registers a real dimension
against a property you did not mean; a wrong `parameterName` or `scope`
registers one that never reports anything. Dimensions cannot be deleted, only
archived, and each one spends a slot against the property's cap — which is why
step 3 does not run until the user has confirmed all three.

## When it fails

A `400` is answered by the response body, which names the constraint that was
violated — an invalid character or an over-length value in `parameterName` or
`displayName`, a reserved `ga_`/`firebase_`/`google_` prefix, or a
`parameterName` already registered at this scope. The create call validates
the request and nothing else: it cannot see your event data, so a `400` never
means the app is not emitting the parameter. That question belongs after the
release, when a registered dimension reports `(not set)` and DebugView has
something to show.

On the impersonation route gcloud warns that `--scopes` "may not work as
expected and will be ignored for account type impersonated_account". It is not
ignored — the scopes are applied to the impersonated credential and reach
`generateAccessToken`. Proceed; the call returning `200` is the answer.

`Invalid value for [--scopes]` from gcloud, listing a fixed set that includes
`cloud-platform` and `drive`, means the token was minted for a user account. A
user account takes `--scopes` only from that fixed list, and `analytics.edit` is
not on it; a service account or an impersonated one takes any scope. The message
names the scopes, so it reads as a bad scope string when the account is what is
wrong.

A `403 SERVICE_DISABLED` means the Analytics Admin API is not enabled on the
service account's project; the body carries the activation URL.

A `403` on the create call *after* step 2's read succeeded is the property role:
the identity can see the property but is not an Editor on it. Grant that in GA4
Admin → Property Access Management — step 2 cannot catch this, because reading a
property needs no more than Viewer.

A property has a cap on custom dimensions and the API refuses once it is
reached; the error names the limit. Archive one that is no longer read rather
than raising the request.

Anything else: report the status and body verbatim and ask, rather than
retrying with different credentials.
