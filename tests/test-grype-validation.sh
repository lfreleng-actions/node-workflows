#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Contract check for the Grype input validation.
#
# Each workflow that scans an SBOM with lfreleng-actions/grype-scan-action
# validates the policy inputs first, in its gerrit-validate job, by
# running the same action in validate-only mode. That step must use
# the action at the scan step's pin, pass validate-only as the literal
# 'true' and mirror every input the scan passes, whatever the shape of
# its value (a literal, one expression or a compound expression), as
# the identical string, and nothing else. The only inputs it may omit
# are a fixed, named set: sbom and target, which validate-only has no
# use for; artifact-name, github-token and output-prefix, which only
# shape the scan's output; and
# dependencies-changed, a signal a later job computes, which no
# caller sets and gerrit-validate cannot evaluate. The mirror is
# derived from the scan step's with: block, so an input added there
# but not to the validator fails here, whatever its value looks
# like. Values are compared as the strings the YAML holds: nothing
# here evaluates an expression, and which values the action rejects
# is the action's own test suite's concern. No shell step may read a
# grype_* input the action owns; grype_dependency_ecosystems and
# grype_dependency_patterns belong to repository-metadata-action and
# stay in shell. Each workflow must also declare the policy inputs
# with the agreed types and defaults.
#
# A rejected input must stop the lane before any build job. The
# guarantee rests on the first hop, so the check holds each lane to
# a boundary that needs no expression parsing: gerrit-validate has
# no needs, if or continue-on-error; the validator step has no
# continue-on-error; every job that lists gerrit-validate in its
# needs has an if: containing none of always(), cancelled() (so
# neither !cancelled()) or failure(), as a substring test, so a
# validation failure skips it; and every other job transitively
# needs one of those first-hop jobs. How a downstream job guards on
# its own upstream (!cancelled() && needs.build.result == 'success'
# and the like) is the workflows' existing design and out of scope
# here. A called workflow that fails marks the caller's run red, so
# testing.yaml cannot exercise that by calling a lane with a bad
# input; this check holds the lanes to the shape that fails fast
# instead.
#
# It first checks the real workflows, then mutates a copy of one of
# them in each way the check must catch and expects each mutant to
# fail, so a check that silently passes everything fails here too.
#
# Usage: bash tests/test-grype-validation.sh [<workflows-dir>]
#
# Needs python3 with PyYAML.

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
workflows="${1:-${repo_root}/.github/workflows}"

if [ ! -d "${workflows}" ]; then
  echo "ERROR: workflows directory not found: ${workflows}" >&2
  exit 1
fi

if ! python3 -c 'import yaml' 2>/dev/null; then
  echo "ERROR: python3 cannot import yaml; install PyYAML" >&2
  exit 1
fi

# '-I' keeps the working directory off sys.path.
python3 -I - "${workflows}" <<'PYEOF'
import copy
import pathlib
import re
import sys

import yaml

ACTION = "lfreleng-actions/grype-scan-action"
# v0.6.2: validate-only (v0.6.0), with rejected values escaped in the
# log (v0.6.1) and a retried Grype install (v0.6.2).
PIN = "f65dca2762823cfc8f376e32fee9baa6f3292696"
USES = f"{ACTION}@{PIN}"
PIN_LINE = f"uses: {USES}  # v0.6.2"

VALIDATE_JOB = "gerrit-validate"
VALIDATOR = "Validate Grype inputs"
SCAN_JOB = "grype"
SCAN_ID = "grype-audit"

