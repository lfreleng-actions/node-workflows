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
  -> tests -> attach-artefacts -> nexus-publish -> promote-release
{ build | sbom } -> attest -> attach-artefacts
build -> sign-artefacts -> attach-artefacts
```

`nexus-publish` skips when `nexus_publish` is `false`, and
`promote-release` then follows `attach-artefacts` directly.

`merge.yaml`:

```text
gerrit-validate -> resolve-commit -> { repository-metadata
                                      | node-metadata
                                      | resolve-version }
resolve-version -> check-release
node-metadata -> build
{ resolve-commit | build } -> snapshot-freshness
{ resolve-version | build | snapshot-freshness } -> snapshot-publish
{ check-release | resolve-version | build } -> pack-release (stamp, pack, SBOM)
pack-release -> { attest | sign-artefacts | grype }
{ pack-release | attest | sign-artefacts } -> release-publish
```

## Release Models

### Model A: tag-driven (`build-test-release.yaml`)

A signed semver tag drives the release. The workflow validates the
tag (semver shape, signature, GitHub presence), builds the project,
stamps `package.json` with the tag version, packs the npm tarball,
then attests and signs it:

- SLSA build provenance via `actions/attest`
  (toggle with the `attestations` input)
- CycloneDX SBOM attestation via `actions/attest`, naming the same
  tarball (needs both `attestations` and `sbom_enabled`)
- Sigstore keyless signature bundle via `cosign sign-blob`
  (toggle with the `sigstore_sign` input)

The tarball, Sigstore bundle and SBOM files attach to a draft GitHub
release. With `nexus_publish: true` the workflow then publishes the
package to every configured registry, in parallel, using the
credential contract below. The workflow promotes the release last,
once every publish leg has succeeded: a registry that refuses the
package leaves the release a draft, and re-running the failed jobs
completes it (see [Re-running a Release](#re-running-a-release)).

### Model B: merge-driven (`merge.yaml`)

The Jenkins-heritage LF/Gerrit flow, as used across ONAP and similar
projects. Every merge publishes a snapshot: the `build-metadata-action`
parses `version.properties` (`major=`/`minor=`/`patch=` keys, a
combined `release_version=X.Y.Z` key, or a `version=X.Y.Z` key,
skipping Jenkins-era `${...}` interpolated values) and the
workflow publishes `X.Y.Z-SNAPSHOT` to the snapshot targets under
the `snapshot` dist-tag, leaving `latest` on the newest release. When
the merged commit adds a file under `releases/` whose `version:`
matches `version.properties`, the workflow also publishes the plain
`X.Y.Z` release to the release targets. A version mismatch between
the release file and `version.properties` fails the run before the
release tarball packs, signs, attests or publishes. The snapshot
publish does not wait on that check, so the merge's snapshot can
still publish.
Detection compares the merged commit against its parent, so the run
fails rather than reporting no release when the checkout lacks that
parent.

On the Gerrit path a `resolve-commit` job asks Gerrit, not the
mirror, for one commit, and every job checks out that commit. Given
`gerrit_patchset_revision` (forward `GERRIT_PATCHSET_REVISION`), it
builds the commit that merged that change: the change itself when
fast-forwarded, otherwise its merge commit, so a change merging
mid-run cannot move or split the run. Without it, a branch refspec
builds the current tip. The change has to be on `gerrit_branch`: a
change ref re-runs an already-merged change, and an unmerged one
fails the run.

Because the run reads Gerrit, a caller has no reason to wait for
replication to the GitHub mirror before calling it.

Callers should serialise merge runs per repository: every merge
publishes the same `X.Y.Z-SNAPSHOT`, so two runs at once race to
publish it. Both callers in `examples/merge/` queue them with
`cancel-in-progress: false` and `queue: max`, rather than cancelling
runs or grouping them by change or branch. Without `queue: max` a
newer run replaces a pending one, and a release file that the
replaced run's commit added never publishes.

Re-runs cannot put an older snapshot back on top. Before the snapshot
publishes, a `snapshot-freshness` job checks that the built commit is
still the tip of its branch: `gerrit_branch` on Gerrit, read from
Gerrit, or the branch the GitHub-native run built. Once the branch has
moved on, the run for the newer commit owns the snapshot, so this run
skips it with a notice and the release leg carries on. A run that
builds a tag or a commit SHA has no branch to compare and publishes.
The check works per branch, so give each active branch its own
SNAPSHOT version: branches sharing one replace each other's snapshot
on every merge, re-run or not.
If the run cannot read the tip, the snapshot publishes with a warning
rather than leave the newest merge without one. The job summary
records the decision. "Re-run failed jobs" on a snapshot publish
fails, because it would reuse an earlier attempt's build; use
"Re-run all jobs". Release publishes take neither guard: a release
version is immutable, so a re-run republishes the same version.

Release publishes also gain attestation and a signature. The build job
uploads the built tree rather than a tarball, so a `pack-release` job
stamps that tree to the resolved release version and packs it. That is
the one stamp in the release path: the publish step receives the
archive and stamps nothing. The workflow then records:

- SLSA build provenance via `actions/attest`
  (toggle with the `attestations` input)
- CycloneDX SBOM attestation via `actions/attest`, naming the same
  tarball (needs both `attestations` and `sbom_enabled`)
- Sigstore keyless signature bundle via `cosign sign-blob`
  (toggle with the `sigstore_sign` input)

The release publish waits for the `attest` and `sign-artefacts` jobs
that make them. An enabled record that fails blocks the publish rather
than trailing it, because hosted npm repositories are typically
write-once: nothing can add provenance to a version that
already published without it, whereas a blocked publish is retryable.
Disabling either toggle skips that job and lets the publish proceed.
Disabling `sbom_enabled` skips the SBOM attestation, but the
provenance still runs.

Snapshot publishes stay unattested and unsigned by design, since every
merge replaces them.

The `pack-release` job also generates a CycloneDX SBOM of the release
(`sbom-action`, syft backend) and uploads it as the
`sbom-files-node-merge` workflow artefact, named apart from the verify
lane's `sbom-files`. It scans the project directory after the version
stamp, not the tarball: `npm pack` leaves out `package-lock.json`, so
the packed tree yields no components, while the stamped lockfile puts
the release version on the root component. A failed SBOM fails
`pack-release` and so blocks the publish, as the records above do, so
the run that publishes a version always uploads its SBOM; set
`sbom_enabled: false` to skip it. A dry run still generates it, since
a workflow artefact leaves no public record. Snapshots get no SBOM, as
with attestation and signing; the verify lane's SBOM already covers
each change's dependencies. Outside a dry run, the `attest` job also
attests this SBOM against the release tarball; see
[Verifying Release Artefacts](#verifying-release-artefacts-model-a).

A `grype` job then scans the release SBOM, informationally, as in
`java-workflows`' merge lane: findings at `medium` or above appear in
the job summary, but the job never fails the run and the publish does
not wait for it. The verify lane's Grype scan is the gate. Set
`grype_enabled: false` to skip it.

The calling job must grant `id-token: write` and `attestations: write`.
A caller's `permissions` block caps what the reusable workflow's jobs
can request, so a caller that grants `contents: read` alone leaves the
`attest` and `sign-artefacts` jobs unable to run. Set `attestations`
and `sigstore_sign` to `false` if you would rather not grant them.

Both release lanes publish the **same archive** they attest. The
`pack-release` job, and the matching step inside `build-test-release`'s
`build` job, pack once, and the publish job hands that file to npm
through `node-publish-action`'s `tarball_path`, so npm packs nothing
at publish time. The provenance, the SBOM attestation and the Sigstore
signature cover the exact bytes the registry received.

That also settles a difference the two paths used to carry. `npm pack`
and `npm publish` do not build identical archives: npm runs
`prepublishOnly` for `publish` and never for `pack`, so a project
generating content in that hook once shipped files the attestation did
not cover. With one archive there is no second pack to diverge.

One consequence is worth knowing. npm gates `prepack`, `prepare`,
`prepublishOnly`, `publish` and `postpublish` on packing a directory,
and publishing a tarball runs none of them. The packing hooks still
run in the pack step, where they belong; a project relying on
`postpublish` needs another home for that work.

Nexus npm repositories offer no registry-native provenance, which is
why the artefact-level records exist at all; publishing to a registry
that does support it (such as npmjs.org under trusted publishing)
yields registry-native provenance too.

#### Release files

The `check-release` job validates the release file against the npm
release schema with
[`verify-release-schema-action`](https://github.com/lfreleng-actions/verify-release-schema-action),
and reads its fields from the parsed file rather than searching for a
`version:` line:

```yaml
project: 'onap-ui-common'   # optional
version: '1.1.2'            # required
```

<!-- markdownlint-disable MD013 -->

| Field               | Required | Meaning                                                                       |
| ------------------- | -------- | ----------------------------------------------------------------------------- |
| `version`           | yes      | Full semantic version, such as `1.1.2`; it must match `version.properties`    |
| `project`           | no       | Package the file releases                                                     |
| `git_tag`           | no       | Tag to create for the release; read but not yet used                          |
| `tag_release`       | no       | Whether to tag the release, `true` or `false`; read but not yet used          |
| `ref`               | no       | Commit the release came from                                                  |
| `distribution_type` | no       | Must be `npm` when present                                                    |

<!-- markdownlint-enable MD013 -->

A file that fails the schema (malformed YAML, a missing or partial
`version` such as `1.1`, or another `distribution_type`) fails the run
with the schema error, before the release tarball packs, signs, attests
or publishes. The lane also rejects SemVer build metadata (`1.1.2+build`),
which the schema allows. Validation needs no credentials, so it runs on
dry runs too.

When the file sets `project`, the job compares it with the `name` in
`<path_prefix>/package.json`, accepting the name with or without its
npm scope (`@scope/name` or `name`). A mismatch emits a warning and
does not fail the run. The comparison ignores the repository name,
since a mirror such as `sdc-onap-ui-common` can publish a package
named `onap-ui-common`.

### Re-running a Release

npm never overwrites a published version, and a release reaching
more than one registry is not atomic. Before publishing, each release
leg (`merge.yaml`'s `release-publish`, and `build-test-release.yaml`'s
`nexus-publish`) asks its registry for the version
(`npm view <package>@<version> dist`), reading with the leg's own
credential, and compares what it finds with the tarball it would
publish:

<!-- markdownlint-disable MD013 -->

| The registry holds the version | The leg                                                                        |
| ------------------------------ | ------------------------------------------------------------------------------ |
| No (`E404`)                    | Publishes                                                                      |
| With identical content         | Succeeds without publishing, and says so in the job summary                    |
| With different content         | Fails: npm cannot replace it, and two artefacts under one version need a human |
| Cannot tell (any other error)  | Fails rather than publishing blind; a dry run warns and rehearses instead      |

<!-- markdownlint-enable MD013 -->

Identical means the registry's `sha512` integrity matches the staged
tarball, falling back to the legacy `sha1` shasum where a registry
reports no `sha512`. A leg that finds identical content succeeds, so a
re-run reports the release as published on every target holding it.

The comparison uses the tarball the run packed, so re-run in a way that
reuses it: **Re-run failed jobs** after a partial publish, or, when
every leg succeeded, re-run one `Publish Release (<target>)` job from
the run's summary. *Re-run all jobs* packs again instead, and unless
the build is byte-for-byte reproducible the new archive differs from
the one already published, failing every target that took the first.

When npm's configuration for the package (the tarball's
`publishConfig`, or the project's `.npmrc`) sends the publish to a
registry other than the leg's `registry_url`, the check would read the
wrong registry. That leg warns and publishes as it did before the
check existed.

#### Recovering a missed or partial release

- **Partly published.** Re-run the failed jobs of the original run.
  Targets that already hold the release skip it; the rest publish.
  In Model A the GitHub release stays a draft until every leg
  succeeds, so the same re-run then promotes it; promotion leaves an
  already published release untouched.
- **Never published** (the merge run skipped or lost the release, or is
  too old to re-run). Dispatch `merge.yaml` at the commit that added
  the release file, with `release_only: true`. On a GitHub caller set
  `ref` to that commit; on a Gerrit caller set `gerrit_refspec` to the
  release change's ref (`refs/changes/...`), which the run resolves to
  the commit that merged it. Your caller has to forward the input, for
  example from a `workflow_dispatch` input.

`release_only` skips the snapshot lane, which would otherwise republish
`X.Y.Z-SNAPSHOT` from the old commit over a newer one. The run fails if
the commit adds no release file, rather than skipping the snapshot and
publishing nothing. A recovery rebuilds and repacks, so any target that
already holds the release must hold identical bytes, as above; combine
it with `dry_run: true` to rehearse first.

## Inputs and Secrets

### build-test.yaml

<!-- markdownlint-disable MD013 -->

| Input                     | Type    | Default    | Description                                                                    |
| ------------------------- | ------- | ---------- | ------------------------------------------------------------------------------ |
| `repository`              | string  | `''`       | Repository to check out (owner/name); empty uses the caller                    |
| `ref`                     | string  | `''`       | Checkout ref (empty = event ref; other repos: default branch)                  |
| `path_prefix`             | string  | `'.'`      | Path to the project root directory                                             |
| `node_version`            | string  | `''`       | Node.js version; empty auto-detects `engines.node`, then 22                    |
| `build_node_version`      | string  | `''`       | Node.js for jobs running the project's toolchain; empty follows `node_version` |
| `test_node_version`       | string  | `''`       | Node.js for the tests job; empty follows `node_version`                        |
| `test_node_versions`      | string  | `''`       | Node.js versions to test on, one leg each; JSON array or list, at most 10      |
| `build_tool`              | string  | `''`       | `npm` or `yarn`; empty auto-detects from project metadata                      |
| `build_scripts`           | string  | `'build'`  | package.json script(s) the build job runs                                      |
| `tests_enabled`           | boolean | `true`     | Run the tests job (set false to skip tests)                                    |
| `test_script`             | string  | `'test'`   | package.json test script(s); comma/space/newline separated list                |
| `test_permit_fail`        | boolean | `false`    | Permit test failures without failing the workflow                              |
| `test_artifact_path`      | string  | `''`       | Test output/report path uploaded as an artefact; empty disables                |
| `junit_report_path`       | string  | `''`       | JUnit XML glob summarised in the tests job and uploaded; empty disables        |
| `coverage_path`           | string  | `''`       | `lcov.info`/`coverage-summary.json` (or their directory) summarised and kept   |
| `artifact_suffix`         | string  | `''`       | Appended to every artefact name; give each call in one run its own             |
| `audit_enabled`           | boolean | `true`     | Run the dependency audit job (set false to skip)                               |
| `audit_level`             | string  | `'high'`   | npm audit severity threshold that fails the audit                              |
| `production_only`         | boolean | `false`    | Restrict the audit to production dependencies                                  |
| `audit_permit_fail`       | boolean | `false`    | Permit dependency audit failures (the NO_BLOCK pattern)                        |
| `sbom_enabled`            | boolean | `true`     | Generate an SBOM (set false to skip; Grype then has nothing to scan)           |
| `grype_enabled`           | boolean | `true`     | Run the Grype scan (set false to keep the SBOM but skip the scan)              |
| `grype_fail_on`           | string  | `'medium'` | Severity threshold that fails the Grype scan                                   |
| `grype_permit_fail`       | boolean | `false`    | Permit Grype findings without failing the job                                  |
| `grype_gate_when`         | string  | `'always'` | `always`, or `dependencies-changed`; see [Grype gating](#grype-gating)         |
| `build_timeout_minutes`   | number  | `15`       | Timeout (minutes) for the build job                                            |
| `test_timeout_minutes`    | number  | `10`       | Timeout (minutes) for the tests job                                            |
| `audit_timeout_minutes`   | number  | `10`       | Timeout (minutes) for the audit, SBOM and Grype jobs                           |
| `harden_runner_egress`    | string  | `'block'`  | Harden-runner egress policy: `block` or `audit`                                |
| `harden_runner_allowlist` | string  | (pinned)   | Out-of-band harden-runner allow-list configuration                             |
| `gerrit_refspec`          | string  | `''`       | Gerrit refspec of the change under test                                        |
| `gerrit_project`          | string  | `''`       | Gerrit project name                                                            |
| `gerrit_branch`           | string  | `''`       | Gerrit target branch                                                           |
| `gerrit_url`              | string  | `''`       | Gerrit server URL; empty falls back to the `GERRIT_URL` variable               |

<!-- markdownlint-enable MD013 -->

The workflow takes no secrets and exposes no outputs.

#### Calling a workflow more than once in a run

Every artefact a call uploads takes a fixed name: `sbom-files`,
`grype-scan-results`, the test report names below, and
`node-build-output` (`node-release-package` and `sigstore-bundle` in
`build-test-release.yaml`). A run that calls `build-test.yaml` or
`build-test-release.yaml` more than once, from a matrix over projects
or once per `path_prefix` in a monorepo, must give each call its own
`artifact_suffix`, such as `-${{ matrix.project }}`. The workflow
appends the suffix to every artefact name, so `sbom-files-api` and
`sbom-files-web` stay apart. The suffix takes letters, digits, `.`,
`_` and `-`.

Within a call, jobs hand artefacts to one another by artefact ID, never
by name, so the Grype job scans the SBOM its own call generated, and
the release jobs attest, sign, attach and publish their own call's
tarball. `actions/download-artifact` looks an ID up among the newest
artefact of each name, so when a later call in the run reuses an
artefact name, the earlier call fails its download rather than reading
the other call's artefact. The fix for that failure is a distinct
`artifact_suffix` per call.

#### Grype gating

With `grype_gate_when: dependencies-changed`, Grype still scans and
reports every finding. Findings at or above `grype_fail_on` block the
job when the change touched the dependency chain, and otherwise appear
as warnings. The `sbom` job decides this by comparing the
change with its base for any of `package.json`, `package-lock.json`,
`npm-shrinkwrap.json`, `yarn.lock`, `.yarnrc.yml`, `pnpm-lock.yaml`,
`pnpm-workspace.yaml`, `bun.lock` or `bun.lockb`, at any depth inside
`path_prefix` or directly in a directory above it, where a workspace
root keeps its lockfile.

The base is the first parent of GitHub's merge commit on
`pull_request`, the parent of the change on Gerrit, and
`github.event.before` on `push` when the checkout holds it: a push of
one commit, such as a merged pull request. Anything else leaves the
answer unresolved and the gate on. That covers scheduled and manual
runs, other events, a `repository` or `ref` naming something other
than the triggering commit, a push of commits the shallow checkout
did not fetch, and a `path_prefix` that is missing or passes through a
symlink, which a change could retarget.

`grype_permit_fail` and the `NO_BLOCK_AUDIT_FAIL` variable apply on top
of the gate: either passes the job even when the gate blocks. A
repository that sets `grype_permit_fail: true` to tolerate inherited
advisories can instead set `grype_gate_when: dependencies-changed`, and
still block a change that adds a vulnerable dependency.
`build-test-release.yaml` does not take this input: a release always
gates.

### build-test-release.yaml

All `build-test.yaml` inputs above except `grype_gate_when` (with
`build_timeout_minutes` and `test_timeout_minutes` both defaulting to
`12`), plus:

<!-- markdownlint-disable MD013 -->

| Input                 | Type    | Default    | Description                                                            |
| --------------------- | ------- | ---------- | ---------------------------------------------------------------------- |
| `attestations`        | boolean | `true`     | Generate SLSA build provenance attestations for the packed tarball     |
| `sigstore_sign`       | boolean | `true`     | Sign the packed tarball with Sigstore (keyless/OIDC)                   |
| `nexus_publish`       | boolean | `false`    | Publish the package to one or more npm registries before promotion     |
| `publish_targets`     | string  | `''`       | JSON array of publish targets; see [Publish Targets](#publish-targets) |
| `registry_url`        | string  | `''`       | Single registry URL; deprecated, prefer `publish_targets`              |
| `nexus_user`          | string  | `''`       | Nexus username override; empty derives it from the repository name     |
| `npm_tag`             | string  | `'latest'` | npm dist-tag applied to the published version                          |
| `npm_access`          | string  | `''`       | npm publish access: `public` or `restricted`; empty keeps the default  |
| `dry_run`             | boolean | `false`    | Run the publish steps for every target without uploading               |
| `publish_environment` | string  | `''`       | GitHub environment gating the publish jobs; empty uses none            |

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

| Input                      | Type    | Default      | Description                                                                                                                      |
| -------------------------- | ------- | ------------ | -------------------------------------------------------------------------------------------------------------------------------- |
| `repository`               | string  | `''`         | Repository to check out (owner/name); empty uses the caller                                                                      |
| `ref`                      | string  | `''`         | Checkout ref (empty = event ref; other repos: default branch)                                                                    |
| `path_prefix`              | string  | `'.'`        | Path to the project root directory                                                                                               |
| `node_version`             | string  | `''`         | Node.js version; empty auto-detects `engines.node`, then 22                                                                      |
| `build_node_version`       | string  | `''`         | Node.js for jobs running the project's toolchain; empty follows `node_version`                                                   |
| `build_tool`               | string  | `''`         | `npm` or `yarn`; empty auto-detects from project metadata                                                                        |
| `build_scripts`            | string  | `'build'`    | package.json script(s) the build job runs                                                                                        |
| `attestations`             | boolean | `true`       | SLSA build provenance for the packed release tarball (release publishes)                                                         |
| `sigstore_sign`            | boolean | `true`       | Sign the packed release tarball with Sigstore (release publishes)                                                                |
| `sbom_enabled`             | boolean | `true`       | Generate the release SBOM (`sbom-files-node-merge` artefact); a failure blocks the release publish                               |
| `grype_enabled`            | boolean | `true`       | Run the informational Grype scan over the release SBOM; never fails the run                                                      |
| `snapshot_targets`         | string  | `''`         | REQUIRED unless you set `snapshot_registry_url`: JSON array of snapshot publish targets; see [Publish Targets](#publish-targets) |
| `release_targets`          | string  | `''`         | REQUIRED unless you set `release_registry_url`: JSON array of release publish targets; see [Publish Targets](#publish-targets)   |
| `snapshot_registry_url`    | string  | `''`         | REQUIRED unless you set `snapshot_targets`: single snapshot registry URL; deprecated, prefer `snapshot_targets`                  |
| `release_registry_url`     | string  | `''`         | REQUIRED unless you set `release_targets`: single release registry URL; deprecated, prefer `release_targets`                     |
| `nexus_user`               | string  | `''`         | Nexus username override; empty derives it from the repository name                                                               |
| `snapshot_dist_tag`        | string  | `'snapshot'` | npm dist-tag for snapshot publishes; never `latest`, which must name the newest release                                          |
| `snapshot_environment`     | string  | `''`         | GitHub environment gating the snapshot publish jobs; empty uses none                                                             |
| `release_environment`      | string  | `''`         | GitHub environment gating the release publish jobs, e.g. one requiring a reviewer; empty uses none                               |
| `dry_run`                  | boolean | `false`      | Rehearse publishing without uploading; needs no secrets, and skips attestation and signing                                       |
| `release_only`             | boolean | `false`      | Recovery: publish the release and skip the snapshot; see [Re-running a Release](#re-running-a-release)                           |
| `harden_runner_egress`     | string  | `'block'`    | Harden-runner egress policy: `block` or `audit`                                                                                  |
| `harden_runner_allowlist`  | string  | (pinned)     | Out-of-band harden-runner allow-list configuration                                                                               |
| `gerrit_refspec`           | string  | `''`         | Gerrit refspec: the branch ref, or a merged change's ref to re-run it; resolved once for every job                               |
| `gerrit_patchset_revision` | string  | `''`         | Triggering change revision (`GERRIT_PATCHSET_REVISION`); pins the run to the commit that merged it                               |
| `gerrit_project`           | string  | `''`         | Gerrit project name                                                                                                              |
| `gerrit_branch`            | string  | `''`         | Gerrit target branch                                                                                                             |
| `gerrit_url`               | string  | `''`         | Gerrit server URL; empty falls back to the `GERRIT_URL` variable                                                                 |

<!-- markdownlint-enable MD013 -->

<!-- markdownlint-disable MD013 -->

| Secret                     | Required | Description                                                            |
| -------------------------- | -------- | ---------------------------------------------------------------------- |
| `OP_SERVICE_ACCOUNT_TOKEN` | No       | 1Password service-account token for credential-load-action             |
| `VAULT_MAPPING_JSON`       | No       | Base64-encoded JSON mapping of organisation name to 1Password vault ID |

<!-- markdownlint-enable MD013 -->

A live run fails when either secret is unset, since `merge.yaml`
runs on merges, where a missing secret is a misconfiguration. A dry
run needs neither and never loads a credential, even when the caller
supplies both: it rehearses each publish without one, and skips
attestation and signing, which would leave permanent public records
for a version that never shipped.

The outputs report the merge outcome, so a caller can tell a release
that published from one that did not. `examples/merge/gerrit.yaml`
posts them to the change, for example `Released 1.1.1 to nexus`.
Each value comes from a job that has to succeed: a job that fails,
skips or stops on cancellation yields `''`, never what it wrote
before stopping. The two `*_published` outputs are the exception.
They are always `'true'` or `'false'`, and they come from the publish
job's combined result, because every matrix leg overwrites the
others' job outputs. `'true'` means every target accepted the
version. `'false'` does not mean none did: the legs run
independently, so a failed leg can leave the version on the other
targets.

<!-- markdownlint-disable MD013 -->

| Output                   | Description                                                                                                                        |
| ------------------------ | ---------------------------------------------------------------------------------------------------------------------------------- |
| `commit`                 | Commit `resolve-commit` chose for the Gerrit path; `''` on the GitHub-native path, which builds `ref`                              |
| `snapshot_version`       | The `X.Y.Z-SNAPSHOT` version from `version.properties`                                                                             |
| `snapshot_published`     | `'true'` when every snapshot target accepted it; `'false'` on any failed leg, a skipped lane, or a dry run                         |
| `snapshot_target_names`  | Comma-separated names of the resolved snapshot targets                                                                             |
| `has_release`            | `'true'` when the merged commit adds a valid release file matching `version.properties`, `'false'` when it adds none; else `''`    |
| `release_version`        | Version the release file requests; `''` unless `has_release` is `'true'`                                                           |
| `release_published`      | `'true'` when every release target accepted it; `'false'` with no release, on any failed leg, or on a dry run                      |
| `release_target_names`   | Comma-separated names of the resolved release targets, set even when no release ran                                                |
| `release_tarball_sha256` | SHA-256 of the packed release tarball, the archive npm receives; set on dry runs too                                               |
| `attestation_url`        | URL of the tarball's build provenance; `''` with `attestations` off, on a dry run, or with no release                              |

<!-- markdownlint-enable MD013 -->

## Node.js Version Selection

`node_version` sets the Node.js used across the pipeline. Empty (the
default) takes a plain `engines.node` from `package.json`, and falls
back to 22.

Two optional inputs narrow that for the jobs that run the **project's
own toolchain**, leaving everything else on `node_version`:

<!-- markdownlint-disable MD013 -->

| Input                | Applies to                              | Empty means            |
| -------------------- | --------------------------------------- | ---------------------- |
| `build_node_version` | the `build` job                         | follow `node_version`  |
| `test_node_version`  | the `tests` job (not in `merge.yaml`)   | follow `node_version`  |
| `test_node_versions` | one `tests` leg per version (likewise)  | one leg, as above      |

<!-- markdownlint-enable MD013 -->

Everything else stays on `node_version`, for two different reasons.
Packing and publishing consume the built artefact rather than
rebuilding it. The dependency audit never builds at all — it takes a
fresh checkout and reads the dependency tree. Neither needs a project
toolchain of its own.

> [!IMPORTANT]
> That is not the same as running no project code. `npm pack` executes
> `prepack` and `prepare` (see
> [the note on attestation scope](#release-models)). Those hooks run
> under `node_version`, **not** `build_node_version`, so a project
> splitting the two must keep its packing hooks compatible with the
> newer toolchain. Hooks that need the legacy toolchain belong in the
> build script instead, where `build_node_version` applies.

### When you need this

A legacy dependency tree can cap the build below what the release
lane requires, leaving no single version that satisfies both.

For example, `node-sass 4.9.2` stops shipping prebuilt bindings after
Node 10, and falls back to a source compile that fails on newer
runners. Meanwhile `pack-release` uses `npm pack --pack-destination`,
which arrived in npm 7 (Node 15+); under npm 6 npm ignores the flag,
the tarball lands in the working directory and the job fails with
`npm pack produced no tarball`.

Splitting the two lets such a project adopt these workflows:

```yaml
    with:
      # The pack/publish jobs stay on a modern toolchain
      node_version: '22'
      # ...while the project itself compiles on the version its
      # dependency tree supports
      build_node_version: '10'
      # Tests often run somewhere newer again
      test_node_version: '18'
