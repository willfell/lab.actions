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
`lab-build`'s pin to the same ref, pointing at byte-identical code.

## Releasing

Tags are created by hand. Nothing computes them, and merging a PR publishes nothing.

```sh
git tag vX.Y.Z && git push origin vX.Y.Z
```

Until the tag exists, a consumer pinned to it fails at job start-up with "unable to
resolve action" — before running a single step.
