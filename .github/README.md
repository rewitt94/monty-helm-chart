# GitHub automation

These workflows follow `pydantic/logfire-helm-chart`: **Test Chart**, **Release Charts**, and a PR
template with **Summary** and **Upgrade notes** sections used in release notes. Actions are pinned
by commit, and Helm is pinned to the same version as Logfire.

## Chart testing

`workflows/pr.yaml` runs `bash check.sh` and release-note tests on pull requests and pushes to `main`.
It can also be run manually. Render tests require no credentials or cluster. Monty uses its existing
render checks rather than Logfire's `helm-unittest` and chart-testing configuration; its chart lives
at `charts/monty` and has no Helm dependencies.

The optional integration job creates a kind cluster, installs the development overlay, checks
`/health` and execution through `/run`, upgrades the Deployments, and repeats the checks. It does not
test remote object storage, session resumption, ingress, or NetworkPolicy enforcement.

To enable it:

1. Pin a published application version in `charts/monty/Chart.yaml` (`appVersion`).
2. Configure the repository secrets `WORKLOAD_IDENTITY_PROVIDER` and `SERVICE_ACCOUNT`, as in Logfire.
   The Google service account needs Artifact Registry **read** access to the Monty images, not publish
   permissions. Restrict the OIDC trust to this repository's `main` branch.
3. Set the repository variable `ENABLE_INTEGRATION_TESTS` to `true`.

Private-image tests run only on `main`, never on pull requests. No long-lived registry key is needed.
Logfire-specific database, identity-provider, and API integration tests are not copied into this chart.

## Releases

Publishing is currently deferred: the chart-releaser and dependent release-note/Pages steps are
literally commented out in `workflows/release.yml`. The workflow runs validation on pushes to `main`
and `monty-*` tags, but publishes nothing. Install from this repository for now.

To enable publishing in a follow-up, uncomment the marked block. Before publishing:

- Set `appVersion` to the application version being shipped and bump the chart's `version`.
- Complete the PR's **Summary** and **Upgrade notes** sections for users.
- Allow GitHub Actions to write repository contents. The workflow uses `GITHUB_TOKEN` for releases
  and `gh-pages`, with read access to pull requests for release notes.
- Create the `gh-pages` branch and enable GitHub Pages for that branch, at its root.

A tag-triggered run requires the tag to match `monty-<Chart.yaml version>`. The commented publication
block validates `appVersion` before releasing. Chart-releaser uses `skip_existing` to preserve existing
releases.

Like Logfire, releases use Helm chart-releaser, mark SemVer prereleases as prereleases rather than
latest, merge PR release-note sections into the GitHub Release, and update `gh-pages/chart/README.md`
only for stable releases. The chart-releaser action discovers `charts/monty` and publishes the index
to `gh-pages/index.yaml`, matching Logfire's `charts/` layout.

GitHub Pages/custom-domain setup and registration with any shared Pydantic chart repository remain
repository/infrastructure configuration; this workflow does not provision them. Release publishing
runs render validation but does not wait for the optional private-image integration job.
