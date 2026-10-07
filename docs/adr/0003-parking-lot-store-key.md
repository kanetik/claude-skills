# 0003 — The parking-lot store is keyed on the main repository root, with no fallback

Date: 2026-10-07. Status: accepted.

## Context

A repository-scoped store lives at `<claude-config>/projects/<mangled-path>/parking-lot.md`, beside the project's own `memory/` directory. Which path gets mangled decides which file a thought lands in, and two spellings of one repository are two stores. That failure is silent: the thought is written, `list` from anywhere else says nothing is parked, and nothing errors.

Without `--path-format=absolute`, `git rev-parse --git-common-dir` answers with a bare `.git` in the main checkout, an absolute path from a linked worktree, and `../../.git` from a subdirectory. Resolving the relative forms against `$PWD` gives a different string every time the working directory moves, and on Windows a different flavour of path (`/c/Users/...` against `C:/Users/...`).

Keying on a linked worktree's own path instead would tie parked thoughts to a directory that is deleted when its branch lands — losing them at the moment the work they were parked behind finishes.

## Decision

- **Key on the main repository root** from `git rev-parse --path-format=absolute --git-common-dir`, so every worktree and subdirectory of a repository shares one store.
- **Require git 2.31 or newer, with no fallback.** On older git a repository-scoped `add` is refused with a message naming the version. `--user` still works, without its `(from <repo>)` tag, and `show` still exits 0. A refusal is recoverable; a fragmented store is not.
- **Handled items stay in the file**, marked `[x]`, so "did I already think of this?" stays answerable. They stop appearing in `list` and the digest.

## Consequences

- Users on git older than 2.31 get only the user store until they upgrade.
- A store from when the skill was called `later` (`later.md`) is renamed on first reach. One found beside an existing `parking-lot.md` is left alone and named by `list` and the digest until its items are moved across by hand.
