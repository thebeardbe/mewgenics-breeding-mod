# Publishing the Mewjector issue and pull request

One script that forks `githubuser508/mewjector`, pushes one commit, opens the
issue, and opens the pull request. It is idempotent: re-running reuses an
existing fork, branch, issue or PR instead of duplicating.

The payloads next to this file are the exact texts:

- `commit_msg.txt` - the commit message
- `issue_body.md` - the issue body
- `pr_body.md` - the pull request body (`Refs #N` is appended automatically)

## Token

A **classic** personal access token with only the **`public_repo`** scope.
Fine-grained tokens cannot reliably fork a repository you do not own or open an
issue/PR on an upstream repo, and they fail with
`Resource not accessible by personal access token`. See
`docs/PR-mewjector.md` for the click-by-click token steps.

Revoke the token after the run; it is used for four API calls.

## Run

```bash
# 1. dry run: checks the token and whether the fork exists, publishes nothing
GITHUB_TOKEN=<token> nix shell nixpkgs#git nixpkgs#python3 --command \
  python3 tools/publish/publish_pr.py --dry-run

# 2. publish
GITHUB_TOKEN=<token> nix shell nixpkgs#git nixpkgs#python3 --command \
  python3 tools/publish/publish_pr.py
```

The script prints the fork, branch, issue and PR URLs at the end.

## Safety

- The token is read from `GITHUB_TOKEN`, injected into git through config
  environment variables (never argv, never written to disk), and is not printed.
- It only ever touches `githubuser508/mewjector`, your fork of it, and one
  branch. No force pushes, no history rewrites.
- Nothing is published until step 2; step 1 is read-only.

## If you would rather not run a script

`docs/PR-mewjector.md` has the same steps by hand: fork, clone, `git apply`,
the commit message, `build.bat`, push, and the PR title and body.
