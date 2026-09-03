# Consumers

Every repo pinning this library, by action/workflow and file. Bumping a tag means
walking this table and opening one PR per repo whose pinned components changed.

| Component | Repo | File | Pin |
|---|---|---|---|
| lab-build | egnyte-mcp | .github/workflows/ci.yml | v1.3.0 |
| lab-deploy | egnyte-mcp | .github/workflows/promote.yml | v1.3.0 |
| lab-tofu-plan | lab | .github/workflows/tofu-plan.yml | v1.3.0 |
| lab-tofu-plan | lab | .github/workflows/tofu-drift.yml | v1.3.0 |
| lab-tofu-apply | lab | .github/workflows/tofu-apply.yml | v1.3.0 |
| lab-tofu-plan | terraform-global | .github/workflows/tofu-plan.yml | v1.3.0 |
| lab-tofu-apply | terraform-global | .github/workflows/tofu-apply.yml | v1.3.0 |
| lab-gitops-deploy | finance | .github/workflows/ci.yml | v1.9.4 |
| lab-kubeconform | finance | .github/workflows/ci.yml | v1.9.4 |
| lab-gitops-deploy | flight-checker | .github/workflows/ci.yml | v1.9.4 |
| lab-kubeconform | flight-checker | .github/workflows/ci.yml | v1.9.4 |
| lab-gitops-deploy | wac | .github/workflows/ci.yml | v1.9.4 |
| lab-kubeconform | wac | .github/workflows/ci.yml | v1.9.4 |
| lab-tools | wac.vaults | .github/workflows/ci.yml | v1.5.0 |
| actionlint | wac.vaults | .github/workflows/ci.yml | v1.5.0 |
| actionlint | finance | .github/workflows/ci.yml | v1.9.4 |
| actionlint | flight-checker | .github/workflows/ci.yml | v1.9.4 |
| actionlint | wac | .github/workflows/ci.yml | v1.9.4 |
| lab-gitops-deploy | travel | .github/workflows/ci.yml | v1.9.4 |
| lab-kubeconform | travel | .github/workflows/ci.yml | v1.9.4 |
| actionlint | travel | .github/workflows/ci.yml | v1.9.4 |
| nextjs-site-deploy | fellhoelter-consulting | .github/workflows/deploy.yml | v1.6.0 |
| nextjs-site-check | fellhoelter-consulting | .github/workflows/pr.yml | v1.6.0 |
| nextjs-site-deploy | will-fell | .github/workflows/deploy.yml | v1.6.0 |
| nextjs-site-check | will-fell | .github/workflows/pr.yml | v1.6.0 |

Release notes must state which components changed in a tag, so a consumer whose
components are untouched knows their bump is byte-identical.
