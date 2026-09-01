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
| `lab-tofu-validate` | Check formatting and validate every OpenTofu root under a directory, no credentials needed |
| `lab-tools` | Install the fleet's k8s and registry tooling, arch-aware, onto `PATH` |
| `lab-gitops-deploy` | Build, push, pin via a kustomize commit-back, sync Argo, verify the served build |
| `lab-kubeconform` | Validate a kustomize overlay by piping its build through kubeconform |

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

## lab-tofu-validate

Checks OpenTofu formatting and validates every root under a directory, without
assuming any cloud role or reading any state. It installs OpenTofu itself, so a
caller drops its own setup step.

```yaml
- uses: willfell/lab.actions/lab-tofu-validate@v1.7.0
  with:
    working_directory: infra
```

| Input | Meaning | Default |
| --- | --- | --- |
| `working_directory` | Directory searched for OpenTofu roots | `infra` |
| `tofu_version` | OpenTofu release to install | `1.11.2` |

### Root discovery

A root is any directory whose `*.tf` files declare an anchored `backend "`
block. Discovery walks `working_directory` for that pattern rather than
requiring a caller to list roots explicitly, so `terraform-global`'s
`backend.tf` layout and `egnyte-mcp`'s `versions.tf` layout are both found the
same way. Discovering zero roots is a loud failure, not a vacuous pass -- a
directory that quietly stopped matching the pattern would otherwise let this
check pass while validating nothing.

Each discovered root is initialized with `-backend=false`, so the check needs
no cloud credentials and can gate any pull request cheaply.

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

## lab-gitops-deploy

Runs the whole build-to-served pipeline as one composite: build the image,
push it to the in-cluster registry, pin it by committing a kustomize edit
back to `main` over a deploy key, force an Argo CD sync onto that commit, and
verify the endpoint now serving traffic is running the source sha that was
just built. This canonicalizes the ~150-line version of this job that
finance, flight-checker, and wac each carried and drifted independently.

```yaml
- uses: willfell/lab.actions/lab-gitops-deploy@v1.5.0
  with:
    image: finance-app
    argo_app: finance
    namespace: finance
    deploy_ssh_key: ${{ secrets.DEPLOY_SSH_KEY }}
    sha_build_arg: FINANCE_BUILD_SHA
    build_secret: ${{ secrets.GITHUB_TOKEN }}
    health_url: http://finance-app.finance.svc.cluster.local:3000/api/health
```

| Input | Meaning | Default |
| --- | --- | --- |
| `image` | Image name, also the default deployment name | required |
| `argo_app` | Argo CD Application to sync and wait on | required |
| `namespace` | Namespace holding the deployment | required |
| `deploy_ssh_key` | Write-scoped deploy key authorizing the commit-back push | required |
| `deployment` | Deployment name when it differs from `image` | `""` |
| `dockerfile` | Dockerfile path | `deploy/Dockerfile` |
| `build_context` | Docker build context | `./` |
| `sha_build_arg` | Build-arg name that receives the source sha; empty disables | `""` |
| `build_secret` | Value exposed to the build as the `node_auth_token` docker secret; empty disables | `""` |
| `kustomize_dir` | Directory holding the kustomization the pin edits | `deploy/k8s` |
| `push_registry` | In-cluster registry address runners push to | `registry.network.svc.cluster.local:5000` |
| `pull_registry` | Registry address the node's docker daemon pulls from | `localhost:30500` |
| `health_url` | In-cluster health endpoint returning `{sha,...}`; empty skips verification | `""` |
| `health_expect_db_ok` | Also assert the health payload reports `db == ok` | `"true"` |
| `wait_timeout` | Seconds to wait on each Argo condition | `"300"` |
| `kubectl_version` / `kustomize_version` / `crane_version` | Tool releases for the deploy and pin steps | `v1.35.0` / `v5.7.1` / `v0.20.6` |

Output: `bump_sha`, the `main`-branch commit carrying the image pin.

### The registry split

`registry.network` collides with a real public TLD (`.network`), so the
node's Docker daemon resolves it as a public FQDN rather than the in-cluster
Service -- pulls were silently going out to a stranger's server while
pushes from in-cluster runners kept working, because pods resolve the name
fine through the kubelet's DNS search path and the daemon doesn't. The fix
is to stop pretending it's one address: `push_registry` is the explicit,
fully-qualified in-cluster DNS name a push can never mistake for anything
public, and `pull_registry` is `localhost:30500`, the registry Service's
NodePort as the node's daemon sees it -- Docker treats `localhost`
registries as insecure/HTTP automatically, and `localhost` can't collide
with a public domain. Same registry, same blobs, two routes into it. Do
not collapse them back into one variable; that collapse is the outage this
section is describing.

### Why crane, not `docker push`

dockerd refuses plain HTTP to any registry address it doesn't consider
`localhost`, and the push address above deliberately isn't one.
Reconfiguring ARC's injected dind sidecar to trust it would work, but it
couples this pipeline to that chart's internals for every consumer. Saving
the image and pushing the tarball with `crane push --insecure` sidesteps
dockerd's registry trust entirely.

### The deploy key

`main` is protected by a ruleset requiring a PR and a passing check. The
pin commit is `deploy: <sha> [skip ci]` by design, so it can never produce
a passing check to satisfy that rule, and GitHub Actions cannot be granted
a ruleset bypass on a user-owned repository (only an org-owned one). The
push is therefore made with a write-scoped deploy key, and the ruleset
grants that key's `DeployKey` principal the bypass instead. Deploy keys
are SSH-only, which is why this step rewrites the push remote to
`git@github.com` rather than reusing the checkout's HTTPS token.

