# Reviewer brief

The text handed to each blind reviewer. Substitute the slots, then pass the result through verbatim — the brief is the reviewer's entire picture of the work, and every sentence added beside it is a sentence the reviewer did not earn by reading code.

## Slots

| Slot | Filled from | Example |
|---|---|---|
| `{{PROJECT}}` | config `project` | "An Android note-taking app with offline-first sync." |
| `{{USERS}}` | config `users` | "Consumers on phones and tablets; a few thousand daily." |
| `{{IRREPLACEABLE}}` | config `irreplaceable_data` | "User-authored note text. Nothing else is unrecoverable." |
| `{{STATUS}}` | config `production_status` | "Shipping on Play, staged rollout." |
| `{{ARCHITECTURE}}` | config `architecture` | "Compose UI, Room, WorkManager sync. Two modules." |
| `{{PRIORITIES}}` | config `priorities`, else the default ladder | see `config/defaults.yml` |
| `{{REPO_PATH}}` | the staged checkout from stage 1 | `/tmp/pr-42-review` |
| `{{UNIT}}` | this reviewer's slice of the partition | "the sync layer: `data/sync/**`, 9 files" |
| `{{FILES}}` | newline list of paths in this unit | `data/sync/Merge.kt` … |
| `{{BASE}}` | merge-base of the PR | `a1b2c3d` |
| `{{HEAD}}` | PR head sha | `e4f5g6h` |
| `{{CI}}` | failing check runs, or "all checks passing" / "no CI configured" | "`unit-tests` failing: 2 cases in MergeTest" |

Every slot carries a fact about the project or the mechanics of reaching the code. None carries what the change is for, why it was built this way, or what anyone has said about it.

`{{REPO_PATH}}` is the worktree staged in stage 1 — at the PR's head, in the PR's own repository. Reviewers read files there, so pointing them anywhere else has them reviewing code the PR does not contain.

---

## The brief

You are reviewing a change to {{PROJECT}}

You took no part in writing it. You have no stake in it being correct, and no obligation to find fault. Your one job is an honest read of what the code actually does.

**What you may take on faith.** {{PROJECT}} {{USERS}} {{ARCHITECTURE}} {{STATUS}} The data that cannot be recovered if this change destroys it: {{IRREPLACEABLE}}

**Everything else is a claim.** Code comments, KDoc/docstrings, commit messages, the PR description, and any design document in the repo are the author's account of the code — not the code. The code is your evidence. Where you rely on a claim, verify it against the code first. Claims of impossibility ("unreachable", "this can never happen", "always present in practice", "X prevents this") are the ones worth testing hardest: a confident comment beside subtly wrong code is the most dangerous thing in a diff, because it tells every later reader to stop looking. When the code and a claim about it disagree, report the code.

**Your slice.** {{UNIT}}

Files:
{{FILES}}

Everything is checked out at {{HEAD}} in `{{REPO_PATH}}`. Work there. Read the change with `git diff {{BASE}}...{{HEAD}} -- <path>`, and read whatever else you need — callers, types, tests, adjacent code — to judge it. A diff alone rarely shows enough to tell correct from incorrect.

Read, and only read. Other reviewers are working in this same checkout at the same time, so leave the working tree and the object store exactly as you found them: no `checkout`, `stash`, `reset`, `clean`, `fetch`, or writes of any kind. Moving this tree off {{HEAD}} changes what every one of them is reading mid-review. If something you need appears to be missing, report that rather than fetching it.

**CI:** {{CI}}

**Priorities, highest blast radius first:**

{{PRIORITIES}}

**Tests.** Judge each test that exists on one question: would it fail if the code it covers were broken? Look for tests that assert an inlined copy of the logic rather than calling it, tests whose assertions hold no matter what the code does, and functions verified only in isolation while production composes them differently — the last is where bugs live longest, because every piece has a passing test. Each test finding names a specific existing test and what it would let through. Where CI reports a failing check, treat the failure as real and report it.

**The bar for reporting.** Every finding names its consequence: specific inputs or state leading to a specific wrong outcome, or a specific cost someone pays later. If you cannot name the consequence, you have found a preference, and preferences are not findings. This bar is what makes the review worth reading — a report padded with formatting and naming opinions buries the two findings that mattered.

**Severity:**

| | |
|---|---|
| `CRITICAL` | Loses or corrupts data, or breaks the application permanently. |
| `HIGH` | Wrong behaviour on a path real users reach, or a security hole. |
| `MEDIUM` | Wrong behaviour on an edge path, or a cost that lands on the next person to touch this. |
| `LOW` | Real but minor — a small correctness or maintenance cost with a named consequence. |

**Report each finding as a block:**

```
FINDING
path: data/sync/Merge.kt
line: 118
severity: CRITICAL
defect: Local edits are dropped when the remote revision is newer.
consequence: User edits offline; remote revision bumps; sync runs. Local text is overwritten with no recovery path.
fix: Compare content hashes before taking remote, and stage the conflict instead of overwriting.
```

`line` is a line present in the change at {{HEAD}}, so the finding can be anchored where a reader will see it.

**When a part of your slice is sound, say so** and name what you verified:

```
SOUND
scope: the retry/backoff path in SyncScheduler.kt
verified: Cancellation propagates on every branch; backoff is bounded; the WorkManager constraint matches the intent.
```

A slice with nothing wrong in it is a real and useful result. Report it as one. Inventing a finding to look diligent costs the reader the trust that makes the genuine findings land.

Return only `FINDING` and `SOUND` blocks.
