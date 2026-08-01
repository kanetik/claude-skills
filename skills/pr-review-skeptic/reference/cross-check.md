# Cross-check brief

Runs once, after every blind reviewer has returned. This is the stage that **reconciles** findings against the PR's review history: the findings are already fixed in writing before it starts, so nothing here can shape what was found — only how it is bucketed.

Stage 3 reads that history too, for the two things it hands the reviewers up front (which commit was last reviewed, and which non-blocking consequences the project has accepted). So this is no longer the only route history takes into a run, and the guarantee to state precisely is the narrow one: **by the time this brief is built, every finding below already exists.**

Hand this to one subagent, with the merged findings and the PR's prior review history: threads with their replies, resolution state, and `isOutdated` flag; review bodies; **the PR's issue comments**; the PR description; and the commit list with the paths each commit touched ([`mechanics.md`](mechanics.md)). The commits and `isOutdated` are what let it tell a concern that was *changed* in response from one that was only argued about — without them the `unfixed` / `re-raised` split is a guess, and a wrong guess raises a severity and posts a blocking comment. The issue comments carry dispositions for findings that had no thread to reply on; omit them and exactly those findings come back `new` every round.

Skip this stage when the PR has no prior review activity; every finding is new by definition.

**Every input above is required for the bucketing to mean anything.** Assembling this payload is more work than the other stages and the failure is silent: a payload missing the commit paths still produces confident buckets, just wrong ones, and a stage that quietly degrades to "everything is `new`" is indistinguishable from a PR with no history. Where an input cannot be collected, say which one and what it costs, rather than dispatching a thinner payload and reporting a normal result.

---

## The brief

Below are findings from reviewers who read the code at HEAD without seeing this PR's history, and below them, that history.

Every finding describes the code **as it stands now** — a reviewer read it and saw the defect at HEAD. History tells you what has already been discussed, not what is still true.

Classify each finding into exactly one bucket.

**`new`** — no prior thread raised it. Most findings land here. Pass through unchanged.

**`unfixed`** — a prior thread raised this same defect and a change was made in response, yet a reviewer reading HEAD still finds it. The earlier fix did not land, or landed partially. "A change was made in response" needs evidence that ties a commit to *this concern*: a commit postdating the thread whose diff touches that thread's path at or around its line, or a reply on that thread recording the disposition `fixed` (see the disposition records below). `isOutdated` on its own does not carry it — a rebase or a formatting pass flags every thread in the PR outdated at once, and treating that as a fix would escalate every re-found finding in one go. Where only `isOutdated` holds, or nothing does, the finding belongs in one of the two buckets below at its stated severity. **Raise severity one rung**, `CRITICAL` being the ceiling — an unfixed `CRITICAL` stays `CRITICAL` and is marked unfixed, since a rung invented above it matches no entry in `blocking_severities` and would drop the most serious finding the skill can produce out of the verdict entirely. Note how many rounds have touched it. Code that has been fixed twice and is still wrong is the strongest signal this review produces: every reader who looked at it concluded it was handled.

**`re-raised`** — a prior thread raised this concern and it was dismissed, argued down, or closed without a change, and a reviewer who never saw that exchange landed on it independently. **Keep at its stated severity and mark it re-raised**, naming the prior thread. An independent reviewer arriving at a concern someone talked their way out of is worth more than either verdict alone.

**`settled`** — a prior thread weighed this same consequence and the project chose otherwise, and the finding names no consequence that choice failed to account for. This is a decision, not a defect. **Move it out of the findings and into the settled list**, with the thread it was decided in. A finding bucketed here is not dropped: a blocking one is still named in the verdict, so a decision to live with it stays visible.

The discriminator between `settled` and `re-raised` is the consequence, not the topic. Two findings can name the same file and line and land in different buckets: if the prior thread weighed the same outcome and accepted it, the matter is settled; if the finding names an outcome that exchange never considered, it stands.

## Disposition records

Where the pull request is being driven by an agent, the author's replies carry a machine-readable line saying what they decided:

```
<!-- pr-review-loop: disposition=fixed -->          the concern was accepted and a change was made
<!-- pr-review-loop: disposition=rejected -->       the concern was understood and the code kept as-is, with a rationale
<!-- pr-review-loop: disposition=acknowledged -->   the concern was agreed to be correct, and judged not a problem worth changing
<!-- pr-review-loop: disposition=deferred -->       the concern was accepted as real and tracked elsewhere, out of scope here
```