# Inputs of repository-metadata-action, which stay in shell
DETECTION = ("grype_dependency_ecosystems", "grype_dependency_patterns")
# The scan inputs the validator must not mirror, and the only ones it
# may omit. Every other key of the scan's with: block is mirrored,
# whatever the shape of its value.
EXCLUDED = {
    # validate-only scans nothing, so it needs neither
    "sbom": "validate-only scans nothing",
    "target": "validate-only scans nothing",
    # Shape the scan's output alone
    "artifact-name": "it only names the scan's artefact",
    "github-token": "it only reads bypass issues, which validate-only"
                    " does not",
    "output-prefix": "it only names the scan's report files",
    # repository-metadata computes it after gerrit-validate, so the
    # validator cannot evaluate the scan's expression, and no caller
    # sets it
    "dependencies-changed": "repository-metadata computes it later",
}
# Lane -> {workflow input: (type, default, scan input it feeds)}. The
# verify lanes gate, so their defaults are the strict ones; merge
# reports and never gates, so its defaults are the action's own.
VERIFY = {
    "grype_fail_on": ("string", "medium", "fail-on"),
    "grype_only_fixed": ("boolean", True, "only-fixed"),
    "grype_dependency_policy": ("string", "declared", "dependency-policy"),
    "grype_transitive_fail_on": ("string", "critical", "transitive-fail-on"),
    "grype_remediation_window_days": ("string", "", "remediation-window-days"),
    "grype_remediation_window_start": (
        "string", "", "remediation-window-start",
    ),
    "grype_bypass_repository": ("string", "", "bypass-repository"),
}
LANES = {
    "build-test.yaml": {
        **VERIFY,
        "grype_gate_when": ("string", "always", "gate-when"),
    },
    "build-test-release.yaml": VERIFY,
    "merge.yaml": {
        "grype_fail_on": ("string", "medium", "fail-on"),
        "grype_only_fixed": ("boolean", False, "only-fixed"),
        "grype_dependency_policy": ("string", "all", "dependency-policy"),
        "grype_transitive_fail_on": ("string", "none", "transitive-fail-on"),
        "grype_bypass_repository": ("string", "", "bypass-repository"),
    },
}
# The functions that let a job run after a need failed. GitHub reads
# them in any case, so the if: is lower-cased before the substring
# test; 'cancelled()' covers '!cancelled()' too.
STATUS_FUNCTIONS = ("always()", "cancelled()", "failure()")


def triggers(doc):
    # PyYAML reads a bare 'on' key as the boolean True.
    on = doc.get("on", doc.get(True))
    return on if isinstance(on, dict) else {}


def steps_of(doc, job_id):
    """Return the job's step list itself, so a mutant can extend it."""
    job = (doc.get("jobs") or {}).get(job_id) or {}
    steps = job.get("steps") or []
    return steps if all(isinstance(s, dict) for s in steps) else []


def one(steps, key, value, where, problems):
    """Return the one step whose key is value, or None with a problem."""
    found = [s for s in steps if s.get(key) == value]
    if len(found) != 1:
        problems.append(f"{where} has {len(found)} steps with {key} {value!r}")
        return None
    return found[0]


def mirrored_inputs(step):
    """Return every input the step passes that the validator mirrors."""
    return {
        name: value
        for name, value in (step.get("with") or {}).items()
        if name not in EXCLUDED
    }


def reads_grype_input(step, allowed):
    """Return the grype_* inputs a run: step reads, less the allowed."""
    if "run" not in step:
        return set()
    text = yaml.safe_dump(step)
    found = set(re.findall(r"inputs\.(grype_[a-z_]+)", text))
    return found - set(allowed)