```

The overrides accept the same forms as `node_version`, including
aliases such as `lts/*`, and share its character set — these values
reach `actions/setup-node` and the job summary.

### Testing across Node.js versions

A library supporting more than one Node.js major can test on each.
`test_node_versions` fans the `tests` job out, one leg per version:

```yaml
    with:
      test_node_versions: '["20", "22", "24"]'
```

- It takes a JSON array or a comma, space or newline separated list of
  up to 10 versions. Entries share the forms and character set of
  `node_version`, and the workflow drops duplicates. It rejects an
  empty entry, such as `""` or the field in `20,,22`.
- Set `test_node_version` or `test_node_versions`, not both: the
  workflow rejects the pair rather than pick one.
- Each leg checks out the source and installs dependencies afresh
  under its own Node.js before running `test_script`. It does not
  reuse the `build` job's toolchain (`build_node_version`).
- Legs run with `fail-fast: false`, so every version reports. Any
  failing leg fails the `tests` job, and with it the workflow (and, in
  `build-test-release.yaml`, the release). `test_permit_fail` applies
  to each leg.
- Build, audit, SBOM, pack and publish stay on a single version.
- Legs carry the version in their names, such as `Tests (Node 22)`:
  update any required status checks naming `Tests`. Likewise each leg's
  artefacts take a `-node-<version>` suffix, with `/` and `*` replaced
  by `_`: `node-test-results-node-22` from `test_artifact_path`, and
  `node-junit-node-22` and `node-coverage-node-22` from
  [test reporting](#test-results-and-coverage).

Left empty, the job runs once as before, keeping the `Tests` name and
the unsuffixed artefact names.

## Publish Targets

Both publish workflows take the same target list.

In `merge.yaml` each lane needs **one** of its two forms. Leaving both
`snapshot_targets` and `snapshot_registry_url` empty fails the
workflow, and likewise for the release lane: both lanes always
resolve, so an empty configuration is a mistake rather than a way to
opt out of publishing. An empty array (`[]`) counts as a mistake too:
the resolver rejects it rather than falling back to the URL input.
Use `dry_run` to run the publish steps without uploading.

`build-test-release.yaml` differs, because publishing there is
opt-in. The targets resolve when `nexus_publish` is `true`, and
`publish_targets` or `registry_url` becomes required at that point.
Leave `nexus_publish` at `false` to skip publishing entirely.

One artefact can reach more than one registry. A matrix fans the list
out, so each registry publishes in parallel and fails on its own:

```yaml
    release_targets: |
      [
        {"name": "nexus",
         "registry_url": "https://nexus3.example.org/repository/npm.release/",
         "auth": "nexus"},
        {"name": "npmjs",
         "registry_url": "https://registry.npmjs.org/",
         "auth": "token",
         "credential_name": "example-npmjs-publish-token"}
      ]
```

The input is `publish_targets` in `build-test-release.yaml`, which has
a single publish lane, and `snapshot_targets` / `release_targets` in
`merge.yaml`, which has two. The entry format below is identical.

<!-- markdownlint-disable MD013 -->

| Field             | Required | Meaning                                                                          |
| ----------------- | -------- | -------------------------------------------------------------------------------- |
| `name`            | Yes      | Labels the matrix leg, so a failed check names the registry. Unique per list     |
| `registry_url`    | Yes      | Absolute `https` URL ending in `/`. Unique per list                              |
| `auth`            | Yes      | `nexus` for Basic auth, `token` for a bearer token                               |
| `credential_name` | No       | 1Password item holding the credential; empty derives it from the repository name |

<!-- markdownlint-enable MD013 -->

`registry.npmjs.org` rejects Basic auth for publishing, so a target
aiming there needs `auth: token`.

Each leg loads its own credential, which is what lets one lane reach
registries with unrelated credentials. `credential_name` still passes
through the admin-managed `CREDENTIAL_LOAD_GRANTS` allow-list, so
naming an item here cannot widen what a repository may read.

`fail-fast` stays off. The legs are independent destinations for the
same artefact, and completing a partial publish is easier than
redoing a whole one.

A malformed list fails once in a `Resolve Targets` job before the
publish legs start, naming the offending entry. The resolver also
refuses duplicate names and duplicate registry URLs: two legs
publishing the same version to one registry cannot both succeed, and
the loser fails with `EPUBLISHCONFLICT` on a version that did publish.

> [!NOTE]
> OIDC trusted publishing is not available as an `auth` mode yet. It
> needs `id-token: write`, which GitHub cannot grant per matrix leg,
> so issue #54 tracks it separately.

### Migrating from the single-URL inputs

`snapshot_registry_url`, `release_registry_url` and
`build-test-release.yaml`'s `registry_url` still work and resolve to a
one-element list using `nexus` auth, which is what they have always
meant. A run using them emits a deprecation notice. Supplying a
targets list makes the matching URL input inert.

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

### Gating the publish jobs behind an environment

The jobs that load these credentials can run behind a GitHub
deployment environment, so a caller can require reviewers, restrict
branches, or keep the secrets as environment secrets:

- `build-test-release.yaml`: `publish_environment` gates
  `nexus-publish`.
- `merge.yaml`: `snapshot_environment` gates `snapshot-publish` and
  `release_environment` gates `release-publish`. They are separate
  because a reviewer suits a release, whereas on the snapshot, which
  publishes on every merge, one would hold every run.

The environment applies to the publish jobs and nothing else: the
build, the checks, attestation and signing run as before. Empty, the
default, runs the publish jobs without one. An environment secret
takes precedence over a secret of the same name that the caller
passes. GitHub creates a missing environment, unprotected, the first
time a job names it, so configure the environment before naming it.

## Verifying Release Artefacts (Model A)

The attestation and the signature both come from jobs inside this
reusable workflow, so the Sigstore certificate behind each one names
the reusable workflow as the signer. The calling run's repository and
tag appear in the GitHub extensions of the certificate, not in its
identity:

<!-- markdownlint-disable MD013 -->

| Certificate field                             | Binds                                       | Value                                                                                                |
| --------------------------------------------- | ------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| Subject Alternative Name (identity)           | This workflow, at the ref the caller pinned | `https://github.com/lfreleng-actions/node-workflows/.github/workflows/build-test-release.yaml@<ref>` |
| GitHub Workflow Repository                    | The calling repository                      | `<owner>/<repo>`                                                                                     |
| GitHub Workflow Ref and Source Repository Ref | The tag the caller ran on                   | `refs/tags/<tag>`                                                                                    |
| GitHub Workflow Trigger                       | The triggering event                        | `push`                                                                                               |

<!-- markdownlint-enable MD013 -->

`<ref>` is whatever follows `@` in the caller's `uses:` line,
typically a node-workflows commit SHA. Check the identity and the
extensions together: the identity alone accepts an artefact that any
project released through this workflow, and the extensions alone
accept one from any workflow that ran on that tag.

The extensions describe the calling run, not the checkout. The
`repository` and `ref` inputs can point the build at other source, so
the extensions identify the packaged source when the caller leaves
both inputs empty, as the examples do, and not otherwise.

Verify the SLSA build provenance attestation with GitHub CLI v2.102.0
or later; earlier releases matched `--signer-workflow` as a prefix
([GHSA-wjmr-j3rp-mh2g]) and `--source-ref` without regard to case
([GHSA-4mq3-hpgx-9cx8]). `--signer-workflow` is mandatory: without it
`gh` expects a signer in the project repository and rejects every
release:

<!-- markdownlint-disable MD013 -->

```shell
gh attestation verify <package>-<version>.tgz \
  --repo <owner>/<repo> \
  --signer-workflow lfreleng-actions/node-workflows/.github/workflows/build-test-release.yaml \
  --source-ref refs/tags/<tag>
```

<!-- markdownlint-enable MD013 -->

When `sbom_enabled` is on, the same job also attests the CycloneDX
SBOM against the same tarball. `gh` checks SLSA provenance unless told
otherwise, so name the CycloneDX predicate type to verify the SBOM
attestation instead:

<!-- markdownlint-disable MD013 -->

```shell
gh attestation verify <package>-<version>.tgz \
  --repo <owner>/<repo> \
  --signer-workflow lfreleng-actions/node-workflows/.github/workflows/build-test-release.yaml \
  --source-ref refs/tags/<tag> \
  --predicate-type https://cyclonedx.org/bom
```

<!-- markdownlint-enable MD013 -->

The SBOM describes the project's dependencies as `sbom-action`'s syft
backend resolves them from the lockfile, not the list of files inside
the tarball. The attestation states that this workflow produced this
SBOM for this release. npm records build provenance and has no
place for an SBOM, and adding one to the tarball would change the
attested bytes, so the attestation is what ties the SBOM to the
published package.

Any copy of the tarball verifies, the registry's included, since both
lanes publish the archive they attest. `npm pack <package>@<version>`
fetches the registry's copy.

Both `gh` commands verify a Model B release, with `merge.yaml` in place
of `build-test-release.yaml` in `--signer-workflow`, and
`--source-ref` set to the GitHub ref of the run that published it:
the pushed branch, or the ref a `workflow_dispatch` targeted.

Verify the Sigstore signature bundle with cosign v3 or later. The
workflow emits a v0.3 Sigstore bundle, which cosign v2.2 cannot read:

<!-- markdownlint-disable MD013 -->

```shell
cosign verify-blob \
  --bundle <package>-<version>.tgz.sigstore.json \
  --certificate-identity-regexp \
  '^https://github\.com/lfreleng-actions/node-workflows/\.github/workflows/build-test-release\.yaml@' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-github-workflow-repository <owner>/<repo> \
  --certificate-github-workflow-ref refs/tags/<tag> \
  --certificate-github-workflow-trigger push \
  <package>-<version>.tgz
```

<!-- markdownlint-enable MD013 -->

Both commands accept any revision of this workflow. To pin the
revision as well, take the commit SHA from the project's caller at the
release tag, add `--signer-digest <sha>` to the `gh` command, and
replace cosign's `--certificate-identity-regexp` with
`--certificate-identity` and the full SAN ending in `@<sha>`.

[GHSA-wjmr-j3rp-mh2g]: https://github.com/cli/cli/security/advisories/GHSA-wjmr-j3rp-mh2g
[GHSA-4mq3-hpgx-9cx8]: https://github.com/cli/cli/security/advisories/GHSA-4mq3-hpgx-9cx8

## Usage

### GitHub-native caller

<!-- markdownlint-disable MD013 -->

```yaml
jobs:
  build-test:
    permissions:
      contents: read
      pull-requests: read
    # yamllint disable-line rule:line-length
    uses: lfreleng-actions/node-workflows/.github/workflows/build-test.yaml@<SHA>  # vX.Y.Z
```

<!-- markdownlint-enable MD013 -->

Pin the `uses:` reference to the commit SHA of a node-workflows
release. Never use a mutable ref such as `@main`, which follows
whatever lands upstream without review. See `examples/build-test/`,
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

## Test Results and Coverage

The `tests` job can summarise a run in its job summary and keep the
reports as artefacts. Both inputs take paths relative to
`path_prefix`, and both are off by default:

<!-- markdownlint-disable MD013 -->

| Input               | Points at                                                      | Job summary                                   | Artefact        |
| ------------------- | -------------------------------------------------------------- | --------------------------------------------- | --------------- |
| `junit_report_path` | A glob of JUnit XML files (`*` and `**` allowed)               | Test counts: passed, failed, errored, skipped | `node-junit`    |
| `coverage_path`     | `lcov.info`, `coverage-summary.json`, or a directory of either | Line, branch, function and statement coverage | `node-coverage` |

<!-- markdownlint-enable MD013 -->

Reporting never changes the job's result. The `Run tests` step alone
decides pass or fail, honouring `test_permit_fail`, and the reports
still render after a failing run, when they matter most. A report
that does not exist raises a warning, not an error: a suite that
crashes before writing one has already failed the job. The workflow
reports coverage but enforces no threshold.

[junit-test-report-action](https://github.com/lfreleng-actions/junit-test-report-action)
renders the JUnit counts. For coverage, the job reads the istanbul
`json-summary` format when `coverage-summary.json` exists, and
otherwise totals the `LF`/`LH`, `BRF`/`BRH` and `FNF`/`FNH` records of
`lcov.info`. `lcov.info` carries no statement count, so that row
needs `coverage-summary.json`. The `node-coverage` artefact holds
what `coverage_path` names: name the directory to keep the HTML
report beside `lcov.info` for a later Sonar or Codecov job. With
`test_node_versions` set, each leg suffixes these names as described
in [Testing across Node.js versions](#testing-across-nodejs-versions).
A run that calls the workflow more than once with these inputs set
needs a distinct `artifact_suffix` per call; see
[Calling a workflow more than once in a run](#calling-a-workflow-more-than-once-in-a-run).

The tests job runs `package.json` scripts by name, and accepts names
made of letters, digits, `-` and `_` (`test-ci`, not `test:ci`). Add
a script that writes the reports and select it with `test_script`:

```yaml
    with:
      test_script: 'test-ci'
      junit_report_path: 'junit.xml'
      coverage_path: 'coverage'
```

A `test-ci` script for each common runner, writing `junit.xml` and a
`coverage` directory:

<!-- markdownlint-disable MD013 -->

- Jest, with the `jest-junit` package:

  ```json
  "test-ci": "jest --ci --coverage --coverageReporters=lcov --coverageReporters=json-summary --reporters=default --reporters=jest-junit"
  ```

- Vitest, with `@vitest/coverage-v8`. Without `reportOnFailure`,
  Vitest writes no coverage for a failing run:

  ```json
  "test-ci": "vitest run --reporter=default --reporter=junit --outputFile.junit=junit.xml --coverage --coverage.reporter=lcov --coverage.reporter=json-summary --coverage.reportOnFailure"
  ```

- Mocha, with the `mocha-junit-reporter` and `c8` packages:

  ```json
  "test-ci": "c8 --reporter=lcov --reporter=json-summary mocha --reporter mocha-junit-reporter --reporter-options mochaFile=junit.xml"
  ```

- The Node.js test runner, with no packages. Its coverage is still
  experimental and writes `lcov.info` alone, and each
  `--test-reporter-destination` directory has to exist already, so
  this writes both reports to the project root; set
  `coverage_path: 'lcov.info'`:

  ```json
  "test-ci": "node --test --experimental-test-coverage --test-reporter=spec --test-reporter-destination=stdout --test-reporter=junit --test-reporter-destination=junit.xml --test-reporter=lcov --test-reporter-destination=lcov.info"
  ```

<!-- markdownlint-enable MD013 -->

> [!NOTE]
> junit-test-report-action counts `<testsuite>` elements. Node.js
> writes a top-level `test()` straight under `<testsuites>`, where
> the summary misses it: group tests in a `describe()` or `suite()`.

## Self-testing

`.github/workflows/testing.yaml` exercises `build-test.yaml` on pull
requests against pinned Node.js fixture repositories (a modern npm
project and a legacy ONAP project). The `build-test-assert` job then
checks what those runs produced, beyond their passing verdicts. Each
leg passes its name as `artifact_suffix`, so the check knows whose
artefact is whose:

- every leg uploads one SBOM, CycloneDX JSON listing at least one
  component; the `test-node-project` SBOM lists that package,
  `express` and its transitive dependency `body-parser`, all
  versioned, and no other leg's SBOM lists `test-node-project`;
- the leg that sets `test_artifact_path` fans its tests out over
  `test_node_versions`, and uploads one
  `node-test-results-node-<version>-test-node-project` artefact per
  version and no other `node-test-results` artefact;
- the audit and Grype jobs of every leg ran; a skipped job fails
  the check;
- each leg's Grype job downloaded, by the artefact ID its download
  step names, the SBOM its own leg uploaded, so legs that cross over
  fail the check.

Neither fixture emits `dist/`, so the check makes no claim about the
`node-build-output` artefact. The release and merge workflows
need tag-push and merged-commit contexts (plus publish credentials),
so instantiating repositories exercise those through their own
release and merge cycles.
