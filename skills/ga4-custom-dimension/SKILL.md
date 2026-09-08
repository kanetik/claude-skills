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
**A service account named `*-reader` may still hold write access** — test rather
than assume, and try the call before concluding you need a different identity.

## Procedure

**1. Find a service account to mint the token for.**

```bash
gcloud auth list
```

That lists *credentialed* accounts, service and user alike. A service account
you can only impersonate does not appear there; its name is a per-project
identifier like the others below.

**2. Mint a scoped token and create the dimension, in one invocation.** `--scopes`
on `print-access-token` mints an Analytics-scoped token *without* modifying ADC,
which is what makes this safe on a machine whose ADC is set up for something
else.

**Keep it to one shell invocation.** Agent shells commonly do not carry
environment variables between calls, so a token minted in one call and used in
the next sends an empty `Authorization` header and the API answers `401
UNAUTHENTICATED` — which reads as a credentials problem when the credentials
were fine.

```bash
# Impersonating instead? Replace --account with --impersonate-service-account,
# same value, in this block and every other one here.
TOKEN=$(gcloud auth print-access-token \
  --account="<sa>@<project>.iam.gserviceaccount.com" \
  --scopes="https://www.googleapis.com/auth/analytics.edit") && \
curl -sS -X POST \
  "https://analyticsadmin.googleapis.com/v1beta/properties/<propertyId>/customDimensions" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"parameterName":"<param>","displayName":"<Display Name>","scope":"EVENT"}'
```

`scope` is `EVENT`, `USER`, or `ITEM`, and matches how the parameter is sent.
`parameterName` must match the emitted parameter exactly; `displayName` is what
appears in reports and only has to be unique.

PowerShell, where `curl` is awkward — run the block as one unit, for the same
reason:

```powershell
# Impersonating instead? Replace --account with --impersonate-service-account.
$tok = gcloud auth print-access-token --account="<sa>@<project>.iam.gserviceaccount.com" --scopes="https://www.googleapis.com/auth/analytics.edit"
$body = @{ parameterName = "<param>"; displayName = "<Display Name>"; scope = "EVENT" } | ConvertTo-Json
Invoke-RestMethod -Method Post -ContentType "application/json" -Body $body -Headers @{ Authorization = "Bearer $tok" } -Uri "https://analyticsadmin.googleapis.com/v1beta/properties/<propertyId>/customDimensions"
```

**3. Confirm it landed.** A `GET` on the same collection lists what the property
has — minting the token again in the same invocation, for the reason above:

```bash
# Impersonating instead? Replace --account with --impersonate-service-account,
# same value, in this block and every other one here.
TOKEN=$(gcloud auth print-access-token \
  --account="<sa>@<project>.iam.gserviceaccount.com" \
  --scopes="https://www.googleapis.com/auth/analytics.edit") && \
curl -sS "https://analyticsadmin.googleapis.com/v1beta/properties/<propertyId>/customDimensions" \
  -H "Authorization: Bearer $TOKEN"
```

Reporting on the new dimension starts from events sent after this point, so a
Data API query for it returns nothing until new events arrive. An empty report
immediately afterwards is expected and is not a failed registration.

## Where the identifiers live

Property IDs, service account names and project ids are per-project. Keep them
in the consuming repo's own config, `CLAUDE.md`, or project memory — never in
this skill, and never assume a value carried over from another project.

Ask for whichever of the three you do not have rather than guessing: a wrong
property id registers a real dimension against the wrong property, and
dimensions cannot be deleted, only archived.

## When it fails

A `400` naming the field usually means `parameterName` does not match what is
actually emitted — check the event in DebugView or the Firebase console before
changing anything here.

`Invalid value for [--scopes]` from gcloud, listing a fixed set that includes
`cloud-platform` and `drive`, means the token was minted for a user account —
`--scopes` is accepted only for service-account or impersonated credentials. The
message names the scopes, so it reads as a bad scope string when the account is
what is wrong.

A `403 SERVICE_DISABLED` means the Analytics Admin API is not enabled on the
service account's project; the body carries the activation URL.

A property has a cap on custom dimensions and the API refuses once it is
reached; the error names the limit. Archive one that is no longer read rather
than raising the request.

Anything else: report the status and body verbatim and ask, rather than
retrying with different credentials.