### `[skip ci]`, not paths-ignore

`[skip ci]` stops the pin commit from retriggering this workflow. A
`paths-ignore` filter on the kustomize directory would do the same thing
for this commit, but it would also suppress the workflow for a hand-edited
manifest in that directory -- and a hand edit is exactly the kind of change
that SHOULD deploy. Argo watches git directly, not this workflow, so
either way the sync happens; only the `[skip ci]` approach keeps Actions
correctly silent on its own commit while staying alert to everyone else's.

### What the verify step checks

The final step asserts that the endpoint is serving the *source* sha --
the commit this job built from -- never the bump commit that carries the
pin. Checking the bump sha instead would make the assertion vacuous: it's
always true the moment the pin lands, whether or not the workload actually
picked it up. Re-running this composite against an already-current sha is
a no-op at the pin step (nothing to commit) and falls straight through to
this same verification, rather than treating "nothing changed" as a
failure.

### The onboarded guard

A repo whose Argo Application doesn't exist yet -- newly composited but
not yet wired into Argo CD -- stops cleanly after the image push instead
of failing the job. Every sync, wait, rollout, and verify step is
conditioned on that onboarded check, so bringing a new consumer onto this
composite doesn't require Argo to be ready on day one.

### The pin retry loop

Each of the five pin attempts re-derives from `origin/main`: fetch, branch
from the fresh tip, edit, commit, push. A concurrent pin from another job
landing between attempts is not a conflict to rebase through -- the next
attempt just starts over from wherever `main` now points, so it can never
push a commit based on a base that's gone stale underneath it.

## lab-kubeconform

Pipes a kustomize overlay's rendered manifests through kubeconform.
Replaces three hand-rolled versions of this same two-command pipeline that
had drifted onto different tool versions and, on the arm64 consumers, hard-
coded release-asset URLs for that one architecture.

```yaml
- uses: willfell/lab.actions/lab-kubeconform@v1.5.0
  with:
    kustomize_dir: deploy/k8s
```

| Input | Meaning | Default |
| --- | --- | --- |
| `kustomize_dir` | Directory holding the kustomization to validate | required |
| `flags` | Flags passed to kubeconform | `-strict -summary` |
| `kustomize_version` | kustomize release to install | `v5.7.1` |
| `kubeconform_version` | kubeconform release to install | `v0.7.0` |

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

### nextjs-site-deploy

Builds a static-exported Next.js site and ships it: install, restore cached
optimized images from S3, validate and re-optimize images, build, run an
optional postbuild step, verify the `out` export exists, sync images with an
immutable cache header, sync the rest of the app files, and invalidate
CloudFront. Canonicalizes the deploy.yml the site fleet's repos had copy-pasted
and drifted -- one step and one invalidation path apart.

```yaml
jobs:
  deploy:
    uses: willfell/lab.actions/.github/workflows/nextjs-site-deploy.yml@v1.6.0
    permissions:
      id-token: write
      contents: read
    with:
      role_arn: arn:aws:iam::111111111111:role/site-deploy
      aws_region: us-east-1
    secrets:
      s3_bucket: ${{ secrets.S3_BUCKET_NAME }}
      cloudfront_distribution_id: ${{ secrets.CLOUDFRONT_DISTRIBUTION_ID }}
```

| Input | Meaning | Default |
| --- | --- | --- |
| `app_dir` | Directory holding the Next.js app | `app` |
| `node_version` | Node release installed before `yarn install` | `22` |
| `role_arn` | OIDC role assumed for the AWS credentials used to deploy | required |
| `aws_region` | AWS region passed to `configure-aws-credentials` | required |
| `postbuild_command` | Shell command run after `yarn build`, skipped when empty | `""` |
| `build_env` | Newline-separated `KEY=value` pairs exported into the build step | `""` |
| `invalidation_paths` | Space-separated CloudFront invalidation path patterns | `/*.html /index.html /_next/* /sitemap*.xml` |

| Secret | Meaning |
| --- | --- |
| `s3_bucket` | S3 bucket the export is synced to |
| `cloudfront_distribution_id` | CloudFront distribution invalidated after sync |

`node_version` defaults to `22`, retiring the fleet's node-18 debt; a caller
whose build breaks on 22 can override it to `"20"` and then `"18"` while it
migrates, rather than being blocked on the bump.

`postbuild_command` is a command by contract, the same as any `run:` step --
it is deliberately interpolated into a shell step, not passed through `env:`.
Every other input above is data and rides `env:` inside the workflow; treat
`postbuild_command` as untrusted-caller-writable code, not as a data value.

### nextjs-site-check

Runs the same install, image validation, and build a pull request needs to
prove a Next.js site still builds, without any of the deploy steps.

```yaml
jobs:
  check:
    uses: willfell/lab.actions/.github/workflows/nextjs-site-check.yml@v1.6.0
```

| Input | Meaning | Default |
| --- | --- | --- |
| `app_dir` | Directory holding the Next.js app | `app` |
| `node_version` | Node release installed before `yarn install` | `22` |

`node_version` defaults to `22` with the same fallback ladder (`20`, then
`18`) as `nextjs-site-deploy` -- a caller's green check on the default is the
acceptance test for the node-22 bump.
