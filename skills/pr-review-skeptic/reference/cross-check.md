# Cross-check brief

Runs once, after every blind reviewer has returned. This is the only point in the skill where the PR's review history is read, and the findings are already fixed in writing before it starts — so history can filter them, never form them.

Hand this to one subagent, with the merged findings and the PR's prior review history: threads with their replies, resolution state, and `isOutdated` flag; review bodies; the PR description; and the commit list ([`mechanics.md`](mechanics.md)). The commits and `isOutdated` are what let it tell a concern that was *changed* in response from one that was only argued about — without them the `unfixed` / `re-raised` split is a guess, and a wrong guess raises a severity and posts a blocking comment.

Skip this stage when the PR has no prior review activity; every finding is new by definition.

---

## The brief

Below are findings from reviewers who read the code at HEAD without seeing this PR's history, and below them, that history.

Every finding describes the code **as it stands now** — a reviewer read it and saw the defect at HEAD. History tells you what has already been discussed, not what is still true.

Classify each finding into exactly one bucket.

**`new`** — no prior thread raised it. Most findings land here. Pass through unchanged.

**`unfixed`** — a prior thread raised this same defect and a change was made in response, yet a reviewer reading HEAD still finds it. The earlier fix did not land, or landed partially. "A change was made in response" needs evidence that ties a commit to *this concern*: a commit postdating the thread whose diff touches that thread's path at or around its line. `isOutdated` on its own does not carry it — a rebase or a formatting pass flags every thread in the PR outdated at once, and treating that as a fix would escalate every re-found finding in one go. Where only `isOutdated` holds, or nothing does, the finding belongs in one of the two buckets below at its stated severity. **Raise severity one rung**, `CRITICAL` being the ceiling — an unfixed `CRITICAL` stays `CRITICAL` and is marked unfixed, since a rung invented above it matches no entry in `blocking_severities` and would drop the most serious finding the skill can produce out of the inline comments entirely. Note how many rounds have touched it. Code that has been fixed twice and is still wrong is the strongest signal this review produces: every reader who looked at it concluded it was handled.

**`re-raised`** — a prior thread raised this concern and it was dismissed, argued down, or closed without a change, and a reviewer who never saw that exchange landed on it independently. **Keep at its stated severity and mark it re-raised**, naming the prior thread. An independent reviewer arriving at a concern someone talked their way out of is worth more than either verdict alone.

**`settled`** — a prior thread weighed this same consequence and the project chose otherwise, and the finding names no consequence that choice failed to account for. This is a decision, not a defect. **Move it out of the findings and into the settled list**, with the thread it was decided in.

The discriminator between `settled` and `re-raised` is the consequence, not the topic. Two findings can name the same file and line and land in different buckets: if the prior thread weighed the same outcome and accepted it, the matter is settled; if the finding names an outcome that exchange never considered, it stands.

Some prior threads are this skill's own, from an earlier run over the same PR: their comments end with the marker line `<!-- pr-review-skeptic -->`. Where a finding matches one of those and the thread is still open, say so and return that comment's `databaseId` — the finding is a reply on the existing thread rather than a new comment, so the PR does not collect two threads and two notifications for one unfixed defect. Match on the marker, not on the author: these reviews are posted under the user's own account and look exactly like a hand-written one.

Return every finding, each with its bucket, any severity change, and the prior thread URL where one applies. The settled ones come back too — they are reported to the user as settled, not discarded.
