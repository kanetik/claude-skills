# Cross-check brief

Runs once, after every blind reviewer has returned. This is the only point in the skill where the PR's review history is read, and the findings are already fixed in writing before it starts — so history can filter them, never form them.

Hand this to one subagent, with the merged findings and the PR's prior review history (threads with their replies and resolution state, review bodies, and the PR description).

Skip this stage when the PR has no prior review activity; every finding is new by definition.

---

## The brief

Below are findings from reviewers who read the code at HEAD without seeing this PR's history, and below them, that history.

Every finding describes the code **as it stands now** — a reviewer read it and saw the defect at HEAD. History tells you what has already been discussed, not what is still true.

Classify each finding into exactly one bucket.

**`new`** — no prior thread raised it. Most findings land here. Pass through unchanged.

**`unfixed`** — a prior thread raised this same defect and a change was made in response, yet a reviewer reading HEAD still finds it. The earlier fix did not land, or landed partially. **Raise severity one rung** and note how many rounds have touched it. Code that has been fixed twice and is still wrong is the strongest signal this review produces: every reader who looked at it concluded it was handled.

**`re-raised`** — a prior thread raised this concern and it was dismissed, argued down, or closed without a change, and a reviewer who never saw that exchange landed on it independently. **Keep at its stated severity and mark it re-raised**, naming the prior thread. An independent reviewer arriving at a concern someone talked their way out of is worth more than either verdict alone.

**`settled`** — a prior thread weighed this same consequence and the project chose otherwise, and the finding names no consequence that choice failed to account for. This is a decision, not a defect. **Move it out of the findings and into the settled list**, with the thread it was decided in.

The discriminator between `settled` and `re-raised` is the consequence, not the topic. Two findings can name the same file and line and land in different buckets: if the prior thread weighed the same outcome and accepted it, the matter is settled; if the finding names an outcome that exchange never considered, it stands.

Return every finding, each with its bucket, any severity change, and the prior thread URL where one applies. The settled ones come back too — they are reported to the user as settled, not discarded.