def check_lane(name, doc):
    """Return the list of problems in one parsed lane workflow."""
    problems = []
    table = LANES[name]
    inputs = (triggers(doc).get("workflow_call") or {}).get("inputs") or {}
    for key, (kind, default, _) in table.items():
        spec = inputs.get(key)
        if not isinstance(spec, dict):
            problems.append(f"input {key} is missing")
        elif (
            spec.get("type") != kind
            or spec.get("default") != default
            or type(spec.get("default")) is not type(default)
        ):
            problems.append(
                f"input {key} is {spec.get('type')!r} defaulting to"
                f" {spec.get('default')!r}, expected {kind} defaulting"
                f" to {default!r}"
            )
    for key in DETECTION:
        spec = inputs.get(key)
        # Only build-test.yaml detects dependency changes
        if name != "build-test.yaml":
            if spec is not None:
                problems.append(f"input {key} belongs to build-test.yaml alone")
        elif not isinstance(spec, dict) or (
            spec.get("type"), spec.get("default")
        ) != ("string", ""):
            problems.append(f"input {key} is not a string defaulting to ''")
    validate = steps_of(doc, VALIDATE_JOB)
    scan = one(steps_of(doc, SCAN_JOB), "id", SCAN_ID, SCAN_JOB, problems)
    validator = one(validate, "name", VALIDATOR, VALIDATE_JOB, problems)
    if scan is None or validator is None:
        return problems
    mirrored = mirrored_inputs(scan)
    for key, (_, _, passed) in table.items():
        want = "${{ inputs." + key + " }}"
        if mirrored.get(passed) != want:
            problems.append(
                f"{SCAN_ID} passes {passed} as"
                f" {(scan.get('with') or {}).get(passed)!r}, expected {want!r}"
            )
    if scan.get("uses") != USES:
        problems.append(f"{SCAN_ID} uses {scan.get('uses')!r}, not {USES}")
    if validator.get("uses") != scan.get("uses"):
        problems.append(f"'{VALIDATOR}' and {SCAN_ID} do not share one pin")
    if "if" in validator:
        problems.append(f"'{VALIDATOR}' is conditional; it must always run")
    passed = validator.get("with") or {}
    if passed.get("validate-only") != "true" or not isinstance(
        passed.get("validate-only"), str
    ):
        problems.append(f"'{VALIDATOR}' does not pass validate-only 'true'")
    for key, why in EXCLUDED.items():
        if key in passed:
            problems.append(f"'{VALIDATOR}' passes {key}; {why}")
    # Each value is compared as the string the YAML holds, whatever
    # its shape; a bare scalar is not a string and is rejected, so
    # 'true' and true cannot pass as one value.
    for key, want in mirrored.items():
        if not isinstance(want, str):
            problems.append(
                f"{SCAN_ID} passes {key} as a bare {type(want).__name__};"
                " quote it"
            )
        elif key not in passed:
            problems.append(
                f"'{VALIDATOR}' omits {key}, which {SCAN_ID} passes as"
                f" {want!r}"
            )
        elif passed[key] != want:
            problems.append(
                f"'{VALIDATOR}' passes {key} as {passed[key]!r},"
                f" {SCAN_ID} passes {want!r}"
            )
    for key in passed:
        if key != "validate-only" and key not in mirrored and (
            key not in EXCLUDED
        ):
            problems.append(f"'{VALIDATOR}' passes {key}, which {SCAN_ID} "
                            "does not pass")
    for index, step in enumerate(validate):
        for key in sorted(reads_grype_input(step, DETECTION)):
            problems.append(
                f"{VALIDATE_JOB} step {index} reads inputs.{key} in shell;"
                " grype-scan-action owns that input"
            )
    if "continue-on-error" in validator:
        problems.append(f"'{VALIDATOR}' continues on error; a rejected"
                        " input must fail the job")
    return problems + check_fail_fast(doc)


def needs_of(job):
    """Return a job's needs as a list, however the YAML wrote them."""
    needs = job.get("needs") or []
    return [needs] if isinstance(needs, str) else list(needs)


