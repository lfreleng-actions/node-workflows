<!--
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
-->

# 🛠️ Node.js Reusable Workflows

<!-- prettier-ignore-start -->
<!-- markdownlint-disable-next-line MD013 -->
[![Linux Foundation](https://img.shields.io/badge/Linux-Foundation-blue)](https://linuxfoundation.org/) [![Source Code](https://img.shields.io/badge/GitHub-100000?logo=github&logoColor=white&color=blue)](https://github.com/lfreleng-actions/node-workflows) [![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
<!-- prettier-ignore-end -->

Reusable GitHub workflows that build, test, audit and release Node.js
projects for the Linux Foundation. The workflows support both
GitHub-native projects and projects where Gerrit serves as the source
of truth (dispatched through gerrit_to_platform).

## Workflow Inventory

<!-- markdownlint-disable MD013 -->

| Workflow                                    | Trigger context           | Purpose                                                                                           |
| ------------------------------------------- | ------------------------- | ------------------------------------------------------------------------------------------------- |
| `.github/workflows/build-test.yaml`         | Pull request / verify     | Build, test, dependency audit, SBOM generation and Grype scan                                     |
| `.github/workflows/build-test-release.yaml` | Tag push (Model A)        | Everything above, plus GitHub release with signed/attested npm tarball and optional Nexus publish |
| `.github/workflows/merge.yaml`              | Merge to branch (Model B) | Snapshot publish on every merge; release publish when a release file merges                       |

<!-- markdownlint-enable MD013 -->

Thin caller examples for each workflow live under `examples/`, with a
GitHub-native and a Gerrit-wrapped variant per workflow.

## Job Graphs

`build-test.yaml` (`->` denotes sequence; `{ }` runs in parallel):

```text
gerrit-validate -> { repository-metadata | node-metadata }
node-metadata -> build -> { tests | audit | sbom -> grype }
```

`build-test-release.yaml` (gating inversion: the audits gate the
expensive test suite on releases):

```text
gerrit-validate -> { repository-metadata | node-metadata | tag-validate }
{ tag-validate | node-metadata } -> build -> { audit | sbom -> grype }
  -> tests -> attach-artefacts -> promote-release -> nexus-publish
build -> sign-artefacts -> attach-artefacts
```

`merge.yaml`:

```text
gerrit-validate -> { repository-metadata | node-metadata
                     | resolve-version | check-release }
node-metadata -> build
{ resolve-version | build } -> snapshot-publish
{ check-release | resolve-version | build } -> release-publish
```

## Release Models

### Model A: tag-driven (`build-test-release.yaml`)

A signed semver tag drives the release. The workflow validates the
tag (semver shape, signature, GitHub presence), builds the project,
stamps `package.json` with the tag version, packs the npm tarball,
then attests and signs it:

- SLSA build provenance via `actions/attest`
  (toggle with the `attestations` input)
- Sigstore keyless signature bundle via `cosign sign-blob`
  (toggle with the `sigstore_sign` input)

The tarball, Sigstore bundle and SBOM files attach to a draft GitHub
release, which the workflow then promotes. With `nexus_publish: true`
the workflow also publishes the package to the Nexus npm registry
named in `registry_url`, using the credential contract below.

### Model B: merge-driven (`merge.yaml`)

The Jenkins-heritage LF/Gerrit flow, as used across ONAP and similar
projects. Every merge publishes a snapshot: the `build-metadata-action`
parses `version.properties` (`major=`/`minor=`/`patch=` keys, a
combined `release_version=X.Y.Z` key, or a `version=X.Y.Z` key,
skipping Jenkins-era `${...}` interpolated values) and the
workflow publishes `X.Y.Z-SNAPSHOT` to `snapshot_registry_url`. When
the merged commit adds a file under `releases/` whose `version:`
matches `version.properties`, the workflow also publishes the plain
`X.Y.Z` release to `release_registry_url`. A version mismatch between
the release file and `version.properties` fails the release publish.

Release publishes also gain attestation and a signature. The build job
uploads the built tree rather than a tarball, and the publish step
stamps the version, so a `pack-release` job re-stamps that tree to the
resolved release version and packs it, then:

- SLSA build provenance via `actions/attest`
  (toggle with the `attestations` input)
- Sigstore keyless signature bundle via `cosign sign-blob`
  (toggle with the `sigstore_sign` input)

The release publish waits for both. An enabled record that fails blocks
the publish rather than trailing it, because hosted npm repositories are
typically write-once: nothing can add provenance to a version that
already published without it, whereas a blocked publish is retryable.
Disabling either toggle skips that job and lets the publish proceed.

Snapshot publishes stay unattested and unsigned by design, since every
merge replaces them.

The calling job must grant `id-token: write` and `attestations: write`.
A caller's `permissions` block caps what the reusable workflow's jobs
can request, so a caller that grants `contents: read` alone leaves the
`attest` and `sign-artefacts` jobs unable to run. Set `attestations`
and `sigstore_sign` to `false` if you would rather not grant them.

Note the scope of what these cover. The tarball comes from a separate
`npm pack`, not the one `npm publish` performs internally, so the
provenance and signature attest to the artefact this workflow built
rather than the exact bytes the registry received. The `pack-release`
job mirrors the publish path's stamping, including running `version`
lifecycle hooks, so the content set still matches where a project's
hooks change files. Nexus npm repositories offer no registry-native
provenance, which is why the artefact-level records exist at all;
publishing to a registry that does support it (such as npmjs.org under
trusted publishing) yields registry-native provenance too.

## Inputs and Secrets

### build-test.yaml

<!-- markdownlint-disable MD013 -->

| Input                     | Type    | Default    | Description                                                       |
| ------------------------- | ------- | ---------- | ----------------------------------------------------------------- |
| `repository`              | string  | `''`       | Repository to check out (owner/name); empty uses the caller       |
| `ref`                     | string  | `''`       | Checkout ref (empty = event ref; other repos: default branch)     |
| `path_prefix`             | string  | `'.'`      | Path to the project root directory                                |
| `node_version`            | string  | `''`       | Node.js version; empty auto-detects `engines.node`, then 22       |
| `build_tool`              | string  | `''`       | `npm` or `yarn`; empty auto-detects from project metadata         |
| `build_scripts`           | string  | `'build'`  | package.json script(s) the build job runs                         |
| `tests_enabled`           | boolean | `true`     | Run the tests job (set false to skip tests)                       |
| `test_script`             | string  | `'test'`   | package.json test script(s); comma/space/newline separated list   |
| `test_permit_fail`        | boolean | `false`    | Permit test failures without failing the workflow                 |
| `test_artifact_path`      | string  | `''`       | Test output/report path uploaded as an artefact; empty disables   |
| `audit_enabled`           | boolean | `true`     | Run the dependency audit job (set false to skip)                  |
| `audit_level`             | string  | `'high'`   | npm audit severity threshold that fails the audit                 |
| `production_only`         | boolean | `false`    | Restrict the audit to production dependencies                     |
| `audit_permit_fail`       | boolean | `false`    | Permit dependency audit failures (the NO_BLOCK pattern)           |
| `sbom_enabled`            | boolean | `true`     | Generate an SBOM (set false to skip SBOM and Grype jobs)          |
| `grype_fail_on`           | string  | `'medium'` | Severity threshold that fails the Grype scan                      |
| `grype_permit_fail`       | boolean | `false`    | Permit Grype findings without failing the job                     |
| `build_timeout_minutes`   | number  | `15`       | Timeout (minutes) for the build job                               |
| `test_timeout_minutes`    | number  | `10`       | Timeout (minutes) for the tests job                               |
| `audit_timeout_minutes`   | number  | `10`       | Timeout (minutes) for the audit, SBOM and Grype jobs              |
| `harden_runner_egress`    | string  | `'block'`  | Harden-runner egress policy: `block` or `audit`                   |
| `harden_runner_allowlist` | string  | (pinned)   | Out-of-band harden-runner allow-list configuration                |
| `gerrit_refspec`          | string  | `''`       | Gerrit refspec of the change under test                           |
| `gerrit_project`          | string  | `''`       | Gerrit project name                                               |
| `gerrit_branch`           | string  | `''`       | Gerrit target branch                                              |
| `gerrit_url`              | string  | `''`       | Gerrit server URL; empty falls back to the `GERRIT_URL` variable  |

<!-- markdownlint-enable MD013 -->

The workflow takes no secrets and exposes no outputs.

### build-test-release.yaml

All `build-test.yaml` inputs above (with `build_timeout_minutes` and
`test_timeout_minutes` both defaulting to `12`), plus:

<!-- markdownlint-disable MD013 -->

| Input           | Type    | Default    | Description                                                           |
| --------------- | ------- | ---------- | --------------------------------------------------------------------- |
| `attestations`  | boolean | `true`     | Generate SLSA build provenance attestations for the packed tarball    |
| `sigstore_sign` | boolean | `true`     | Sign the packed tarball with Sigstore (keyless/OIDC)                  |
| `nexus_publish` | boolean | `false`    | Publish the package to a Nexus npm registry after release promotion   |
| `registry_url`  | string  | `''`       | npm registry URL that receives the publish (required for Nexus)       |
| `nexus_user`    | string  | `''`       | Nexus username override; empty derives it from the repository name    |
| `npm_tag`       | string  | `'latest'` | npm dist-tag applied to the published version                         |
| `npm_access`    | string  | `''`       | npm publish access: `public` or `restricted`; empty keeps the default |
| `dry_run`       | boolean | `false`    | Run the Nexus publish steps without uploading                         |

<!-- markdownlint-enable MD013 -->

<!-- markdownlint-disable MD013 -->

| Secret                     | Required | Description                                                            |
| -------------------------- | -------- | ---------------------------------------------------------------------- |
| `OP_SERVICE_ACCOUNT_TOKEN` | No       | 1Password service-account token for credential-load-action             |
| `VAULT_MAPPING_JSON`       | No       | Base64-encoded JSON mapping of organisation name to 1Password vault ID |

<!-- markdownlint-enable MD013 -->

| Output | Description                          |
| ------ | ------------------------------------ |
| `tag`  | Validated release tag/version string |

<!-- markdownlint-enable MD013 -->

### merge.yaml

<!-- markdownlint-disable MD013 -->

| Input                     | Type    | Default   | Description                                                              |
| ------------------------- | ------- | --------- | ------------------------------------------------------------------------ |
| `repository`              | string  | `''`      | Repository to check out (owner/name); empty uses the caller              |
| `ref`                     | string  | `''`      | Checkout ref (empty = event ref; other repos: default branch)            |
| `path_prefix`             | string  | `'.'`     | Path to the project root directory                                       |
| `node_version`            | string  | `''`      | Node.js version; empty auto-detects `engines.node`, then 22              |
| `build_tool`              | string  | `''`      | `npm` or `yarn`; empty auto-detects from project metadata                |
| `build_scripts`           | string  | `'build'` | package.json script(s) the build job runs                                |
| `attestations`            | boolean | `true`    | SLSA build provenance for the packed release tarball (release publishes) |
| `sigstore_sign`           | boolean | `true`    | Sign the packed release tarball with Sigstore (release publishes)        |
| `snapshot_registry_url`   | string  | (none)    | REQUIRED: npm registry URL that receives snapshot publishes              |
| `release_registry_url`    | string  | (none)    | REQUIRED: npm registry URL that receives release publishes               |
| `nexus_user`              | string  | `''`      | Nexus username override; empty derives it from the repository name       |
| `dry_run`                 | boolean | `false`   | Run the publish steps without uploading                                  |
| `harden_runner_egress`    | string  | `'block'` | Harden-runner egress policy: `block` or `audit`                          |
| `harden_runner_allowlist` | string  | (pinned)  | Out-of-band harden-runner allow-list configuration                       |
| `gerrit_refspec`          | string  | `''`      | Gerrit refspec of the merged change                                      |
| `gerrit_project`          | string  | `''`      | Gerrit project name                                                      |
| `gerrit_branch`           | string  | `''`      | Gerrit target branch                                                     |
| `gerrit_url`              | string  | `''`      | Gerrit server URL; empty falls back to the `GERRIT_URL` variable         |

<!-- markdownlint-enable MD013 -->

<!-- markdownlint-disable MD013 -->

| Secret                     | Required | Description                                                            |
| -------------------------- | -------- | ---------------------------------------------------------------------- |
| `OP_SERVICE_ACCOUNT_TOKEN` | No       | 1Password service-account token for credential-load-action             |
| `VAULT_MAPPING_JSON`       | No       | Base64-encoded JSON mapping of organisation name to 1Password vault ID |

<!-- markdownlint-enable MD013 -->

The secrets stay optional so PR and self-test contexts work; the
publish steps check credential availability and skip with a warning
when the secrets stay unset.

## Credential Contract (Nexus publishing)

Nexus publishing uses the 1Password credential model through
`lfreleng-actions/credential-load-action`:

- `OP_SERVICE_ACCOUNT_TOKEN` (secret): a 1Password service-account
  token with read access to the per-organisation CI/CD vault.
- `VAULT_MAPPING_JSON` (secret): base64-encoded JSON that maps the
  organisation name (`github.repository_owner`) to the 1Password
  vault ID.
- `CREDENTIAL_LOAD_GRANTS` (repository/organisation **variable**,
  admin-managed): the grants list that authorises repositories to
  load credentials. The workflows wire it in at the workflow layer —
  composite actions cannot read variables — and it never appears as
  a caller-facing input.
- Credential naming: the 1Password credential takes the name of the
  GitHub repository, and the Nexus username defaults to the same
  name. For Gerrit projects the mapping replaces the path separator
  with a hyphen: Gerrit `ccsdk/app` maps to GitHub `ccsdk-app`.
  Use the `nexus_user` input to override the derived username.

## Verifying Release Artefacts (Model A)

Verify the SLSA build provenance attestation with the GitHub CLI:

```shell
gh attestation verify <package>-<version>.tgz --repo <owner>/<repo>
```

Verify the Sigstore signature bundle with cosign:

<!-- markdownlint-disable MD013 -->

```shell
# Pin the identity to this reusable workflow and the release tag so
# signatures from unrelated workflows or refs get rejected; replace
# <tag> with the release tag under verification
cosign verify-blob \
  --bundle <package>-<version>.tgz.sigstore.json \
  --certificate-identity-regexp \
  'https://github.com/lfreleng-actions/node-workflows/.github/workflows/build-test-release.yaml@refs/tags/<tag>' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  <package>-<version>.tgz
```

<!-- markdownlint-enable MD013 -->

## Usage

### GitHub-native caller

```yaml
jobs:
  build-test:
    permissions:
      contents: read
      pull-requests: read
      issues: read  # Grype scan reads approved CVE bypass issues
    uses: lfreleng-actions/node-workflows/.github/workflows/build-test.yaml@main
```

Pin the `uses:` reference to a specific release SHA in production
instead of the mutable `@main` reference. See `examples/build-test/`,
`examples/build-test-release/` and `examples/merge/` for complete
callers, including tag-push release and push-to-main merge triggers.

### Gerrit-wrapped caller

For projects where Gerrit serves as the source of truth,
gerrit_to_platform dispatches caller workflows through
`workflow_dispatch` with nine `GERRIT_*` inputs. The naming contract
requires the verify caller filename to contain both `gerrit` and
`verify` (for example `gerrit-verify.yaml`) and the merge caller
filename to contain both `gerrit` and `merge` (for example
`gerrit-merge.yaml`). See the `gerrit.yaml` variants under
`examples/` for complete callers, including vote/comment plumbing.

## Self-testing

`.github/workflows/testing.yaml` exercises `build-test.yaml` on pull
requests against pinned Node.js fixture repositories (a modern npm
project and a legacy ONAP project). The release and merge workflows
need tag-push and merged-commit contexts (plus publish credentials),
so instantiating repositories exercise those through their own
release and merge cycles.
