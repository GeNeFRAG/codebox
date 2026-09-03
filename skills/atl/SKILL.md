---
name: atl
description: Read and write Jira issues, Confluence pages, and Zephyr Scale test cases/runs/results via the `atl` CLI, already installed and authenticated in this container. Use whenever the user mentions Jira, a ticket/issue key (e.g. MERCURY-123), a sprint, a board, JQL, Confluence, a wiki page, or Zephyr test cases, test runs, test results, or coverage.
compatibility: Requires the `atl` binary on PATH and JIRA_*/CONFLUENCE_* credentials in the environment. Both are baked into the CodeBox image.
---

# atl — Atlassian from the command line

`atl` is a single Go binary built for agent consumption: every command emits a
JSON envelope on stdout. Prefer it over `curl` against the Atlassian REST APIs —
it already holds the credentials, retries on 429/503, and returns
`next_actions` hints that suggest the follow-up command.

## Discover commands from the binary, not from this file

This skill deliberately does not list subcommands or flags; they would go stale.
Ask the binary:

```bash
atl --help                       # top level: jira, confluence, zephyr, schema, api, pipe
atl jira --help                  # board, field, issue, project, sprint, user
atl jira issue --help            # get, search, create, update, transition, comment, ...
atl schema jira-issue            # field definitions and enums for a resource
```

## Conventions that are not obvious from --help

**Always narrow the output.** A bare `atl jira issue get KEY-1` returns every
field on the issue and will consume thousands of tokens. Pass `--fields` with
just what you need, or `--compact` for keys/IDs only:

```bash
atl jira issue search --jql 'project = MERCURY AND status = Open ORDER BY updated DESC' \
  --limit 10 --fields key,summary,status.name,assignee.displayName
```

`--limit` defaults to 50 — lower it when exploring.

**Batch with `atl pipe`, not a loop.** For more than two or three calls, feed
one JSON object per line and reuse the single TLS session:

```bash
printf '%s\n' \
  '{"argv":["jira","issue","get","MERCURY-1","--fields","key,status.name"]}' \
  '{"argv":["jira","issue","get","MERCURY-2","--fields","key,status.name"]}' \
  | atl pipe
```

Each output envelope carries a 0-indexed `seq` matching its input line.

**Check the envelope, not the exit code.** Responses look like
`{"ok":true,"command":"...","result":{...}}`. On failure `ok` is `false` and the
error is in the envelope.

**`atl api` is the escape hatch.** If no subcommand covers what you need, make a
raw authenticated API call rather than rebuilding auth with `curl`.

## Before writing

Creating issues, transitioning tickets, posting comments, and editing Confluence
pages all affect a shared production instance. Confirm the target with the user
first, then verify with a read-back afterwards.

If a command reports an auth failure, run `atl auth status` to see which of
Jira / Confluence / Zephyr is connected.