def check_fail_fast(doc):
    """Return the problems in the lane's job graph around validation.

    A rejected input stops the lane when gerrit-validate runs first,
    unconditionally, and fails when its validator does; when every
    job that needs it directly has no status-check function in its
    if:, so GitHub skips it on that failure; and when every other
    job transitively needs one of those first-hop jobs. Nothing here
    parses an expression: the if: test is a substring test.
    """
    problems = []
    jobs = doc.get("jobs") or {}
    gate = jobs.get(VALIDATE_JOB)
    if not isinstance(gate, dict):
        return [f"job {VALIDATE_JOB} is missing"]
    for key in ("needs", "if", "continue-on-error"):
        if key in gate:
            problems.append(f"{VALIDATE_JOB} has {key}; it must run first,"
                            " always, and fail when validation does")
    others = {
        job_id: job for job_id, job in jobs.items()
        if job_id != VALIDATE_JOB and isinstance(job, dict)
    }
    for job_id, job in others.items():
        if VALIDATE_JOB not in needs_of(job):
            continue
        condition = str(job.get("if", "")).lower()
        for function in STATUS_FUNCTIONS:
            if function in condition:
                problems.append(
                    f"job {job_id} needs {VALIDATE_JOB} but its if: names"
                    f" {function}, so a rejected input would not skip it"
                )
    # A fixed point: each pass admits the jobs needing one already
    # admitted, so a cycle, or a job needing nothing, never gets in.
    reached, pending = {VALIDATE_JOB}, dict(others)
    while True:
        admitted = {
            job_id for job_id, job in pending.items()
            if any(need in reached for need in needs_of(job))
        }
        if not admitted:
            break
        reached |= admitted
        pending = {k: v for k, v in pending.items() if k not in admitted}
    for job_id in pending:
        problems.append(f"job {job_id} does not need {VALIDATE_JOB},"
                        " directly or through another job, so a rejected"
                        " input would not stop it")
    return problems


def check_lane_text(text):
    """Return the problems in the pin lines of one lane's source."""
    problems = []
    lines = [line.strip().lstrip("- ") for line in text.splitlines()
             if ACTION in line]
    uses = [line for line in lines if line.startswith("uses:")]
    if len(uses) != 2:
        problems.append(f"{ACTION} is used {len(uses)} times, expected 2")
    for line in uses:
        if line != PIN_LINE:
            problems.append(f"{line!r} is not {PIN_LINE!r}")
    return problems


def load(path):
    return yaml.safe_load(path.read_text(encoding="utf-8"))


def check_dir(root):
    failures = 0
    for name in LANES:
        path = root / name
        if not path.is_file():
            print(f"::error::{path} is missing")
            failures += 1
            continue
        text = path.read_text(encoding="utf-8")
        doc = yaml.safe_load(text)
        for problem in check_lane(name, doc) + check_lane_text(text):
            print(f"::error file={path}::{problem}")
            failures += 1
    return failures


