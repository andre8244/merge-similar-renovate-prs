# merge-similar-renovate-prs

Merge the same Renovate pull request across many repositories of the
[NethServer](https://github.com/NethServer) and [nethesis](https://github.com/nethesis)
GitHub organizations in one go.

Renovate opens identically titled dependency-bump pull requests (for example
`Update dependency sass to v1.104.0`) in a lot of repositories. This script
finds all of them, shows their CI check status, and squash-merges the ones that
are ready, after a single confirmation.

## Requirements

- [`gh`](https://cli.github.com) (GitHub CLI), authenticated with `gh auth login`
  and a token that can merge pull requests (`repo` scope)
- [`jq`](https://jqlang.github.io/jq/)
- `bash` 4.x or newer

## Usage

```
./merge-similar-renovate-prs.sh [options] "<pr title>"
```

| Option | Description |
| --- | --- |
| `-l, --limit N` | maximum number of search results to fetch (default: 100) |
| `-y, --yes` | do not ask for confirmation before merging |
| `-n, --dry-run` | only list the pull requests, never merge |
| `-h, --help` | show the help text |

The title must match the pull request title **exactly** (case-insensitive);
`gh search prs` is fuzzy, so results are filtered afterwards. Passing a partial
title such as `update dependency` returns nothing.

Characters that GitHub's search syntax rejects (`:`, `(`, `)`, `[`, `]`, `{`,
`}`, `<`, `>`, `"`, `/`, `\`, `,`) are replaced by spaces in the search query,
so Conventional Commits titles work as-is:

```
./merge-similar-renovate-prs.sh "chore(deps): update dependency sass to v1.104.0"
```

The exact-title filter still runs on the full title you typed, so the dropped
characters do not widen what gets merged.

## Example

```console
$ ./merge-similar-renovate-prs.sh "Update dependency sass to v1.104.0"
Searching for pull requests titled: Update dependency sass to v1.104.0
Organizations: NethServer nethesis

Fetching check status for 3 open pull request(s)...

Open pull requests
  [ 1] + PASSING    NethServer/ns8-lamp#138            https://github.com/NethServer/ns8-lamp/pull/138
  [ 2] x FAILING    NethServer/ns8-n8n#40              https://github.com/NethServer/ns8-n8n/pull/40
  [ 3] + PASSING    NethServer/ns8-rustfs#82           https://github.com/NethServer/ns8-rustfs/pull/82

Closed / merged pull requests (not merged by this script)
  merged       NethServer/ns8-lamp#136            https://github.com/NethServer/ns8-lamp/pull/136

Summary: 4 matching pull request(s) - 3 open, 1 closed/merged
         2 ready to merge, 1 open skipped (draft, conflicting, or checks not passing)

Merge the 2 pull request(s) marked PASSING with --squash? [yes/N] yes

  Merging https://github.com/NethServer/ns8-lamp/pull/138      ... done
  Merging https://github.com/NethServer/ns8-rustfs/pull/82     ... done

Merged 2 / 2, failed 0
```

## What gets merged

Only open pull requests that are **not** drafts, have **no** conflicts, and
whose checks are all passing. They are merged with
`gh pr merge --squash --delete-branch`.

Everything else is listed for information but never merged:

| Status | Meaning |
| --- | --- |
| `+ PASSING` | all checks passed - will be merged |
| `~ PENDING` | at least one check is still running |
| `x FAILING` | at least one check failed |
| `? NO CHECKS` | the pull request reports no checks |
| `! CONFLICT` | the branch conflicts with its base |
| `* DRAFT` | the pull request is a draft |

Auto-merge (`--auto`) and administrator overrides (`--admin`) are never used:
if a pull request is not mergeable right now, the script leaves it alone.

The exit code is `1` if any merge failed, `0` otherwise.
