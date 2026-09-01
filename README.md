# lab.actions

Composite GitHub Actions shared across the homelab's projects.

Public on purpose: composite actions are YAML wrappers and every credential is
passed in as an input, so there is nothing secret here — and a public repo
avoids the private-repo Access setting that otherwise has to be right in every
consuming repository.

| Action | Purpose |
| --- | --- |
| `lab-build` | Compute semver, build, push an immutable tag, move a mutable environment pointer, cut a release |
| `lab-deploy` | Point an Argo CD Application at a new release and wait for it to converge |
| `lab-tofu-plan` | Plan an OpenTofu stack on a pull request, guard it, and comment the result |
| `lab-tofu-apply` | Guard and apply the reviewed plan file on merge |
| `lab-tools` | Install the fleet's k8s and registry tooling, arch-aware, onto `PATH` |

Consume at an **exact patch-level tag** — never at `main`, and never at a floating
major:

```yaml
- uses: willfell/lab.actions/lab-build@v1.2.0
```

`@main` lets an unrelated push here change how a consuming repo builds and deploys.
A floating `@v1` is the same hole with a slower fuse: it moves without review, and
this repo's `v1` already went stale carrying a bootstrap that shells out to `gh`,
which is absent from the self-hosted runner image. Repointing a major tag depends on
a human remembering to, which is not a guarantee.

The cost of exact pins is that bumping a consumer is a deliberate edit. That is the
point: an unreviewed change to a composite cannot reach anyone's CI, and cannot
silently fail to reach it either.

All actions share one tag. A release touching only `lab-deploy` still moves
`lab-build`'s pin to the same ref, pointing at byte-identical code. Reusable
workflows (below) ride the same repo-wide exact tags.

`CONSUMERS.md` tracks every pinned component, repo, and file. Bumping a tag means
walking that table and opening one PR per affected consumer.

## Releasing

Tags are created by hand. Nothing computes them, and merging a PR publishes nothing.

```sh
git tag vX.Y.Z && git push origin vX.Y.Z
```

Until the tag exists, a consumer pinned to it fails at job start-up with "unable to
resolve action" — before running a single step.

## The OpenTofu actions

`lab-tofu-plan` and `lab-tofu-apply` are one pipeline split across two triggers.
Plan runs on the pull request and comments what would change; apply runs on the
merge and applies **the plan file it just wrote**, not a fresh one. That
distinction is the whole reason the pair exists: `tofu apply -auto-approve`
re-plans at apply time, so a drift or a racing change lands without anyone having
reviewed it.

```yaml
- uses: willfell/lab.actions/lab-tofu-plan@v1.3.0
  with:
    working_directory: infra/cloudflare
    role_arn: arn:aws:iam::634560051830:role/lab-cloudflare-plan
    github_token: ${{ secrets.GITHUB_TOKEN }}
```

### Guards stay in the calling repo

Neither action ships a policy check. They take a `guard_command` instead, run
from the repository root with two variables set:

| Variable | Meaning |
| --- | --- |
| `TOFU_PLAN_JSON` | Path to the rendered plan JSON |
| `GUARD_OVERRIDE` | Non-empty when `override_label` was on the pull request |

```yaml
    guard_command: uv run lab tf guard --plan "$TOFU_PLAN_JSON" ${GUARD_OVERRIDE:+--allow-destroy}
    override_label: allow-access-destroy
```

This repo has no test suite by design, and a guard is the one piece of the
pipeline whose failure mode is an outage rather than a red check. Moving it here
would trade a tested function for an unverified shell fragment. So the guard
lives in the consumer, under that repo's own linters and tests, and these actions
only decide *when* to call it and *whether* an override applies.

`override_label` is resolved through the API on both sides -- from the pull
request on plan, from the merge commit's pull request on apply. Reading it from
the push event instead would mean a guard that a reviewer had to override could
be bypassed simply by merging.

A failing guard on plan still posts its comment before failing the job. On apply
there is nothing to read, so it fails immediately.

### Requirements of the calling job

```yaml
permissions:
  id-token: write
  contents: read
  pull-requests: write
```

Check out the repository and install whatever `guard_command` needs before
calling either action; neither does its own checkout or language setup. The
override-label step shells out to `gh`, which is present on GitHub-hosted runners
but not on this homelab's self-hosted image -- omit `override_label` there.

## lab-tools

Installs the fleet's k8s and registry tooling -- `kubectl`, `kustomize`, `crane`,
`kubeconform`, `helm` -- to `$RUNNER_TEMP/bin` and appends it to `GITHUB_PATH`, so
every subsequent step in the job finds them on `PATH`. It maps `uname -m` to each
tool's release-asset arch naming, so the same call works unmodified on
GitHub-hosted amd64 runners and this homelab's arm64 self-hosted runners.

```yaml
- uses: willfell/lab.actions/lab-tools@v1.4.0
  with:
    tools: kubectl,kustomize,crane,kubeconform
```

| Input | Meaning | Default |
| --- | --- | --- |
| `tools` | Comma-separated subset of `kubectl,kustomize,crane,kubeconform,helm` | required |
| `kubectl_version` | kubectl release installed when `kubectl` is requested | `v1.35.0` |
| `kustomize_version` | kustomize release installed when `kustomize` is requested | `v5.7.1` |
| `crane_version` | go-containerregistry release installed when `crane` is requested | `v0.20.6` |
| `kubeconform_version` | kubeconform release installed when `kubeconform` is requested | `v0.7.0` |
| `helm_version` | helm release installed when `helm` is requested; empty installs the latest | `""` |

This repo's CI runs the smoke matrix on `ubuntu-latest` (amd64) and
`ubuntu-24.04-arm` (arm64) on every push and pull request, installing all five
tools and executing each one, so the arch mapping above is enforced by a real
job rather than trusted.

## Reusable workflows

Reusable workflows ride the same repo-wide exact tags as the composites above --
consume at an exact patch-level tag, never `@main` or a floating major.

### actionlint

Runs [`raven-actions/actionlint`](https://github.com/raven-actions/actionlint)
against the caller's own workflows. No inputs.

```yaml
jobs:
  lint:
    uses: willfell/lab.actions/.github/workflows/actionlint.yml@v1.4.0
    permissions:
      contents: read
```