def lane_mutants(doc):
    """Yield (label, mutated lane) for each drift the check must catch."""

    def validator(d):
        return one(steps_of(d, VALIDATE_JOB), "name", VALIDATOR, "", [])

    def scan(d):
        return one(steps_of(d, SCAN_JOB), "id", SCAN_ID, "", [])

    d = copy.deepcopy(doc)
    validator(d)["with"]["fail-on"] = "${{ inputs.grype_transitive_fail_on }}"
    yield "validator passes another expression", d
    d = copy.deepcopy(doc)
    del validator(d)["with"]["validate-only"]
    yield "validate-only removed", d
    d = copy.deepcopy(doc)
    validator(d)["with"]["validate-only"] = True
    yield "validate-only as a bare boolean", d
    d = copy.deepcopy(doc)
    validator(d)["uses"] = f"{ACTION}@{'0' * 40}"
    yield "validator pinned elsewhere", d
    d = copy.deepcopy(doc)
    scan(d)["uses"] = f"{ACTION}@{'0' * 40}"
    yield "scan pinned elsewhere", d
    d = copy.deepcopy(doc)
    validator(d)["with"]["permit-fail"] = "${{ inputs.grype_permit_fail }}"
    yield "validator shortens a compound expression", d
    d = copy.deepcopy(doc)
    scan(d)["with"]["cache-db"] = "${{ inputs.grype_cache_db }}"
    yield "scan input the validator lacks", d
    d = copy.deepcopy(doc)
    scan(d)["with"]["cache-db"] = "restore-only"
    yield "literal scan input the validator lacks", d
    d = copy.deepcopy(doc)
    scan(d)["with"]["declared-source"] = (
        "${{ inputs.grype_declared_source || 'auto' }}"
    )
    yield "compound scan input the validator lacks", d
    d = copy.deepcopy(doc)
    scan(d)["with"]["permit-fail"] = "${{ inputs.grype_permit_fail }}"
    yield "scan shortens a compound expression", d
    d = copy.deepcopy(doc)
    scan(d)["with"]["only-fixed"] = True
    validator(d)["with"]["only-fixed"] = True
    yield "a bare boolean on both sides", d
    d = copy.deepcopy(doc)
    del validator(d)["with"]["fail-on"]
    yield "validator drops an input", d
    d = copy.deepcopy(doc)
    del validator(d)["with"]["permit-fail"]
    yield "validator drops a compound expression", d
    d = copy.deepcopy(doc)
    validator(d)["with"]["sbom"] = "sbom-cyclonedx.json"
    yield "validator passes sbom", d
    d = copy.deepcopy(doc)
    validator(d)["with"]["dependencies-changed"] = ""
    yield "validator passes a runtime signal", d
    d = copy.deepcopy(doc)
    validator(d)["with"]["cache-db"] = "true"
    yield "validator passes an input the scan does not", d
    d = copy.deepcopy(doc)
    validator(d)["if"] = "inputs.grype_enabled"
    yield "validator conditional", d
    d = copy.deepcopy(doc)
    steps_of(d, VALIDATE_JOB).append(copy.deepcopy(validator(d)))
    yield "two validators", d
    d = copy.deepcopy(doc)
    steps_of(d, VALIDATE_JOB).append({
        "name": "Validate grype_fail_on input",
        "shell": "bash",
        "env": {"FAIL_ON": "${{ inputs.grype_fail_on }}"},
        "run": "test -n \"${FAIL_ON}\"",
    })
    yield "shell check of an action input", d
    d = copy.deepcopy(doc)
    steps_of(d, SCAN_JOB).append(copy.deepcopy(scan(d)))
    yield "two scans", d
    d = copy.deepcopy(doc)
    triggers(d)["workflow_call"]["inputs"]["grype_fail_on"]["default"] = "high"
    yield "input default moved", d
    d = copy.deepcopy(doc)
    del triggers(d)["workflow_call"]["inputs"]["grype_dependency_patterns"]
    yield "detection input dropped", d
    d = copy.deepcopy(doc)
    validator(d)["continue-on-error"] = True
    yield "validator continues on error", d
    d = copy.deepcopy(doc)
    d["jobs"][VALIDATE_JOB]["continue-on-error"] = True
    yield "validation job continues on error", d
    d = copy.deepcopy(doc)
    d["jobs"][VALIDATE_JOB]["if"] = "inputs.grype_enabled"
    yield "validation job conditional", d
    d = copy.deepcopy(doc)
    d["jobs"][VALIDATE_JOB]["needs"] = "repository-metadata"
    yield "validation job runs after another", d
    d = copy.deepcopy(doc)
    del d["jobs"]["build"]["needs"]
    yield "build job needs nothing", d
    d = copy.deepcopy(doc)
    d["jobs"]["build"]["needs"] = ["build"]
    yield "a job needs only itself", d
    # node-metadata needs gerrit-validate directly; it is the first hop
    d = copy.deepcopy(doc)
    d["jobs"]["node-metadata"]["if"] = "${{ always() }}"
    yield "first-hop job runs always", d
    d = copy.deepcopy(doc)
    d["jobs"]["node-metadata"]["if"] = "${{ !cancelled() }}"
    yield "first-hop job runs unless cancelled", d
    d = copy.deepcopy(doc)
    d["jobs"]["node-metadata"]["if"] = "${{ cancelled() }}"
    yield "first-hop job runs when cancelled", d
    d = copy.deepcopy(doc)
    d["jobs"]["node-metadata"]["if"] = "${{ failure() }}"
    yield "first-hop job runs on failure", d
    d = copy.deepcopy(doc)
    d["jobs"]["node-metadata"]["if"] = "${{ ALWAYS() }}"
    yield "status function in another case", d
    d = copy.deepcopy(doc)
    d["jobs"]["node-metadata"]["if"] = (
        "${{ always() || false && needs.gerrit-validate.result == 'success' }}"
    )
    yield "status function beside a success guard", d
    d = copy.deepcopy(doc)
    d["jobs"]["summary"] = {
        "runs-on": "ubuntu-latest",
        "needs": [VALIDATE_JOB, "build"],
        "if": "${{ always() }}",
        "steps": [{"run": "true"}],
    }
    yield "summary job needing the gate runs always", d