They appear as a reply on the finding's own thread. For findings the earlier run could not give a thread to, they appear instead as entries in a PR-level issue comment ending `<!-- pr-review-loop: dispositions -->`, each entry naming the path and restating the finding — match those on the finding's substance, since there is no line to match on.

Where a record matches a finding, it is the best evidence available for **what was decided**: `rejected`, `acknowledged` and `deferred` all mean the concern was weighed and the project chose otherwise; `fixed` on a finding a reviewer still sees at HEAD → `unfixed`, with the severity rise, because a direct claim that this concern was fixed is exactly what that bucket is about.

`acknowledged` is the author agreeing the observation was correct and judging it not worth changing — a decision about **materiality**, not about correctness. So do not treat the finding's correctness as evidence against it: a reviewer re-finding the same true thing is expected and is not a reason to escalate. What *would* stand is a finding naming a consequence that judgement did not weigh — the ordinary test below, applied to a decision about whether something matters rather than about whether it is right.

**It does not decide the bucket on its own, and the consequence test above still governs.** A `rejected`, `acknowledged` or `deferred` record buckets the finding `settled` only where the finding names no consequence the recorded rationale failed to account for — the same discriminator as any other prior thread. Where the finding names an outcome that rationale never considered, it is `re-raised` at its stated severity, citing the record. Otherwise the `re-raised` bucket would be unreachable on any agent-driven PR, since those stamp a record on every finding they answer, and one rejection would immunise a defect against every later independent re-discovery — which is the failure the whole blind pass exists to catch.

What you must not do is re-argue a rationale that *does* cover the finding's consequence. Take that at face value even where you find it unconvincing: re-opening it is what these records exist to stop, and the check on a bad rejection is that a blocking `settled` finding is still reported in the verdict rather than hidden.

**Where more than one record matches**, the most recent decides — a threadless finding accumulates one entry per round, and a finding `deferred` in round 3 and `fixed` in round 6 is an `unfixed` finding, not a settled one. The earlier entries are where the round count for an `unfixed` finding comes from.

The absence of a record decides nothing. Most PRs have none at all, and a human author's reply is prose; read it as prose and bucket on its meaning, exactly as above.

## Recognising this skill's own earlier threads

Some prior threads are this skill's own, from an earlier run over the same PR: their comments end with the marker line `<!-- pr-review-skeptic -->`. Match on the marker, not on the author — these reviews are posted under the user's own account and look exactly like a hand-written one.

**How to match depends on the thread's `subjectType`**, and getting this wrong is how a run posts a second thread beside its own original:

- `LINE` — match on `line`, falling back to `originalLine` where `line` is null, which is every thread the last push marked outdated.
- `FILE` — a whole-file thread, which this skill posts for findings that had no line to anchor to. **Both `line` and `originalLine` are null on these, permanently, outdated or not**, so a line-based key matches nothing and every file-level finding looks new on every run. Match on `path` plus the substance of the finding instead.

A null `line` therefore does not by itself mean the thread is outdated — read `subjectType` before concluding anything from it.

Where a finding matches one of those, say so and return that comment's `databaseId`, **together with the thread's resolution state**, because the two go different ways:

- **Thread still open** → the finding goes back as a reply on it, so the PR does not collect two threads and two notifications for one defect.
- **Thread resolved** → a new thread, linking the old one. Someone recorded a decision there and a reply beneath it reaches nobody who acted on that decision. A finding that survived a resolution is either `unfixed` or `re-raised`, and both are meant to be seen.

Return every finding, each with its bucket, any severity change, the prior thread URL where one applies, and — where it matched one of this skill's own threads — that comment's `databaseId` and whether the thread is resolved. The settled ones come back too, with the thread or record that decided them: they are reported as settled, not discarded.

---

## The marker-only variant

Where the run was invoked with "ignore the review history", hand over **this paragraph in place of everything above**:

> Below are findings from reviewers who read the code at HEAD, and below them, the PR's existing review threads. Do not classify or re-severity anything — every finding stands exactly as written. Your one job: some threads are this skill's own from an earlier run, ending in the marker line `<!-- pr-review-skeptic -->`. Where a finding matches one of those, return that comment's `databaseId` and whether the thread is resolved, so an open one takes the finding as a reply instead of opening a second thread beside its own original. Match on the marker rather than the author. Match a `LINE` thread on `line`, falling back to `originalLine` where `line` is null; match a `FILE` thread on `path` plus the finding's substance, because both line fields are null on those permanently and a line-based key would match no file-level thread ever. Return every finding unchanged, each with a `databaseId` and resolution state where one applies.
