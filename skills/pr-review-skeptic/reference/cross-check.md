# Cross-check brief

Runs once, after every blind reviewer has returned. This is the only point in the skill where the PR's review history is read, and the findings are already fixed in writing before it starts — so history can filter them, never form them.

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
<!-- pr-review-loop: disposition=fixed -->      the concern was accepted and a change was made
<!-- pr-review-loop: disposition=rejected -->   the concern was understood and the code kept as-is, with a rationale
<!-- pr-review-loop: disposition=deferred -->   the concern was accepted as real and tracked elsewhere, out of scope here
```

They appear as a reply on the finding's own thread. For findings the earlier run could not give a thread to, they appear instead as entries in a PR-level issue comment ending `<!-- pr-review-loop: dispositions -->`, each entry naming the path and restating the finding — match those on the finding's substance, since there is no line to match on.

Where a record matches a finding, it is the best evidence available and it decides the bucket: `rejected` and `deferred` → `settled`; `fixed` on a finding a reviewer still sees at HEAD → `unfixed`, with the severity rise, because a direct claim that this concern was fixed is exactly what that bucket is about. Take `rejected` at face value even where you find the rationale unconvincing — arguing it here would re-open a decision the author recorded publicly, which is what these records exist to stop, and the check on a bad rejection is that a blocking `settled` finding is reported in the verdict rather than hidden.

The absence of a record decides nothing. Most PRs have none at all, and a human author's reply is prose; read it as prose and bucket on its meaning, exactly as above.

## Recognising this skill's own earlier threads

Some prior threads are this skill's own, from an earlier run over the same PR: their comments end with the marker line `<!-- pr-review-skeptic -->`. Match on the marker, not on the author — these reviews are posted under the user's own account and look exactly like a hand-written one — and match on `originalLine` where `line` is null, which is every thread the last push marked outdated.

Where a finding matches one of those, say so and return that comment's `databaseId`, **together with the thread's resolution state**, because the two go different ways:

- **Thread still open** → the finding goes back as a reply on it, so the PR does not collect two threads and two notifications for one defect.
- **Thread resolved** → a new thread, linking the old one. Someone recorded a decision there and a reply beneath it reaches nobody who acted on that decision. A finding that survived a resolution is either `unfixed` or `re-raised`, and both are meant to be seen.

Return every finding, each with its bucket, any severity change, the prior thread URL where one applies, and — where it matched one of this skill's own threads — that comment's `databaseId` and whether the thread is resolved. The settled ones come back too, with the thread or record that decided them: they are reported as settled, not discarded.

---

## The marker-only variant

Where the run was invoked with "ignore the review history", hand over **this paragraph in place of everything above**:

> Below are findings from reviewers who read the code at HEAD, and below them, the PR's existing review threads. Do not classify or re-severity anything — every finding stands exactly as written. Your one job: some threads are this skill's own from an earlier run, ending in the marker line `<!-- pr-review-skeptic -->`. Where a finding matches one of those, return that comment's `databaseId` and whether the thread is resolved, so an open one takes the finding as a reply instead of opening a second thread beside its own original. Match on the marker rather than the author, and on `originalLine` where `line` is null. Return every finding unchanged, each with a `databaseId` and resolution state where one applies.