def first_hop_cases(doc):
    """Yield (label, lane) for job graphs the check must accept.

    A first-hop if: with no status-check function keeps GitHub's
    implicit guard, and a downstream job's guard on its own upstream
    is the workflow's design, out of this check's scope.
    """
    d = copy.deepcopy(doc)
    d["jobs"]["node-metadata"]["if"] = "${{ inputs.lint_enabled }}"
    yield "first-hop job guarded by an input", d
    d = copy.deepcopy(doc)
    d["jobs"]["summary"] = {
        "runs-on": "ubuntu-latest",
        "needs": ["build"],
        "if": "${{ always() }}",
        "steps": [{"run": "true"}],
    }
    yield "downstream summary job runs always", d


def merge_mutants(doc):
    """Yield (label, mutated merge lane) for the literal-value drifts.

    merge.yaml passes permit-fail as a literal, where the verify lanes
    pass a compound expression, so the literal cases live here.
    """

    def validator(d):
        return one(steps_of(d, VALIDATE_JOB), "name", VALIDATOR, "", [])

    def scan(d):
        return one(steps_of(d, SCAN_JOB), "id", SCAN_ID, "", [])

    d = copy.deepcopy(doc)
    validator(d)["with"]["permit-fail"] = "false"
    yield "validator passes another literal", d
    d = copy.deepcopy(doc)
    del validator(d)["with"]["permit-fail"]
    yield "validator drops a literal", d
    d = copy.deepcopy(doc)
    scan(d)["with"]["cache-db"] = "false"
    yield "literal scan input the validator lacks", d
    d = copy.deepcopy(doc)
    validator(d)["with"]["artifact-name"] = "grype-scan-results-node-merge"
    yield "validator passes an output-only input", d


def lane_text_mutants(text):
    """Yield (label, mutated source) for each pin drift to catch."""
    yield "pin comment names another release", text.replace(
        "# v0.6.2", "# v0.6.1", 1
    )
    yield "a third use of the action", text + (
        f"\n      - uses: {USES}  # v0.6.2\n"
    )


def self_test(root):
    """Expect every mutant to fail; return the number that escaped."""
    escaped = total = 0
    name = "build-test.yaml"
    text = (root / name).read_text(encoding="utf-8")
    doc = yaml.safe_load(text)
    for label, mutant in lane_mutants(doc):
        total += 1
        # Through a dump and a load, as a file would be read
        if not check_lane(name, yaml.safe_load(yaml.safe_dump(mutant))):
            escaped += 1
            print(f"::error::mutant not caught: {label}")
    for label, lane in first_hop_cases(doc):
        total += 1
        found = check_fail_fast(yaml.safe_load(yaml.safe_dump(lane)))
        if found:
            escaped += 1
            print(f"::error::{label}: rejected: {found}")
    merge = load(root / "merge.yaml")
    for label, mutant in merge_mutants(merge):
        total += 1
        if not check_lane(
            "merge.yaml", yaml.safe_load(yaml.safe_dump(mutant))
        ):
            escaped += 1
            print(f"::error::mutant not caught: {label}")
    for label, mutant in lane_text_mutants(text):
        total += 1
        if not check_lane_text(mutant):
            escaped += 1
            print(f"::error::mutant not caught: {label}")
    print(f"Mutants caught: {total - escaped}/{total}")
    return escaped


root = pathlib.Path(sys.argv[1])
failures = check_dir(root)
if failures:
    print(f"{failures} problem(s) in the Grype input validation ❌")
    sys.exit(1)
print("Every lane validates its Grype inputs through the action ✅")
if self_test(root):
    sys.exit(1)
PYEOF
