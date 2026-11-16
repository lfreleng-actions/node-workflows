#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Tests for .github/workflows/bundle-check.yaml that need no live
# Dependabot pull request.
#
# The script lifts each shell step out of the workflow and runs it as
# the runner would (bash -eo pipefail, with the step's env and the
# GITHUB_OUTPUT, GITHUB_STEP_SUMMARY and RUNNER_TEMP files), against
# a throwaway git repository holding a small npm project whose build
# writes dist/. It covers:
#
# - input validation;
# - a fresh bundle passing, and a stale one reporting each file to
#   add, change or delete, from a build that leaves old output in
#   place and in a repository that ignores its force-added bundle;
# - every repair condition: event, pull request author, fork, the
#   repair switch, and a run of rebuild commits at the head that
#   already holds a rebuild of the same bundle directory (an A/B/A
#   loop), not of another one, or that runs past the fetched history;
# - the repair job's App key check: the dry-run switch, a missing key
#   (including the run the App's rebuild push triggers, which reads
#   Actions secrets) and a key without a client ID;
# - staging refusing an executable file, new or committed, since
#   createCommitOnBranch cannot set a file mode;
# - the repair job's artefact validation, which must refuse a
#   symlink, a path outside the bundle directory, an oversized file,
#   a stale head SHA, an unlisted file, and a bundle directory other
#   than the one the inputs name, even when the check job's forged
#   output agrees with the manifest;
# - the createCommitOnBranch request: additions, deletions,
#   expectedHeadOid and message, as the dry run reports it; and that
#   applying it leaves a bundle the check passes;
# - the workflow's shape: permissions, pins, the steps a dry run or
#   a missing key skips, that a forged repair output cannot run the
#   repair job with repair switched off, that the check job
#   references no secret, and that no script interpolates an
#   expression.
#
# Needs python3 with PyYAML, git and npm. Run from the repository root:
#   bash tests/test-bundle-check.sh

set -euo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
import base64
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

import yaml

WORKFLOW = '.github/workflows/bundle-check.yaml'
SHA_RE = re.compile(r'^[0-9a-f]{40}$')

with open(WORKFLOW) as handle:
    TEXT = handle.read()
DOC = yaml.safe_load(TEXT)
JOBS = DOC['jobs']
failures = []


def check(condition, message):
    if condition:
        print(f'  ok: {message}')
    else:
        print(f'  FAIL: {message}')
        failures.append(message)


def step(job, name):
    found = [s for s in JOBS[job]['steps'] if s.get('name') == name]
    if len(found) != 1:
        sys.exit(f'{job} has {len(found)} steps named {name!r}')
    return found[0]


def run_step(job, name, env, cwd, temp):
    """Run one step's script; return (exit code, outputs, output)."""
    script = os.path.join(temp, 'step.sh')
    with open(script, 'w') as handle:
        handle.write(step(job, name)['run'])
    outputs = os.path.join(temp, 'outputs.txt')
    summary = os.path.join(temp, 'summary.md')
    open(outputs, 'w').close()
    full = {
        'PATH': os.environ['PATH'],
        'HOME': os.environ.get('HOME', temp),
        'RUNNER_TEMP': temp,
        'GITHUB_OUTPUT': outputs,
        'GITHUB_STEP_SUMMARY': summary,
        'npm_config_update_notifier': 'false',
    }
    full.update(env)
    result = subprocess.run(
        ['bash', '--noprofile', '--norc', '-eo', 'pipefail', script],
        cwd=cwd, env=full, capture_output=True, text=True,
    )
    values = {}
    with open(outputs) as handle:
        for line in handle:
            key, _, value = line.rstrip('\n').partition('=')
            values[key] = value
    return result.returncode, values, result.stdout + result.stderr


def git(cwd, *args):
    return subprocess.run(
        ['git', '-c', 'user.name=Test', '-c', 'user.email=t@example.com',
         *args],
        cwd=cwd, check=True, capture_output=True, text=True,
    ).stdout.strip()


def evaluate(condition, context):
    """Evaluate a job condition built from && clauses, as GitHub would.

    Handles only the clause forms the repair job uses: !cancelled(), a
    bare context value, and a comparison with a literal or a context
    value.
    """
    def value(term):
        term = term.strip()
        if term.startswith("'") and term.endswith("'"):
            return term[1:-1]
        return context[term]

    for clause in condition.split('&&'):
        clause = clause.strip()
        if clause == '!cancelled()':
            continue
        if '==' in clause:
            left, right = clause.split('==')
            if str(value(left)) != str(value(right)):
                return False
        elif not value(clause):
            return False
    return True


print('Workflow shape')
check(JOBS['check']['name'] == 'Committed bundle matches sources 📦',
      'the check job keeps its required-check name')
check(JOBS['check']['permissions'] == {'contents': 'read'},
      'the check job reads contents only')
check(JOBS['repair']['permissions'] == {},
      'the repair job holds no GITHUB_TOKEN permission')
checkout = step('check', 'Checkout repository')
check(checkout['with'].get('persist-credentials') is False,
      'the check job does not persist checkout credentials')
repair_steps = JOBS['repair']['steps']
check(not any('checkout' in str(s.get('uses', '')) for s in repair_steps),
      'the repair job checks nothing out')
check(not any(re.search(r'^\s*(npm|npx|node)\s', s.get('run', ''), re.M)
              for s in repair_steps),
      'the repair job runs no npm')
condition = JOBS['repair']['if']
for needle in ("needs.check.outputs.repair == 'true'",
               'inputs.repair_enabled',
               "github.event_name == 'pull_request'",
               "github.event.pull_request.user.login == 'dependabot[bot]'",
               'github.event.pull_request.head.repo.full_name == '
               'github.repository'):
    check(needle in condition, f'the repair job requires {needle}')
# The build can forge the check job's outputs, so the repair job must
# not run on a forged repair=true when the caller switched repair off
forged = {
    'needs.check.outputs.repair': 'true',
    'inputs.repair_enabled': True,
    'github.event_name': 'pull_request',
    'github.event.pull_request.user.login': 'dependabot[bot]',
    'github.event.pull_request.head.repo.full_name': 'org/repo',
    'github.repository': 'org/repo',
}
check(evaluate(condition, forged),
      'the repair job runs on a same-repository Dependabot repair')
check(not evaluate(condition, {**forged, 'inputs.repair_enabled': False}),
      'a forged repair=true does not run the repair job with repair off')
check(checkout['with'].get('fetch-depth', 1) > 1,
      'the check job fetches history for the loop guard')
token = step('repair', 'Mint App token')
permissions = {k for k in token['with'] if k.startswith('permission-')}
check(permissions == {'permission-contents'}
      and token['with']['permission-contents'] == 'write',
      'the App token asks for contents: write alone')
check(token['with'].get('repositories')
      == '${{ github.event.repository.name }}',
      'the App token is scoped to the calling repository')
check(JOBS['repair']['steps'][2]['name'] == 'Check App key',
      'the repair job checks the App key before it touches the artefact')
for name in ('Mint App token', 'Resolve commit author',
             'Commit rebuilt bundle'):
    check(step('repair', name).get('if')
          == "steps.key.outputs.commit == 'true'",
          f'a dry run or a missing key skips {name!r}')
for name in ('Download rebuilt bundle', 'Validate rebuilt bundle',
             'Build commit request'):
    check(step('repair', name).get('if')
          == "steps.key.outputs.proceed == 'true'",
          f'a missing key outside a dry run skips {name!r}')
# GitHub sends a runner each secret its job references, and the check
# job runs dependency code, so no part of it may name a secret
check(not re.search(r'\bsecrets\s*[.\[]', json.dumps(JOBS['check'])),
      'the check job references no secret')
check(re.search(r'\bsecrets\s*[.\[]', json.dumps(JOBS['repair'])),
      'the repair job reads the App key')
for job_id, job in JOBS.items():
    for item in job['steps']:
        if '${{' in item.get('run', ''):
            check(False, f'{job_id}/{item["name"]} interpolates an '
                  'expression into its script')
uses = re.findall(r'uses: (\S+)(.*)', TEXT)
check(bool(uses) and all(
    re.fullmatch(r'[^@]+@[0-9a-f]{40}', ref)
    and re.fullmatch(r'\s+# v\d+\.\d+\.\d+', comment)
    for ref, comment in uses),
    'every action is pinned to a commit SHA with a # vX.Y.Z comment')


def fixture(root, ignore_dist=False):
    """An npm project whose build writes dist/ from src/.

    The build never removes old output, as with many bundlers, so a
    file it stops writing goes away only because the workflow clears
    the bundle directory first. With ignore_dist, .gitignore covers
    dist/ and the bundle is force-added.
    """
    os.makedirs(os.path.join(root, 'src'))
    with open(os.path.join(root, 'package.json'), 'w') as handle:
        json.dump({'name': 'fixture', 'version': '1.0.0', 'private': True,
                   'scripts': {'build': 'node build.js'}}, handle)
    with open(os.path.join(root, 'package-lock.json'), 'w') as handle:
        json.dump({'name': 'fixture', 'version': '1.0.0',
                   'lockfileVersion': 3, 'requires': True,
                   'packages': {'': {'name': 'fixture',
                                     'version': '1.0.0'}}}, handle)
    with open(os.path.join(root, 'build.js'), 'w') as handle:
        handle.write(
            "const fs = require('fs');\n"
            "const src = fs.readFileSync('src/version.txt', 'utf8');\n"
            "fs.mkdirSync('dist/lib', { recursive: true });\n"
            "fs.writeFileSync('dist/index.js', 'v=' + src);\n"
            "if (src.trim() !== '1') {\n"
            "  fs.writeFileSync('dist/lib/new.js', 'new ' + src);\n"
            "} else {\n"
            "  fs.writeFileSync('dist/old.js', 'old');\n"
            "}\n"
        )
    with open(os.path.join(root, 'src', 'version.txt'), 'w') as handle:
        handle.write('1\n')
    with open(os.path.join(root, '.gitignore'), 'w') as handle:
        handle.write('node_modules/\n' + ('dist/\n' if ignore_dist else ''))
    git(root, 'init', '-q', '-b', 'main')
    subprocess.run(['node', 'build.js'], cwd=root, check=True)
    git(root, 'add', '-A')
    if ignore_dist:
        git(root, 'add', '-f', 'dist')
    git(root, 'commit', '-q', '-m', 'Initial')


temp = tempfile.mkdtemp()
try:
    repo = os.path.join(temp, 'repo')
    runner = os.path.join(temp, 'runner')
    os.makedirs(runner)
    fixture(repo)

    print('Input validation')
    good = {
        'NODE_VERSION': '22', 'BUILD_SCRIPT': 'build',
        'BUNDLE_PATH': 'dist', 'PATH_PREFIX': '.', 'APP_CLIENT_ID': '',
        'ARTIFACT_SUFFIX': '',
    }
    rc, out, _ = run_step('check', 'Validate inputs', good, repo, runner)
    check(rc == 0 and out.get('bundle_dir') == 'dist',
          'the defaults resolve bundle_dir to dist')
    rc, out, _ = run_step('check', 'Validate inputs',
                          {**good, 'PATH_PREFIX': 'packages/action',
                           'BUNDLE_PATH': './dist/'}, repo, runner)
    check(rc == 0 and out.get('bundle_dir') == 'packages/action/dist',
          'path_prefix joins bundle_path')
    for key, value in (('BUNDLE_PATH', '../dist'),
                       ('BUNDLE_PATH', '/dist'),
                       ('BUNDLE_PATH', '.'),
                       ('BUNDLE_PATH', 'dist; rm -rf /'),
                       ('PATH_PREFIX', 'a/../..'),
                       ('BUILD_SCRIPT', 'build && curl x'),
                       ('NODE_VERSION', '22 $(id)'),
                       ('ARTIFACT_SUFFIX', '/x'),
                       ('APP_CLIENT_ID', 'id\nx')):
        rc, _, _ = run_step('check', 'Validate inputs',
                            {**good, key: value}, repo, runner)
        check(rc != 0, f'{key} {value!r} is refused')

    build = {'PATH_PREFIX': '.', 'BUILD_SCRIPT': 'build',
             'BUNDLE_DIR': 'dist'}
    compare = {'BUNDLE_DIR': 'dist'}

    print('Fresh and stale bundles')
    rc, _, log = run_step('check', 'Build bundle', build, repo, runner)
    check(rc == 0, 'the build step runs npm ci and the build script')
    if rc != 0:
        print(log)
    rc, out, _ = run_step('check', 'Compare bundle', compare, repo, runner)
    check(rc == 0 and out.get('stale') == 'false',
          'a fresh bundle passes')
    base = git(repo, 'rev-parse', 'HEAD')
    check(out.get('head_sha') == base, 'the check reports its head SHA')

    with open(os.path.join(repo, 'src', 'version.txt'), 'w') as handle:
        handle.write('2\n')
    git(repo, 'commit', '-q', '-am', 'Bump source without rebuilding')
    head = git(repo, 'rev-parse', 'HEAD')
    run_step('check', 'Build bundle', build, repo, runner)
    rc, out, log = run_step('check', 'Compare bundle', compare, repo,
                            runner)
    check(rc == 0 and out.get('stale') == 'true', 'a stale bundle is stale')
    check(out.get('head_sha') == head, 'it was built from the head commit')
    check('is stale' in log and "'dist/old.js'" in log,
          'the stale report names the files')
    with open(os.path.join(runner, 'bundle-changes.json')) as handle:
        changes = json.load(handle)
    check(changes['additions'] == ['dist/index.js', 'dist/lib/new.js'],
          'changed and new files count as additions')
    check(changes['deletions'] == ['dist/old.js'],
          'a file the build no longer writes counts as a deletion, '
          'though the build leaves old output in place')
    rc, _, _ = run_step('check', 'Fail on a stale bundle',
                        {'REPAIR': 'true'}, repo, runner)
    check(rc != 0, 'the check fails on a stale bundle, repair or not')

    print('An ignored bundle directory')
    ignored = os.path.join(temp, 'ignored')
    ignored_runner = os.path.join(temp, 'ignored-runner')
    os.makedirs(ignored_runner)
    fixture(ignored, ignore_dist=True)
    with open(os.path.join(ignored, 'src', 'version.txt'), 'w') as fh:
        fh.write('2\n')
    git(ignored, 'commit', '-q', '-am', 'Bump source without rebuilding')
    run_step('check', 'Build bundle', build, ignored, ignored_runner)
    rc, out, _ = run_step('check', 'Compare bundle', compare, ignored,
                          ignored_runner)
    with open(os.path.join(ignored_runner, 'bundle-changes.json')) as fh:
        ignored_changes = json.load(fh)
    check(rc == 0 and out.get('stale') == 'true'
          and ignored_changes['additions']
          == ['dist/index.js', 'dist/lib/new.js']
          and ignored_changes['deletions'] == ['dist/old.js'],
          'a new file under an ignored, force-added bundle counts')

    print('Repair conditions')
    applies = {
        'EVENT_NAME': 'pull_request', 'PR_AUTHOR': 'dependabot[bot]',
        'HEAD_REPO': 'org/repo', 'BASE_REPO': 'org/repo',
        'REPAIR_ENABLED': 'true', 'BUNDLE_DIR': 'dist',
    }
    cases = [
        ('a same-repository Dependabot pull request', {}, 'true'),
        ('a push', {'EVENT_NAME': 'push', 'PR_AUTHOR': ''}, 'false'),
        ('another author', {'PR_AUTHOR': 'octocat'}, 'false'),
        ('a fork', {'HEAD_REPO': 'fork/repo'}, 'false'),
        ('a deleted fork', {'HEAD_REPO': ''}, 'false'),
        ('repair switched off', {'REPAIR_ENABLED': 'false'}, 'false'),
    ]
    for label, override, want in cases:
        rc, out, _ = run_step('check', 'Decide repair',
                              {**applies, **override}, repo, runner)
        check(rc == 0 and out.get('repair') == want,
              f'{label}: repair={want}')
    _, _, log = run_step('check', 'Decide repair',
                         {**applies, 'PR_AUTHOR': 'octocat'}, repo, runner)
    check('::notice::No automatic rebuild: the pull request author is '
          'octocat, not dependabot[bot]\n' in log,
          'a reason prints as one notice')

    print('App key (repair job)')
    key = {'HAS_KEY': 'true', 'APP_CLIENT_ID': 'Iv1.abc',
           'DRY_RUN': 'false', 'ACTOR': 'dependabot[bot]'}
    key_cases = [
        ('a key and a client ID', {}, 'true', 'true'),
        ('a dry run with a key', {'DRY_RUN': 'true'}, 'true', 'false'),
        ('a dry run with no key', {'HAS_KEY': 'false', 'DRY_RUN': 'true',
                                   'APP_CLIENT_ID': ''}, 'true', 'false'),
        ('no key', {'HAS_KEY': 'false'}, 'false', 'false'),
    ]
    for label, override, proceed, commit in key_cases:
        rc, out, _ = run_step('repair', 'Check App key',
                              {**key, **override}, repo, runner)
        check(rc == 0 and out.get('proceed') == proceed
              and out.get('commit') == commit,
              f'{label}: proceed={proceed}, commit={commit}')
    rc, _, log = run_step('repair', 'Check App key',
                          {**key, 'APP_CLIENT_ID': ''}, repo, runner)
    check(rc != 0 and 'app_client_id is empty' in log,
          'a private key without a client ID is refused')
    rc, _, log = run_step('repair', 'Check App key',
                          {**key, 'HAS_KEY': 'false'}, repo, runner)
    check('::notice::No automatic rebuild: no APP_PRIVATE_KEY secret is '
          'set, so this workflow checks only.\n' in log,
          'no key prints one checks-only notice')
    # The App's rebuild push triggers a run that reads Actions secrets,
    # so a key stored only as a Dependabot secret is missing there
    rc, out, log = run_step('repair', 'Check App key',
                            {**key, 'HAS_KEY': 'false',
                             'ACTOR': 'lf-releng-bot[bot]'}, repo, runner)
    check(rc == 0 and out.get('proceed') == 'false'
          and 'reads Actions secrets' in log,
          'the App-triggered run with no Actions secret names the cause')

    print('Staging and artefact validation')
    # createCommitOnBranch cannot set a file mode, so staging refuses a
    # rebuild that needs one rather than commit a bundle still stale
    new_js = os.path.join(repo, 'dist', 'lib', 'new.js')
    os.chmod(new_js, 0o755)
    rc, _, log = run_step('check', 'Stage rebuilt bundle', compare, repo,
                          runner)
    check(rc != 0 and "'dist/lib/new.js' is or was executable" in log,
          'staging refuses a new executable file')
    os.chmod(new_js, 0o644)
    exec_repo = os.path.join(temp, 'exec')
    exec_runner = os.path.join(temp, 'exec-runner')
    os.makedirs(exec_runner)
    shutil.copytree(repo, exec_repo, symlinks=True)
    git(exec_repo, 'update-index', '--chmod=+x', 'dist/index.js')
    git(exec_repo, 'commit', '-q', '-m', 'Make index.js executable')
    run_step('check', 'Compare bundle', compare, exec_repo, exec_runner)
    rc, _, log = run_step('check', 'Stage rebuilt bundle', compare,
                          exec_repo, exec_runner)
    check(rc != 0 and "'dist/index.js' is or was executable" in log,
          'staging refuses a change to a committed executable file')
    rc, _, log = run_step('check', 'Stage rebuilt bundle', compare, repo,
                          runner)
    check(rc == 0, 'the rebuilt bundle stages')
    stage = os.path.join(runner, 'bundle-repair')
    with open(os.path.join(stage, 'manifest.json')) as handle:
        manifest = json.load(handle)
    check(manifest == {'schema': 1, 'head_sha': head, 'bundle_dir': 'dist',
                       'additions': changes['additions'],
                       'deletions': changes['deletions']},
          'the manifest names the head SHA, additions and deletions')

    validate = {'ARTIFACT_DIR': stage, 'PATH_PREFIX': '.',
                'BUNDLE_PATH': 'dist', 'EXPECTED_HEAD_SHA': head}
    rc, out, log = run_step('repair', 'Validate rebuilt bundle', validate,
                            repo, runner)
    check(rc == 0 and out.get('root') == stage, 'a sound artefact passes')
    if rc != 0:
        print(log)
    nested = os.path.join(temp, 'nested')
    shutil.copytree(stage, os.path.join(nested, 'bundle-repair'))
    rc, out, _ = run_step('repair', 'Validate rebuilt bundle',
                          {**validate, 'ARTIFACT_DIR': nested}, repo,
                          runner)
    check(rc == 0 and out.get('root')
          == os.path.join(nested, 'bundle-repair'),
          'an artefact one directory down passes')

    def bad_copy(label, mutate, want, env=None):
        copy = os.path.join(temp, 'bad')
        shutil.rmtree(copy, ignore_errors=True)
        shutil.copytree(stage, copy, symlinks=True)
        data = json.loads(json.dumps(manifest))
        mutate(copy, data)
        with open(os.path.join(copy, 'manifest.json'), 'w') as handle:
            json.dump(data, handle)
        rc, _, log = run_step('repair', 'Validate rebuilt bundle',
                              {**validate, 'ARTIFACT_DIR': copy,
                               **(env or {})}, repo, runner)
        check(rc != 0 and 'Refusing' in log and want in log,
              f'refuses {label}')

    def symlink(copy, data):
        target = os.path.join(copy, 'files', 'dist', 'index.js')
        os.remove(target)
        os.symlink('/etc/passwd', target)

    def symlink_dir(copy, data):
        os.symlink('/etc', os.path.join(copy, 'files', 'dist', 'etc'))

    def outside(copy, data):
        os.makedirs(os.path.join(copy, 'files', 'src'))
        with open(os.path.join(copy, 'files', 'src', 'x.js'), 'w') as fh:
            fh.write('x')
        data['additions'].append('src/x.js')

    def dotdot(copy, data):
        data['deletions'].append('dist/../build.js')

    def oversized(copy, data):
        path = os.path.join(copy, 'files', 'dist', 'index.js')
        with open(path, 'wb') as handle:
            handle.truncate(11 * 1024 * 1024)

    def too_large(copy, data):
        for index in range(3):
            name = f'dist/big{index}.js'
            with open(os.path.join(copy, 'files', name), 'wb') as handle:
                handle.truncate(8 * 1024 * 1024)
            data['additions'].append(name)

    def too_many(copy, data):
        data['deletions'] = [f'dist/gone{i}.js' for i in range(1001)]

    def unlisted(copy, data):
        with open(os.path.join(copy, 'files', 'dist', 'x.js'), 'w') as fh:
            fh.write('x')

    def stray(copy, data):
        with open(os.path.join(copy, 'run.sh'), 'w') as handle:
            handle.write('x')

    def stale_head(copy, data):
        data['head_sha'] = base

    def both(copy, data):
        data['deletions'].append('dist/index.js')

    bad_copy('a symlinked file', symlink, 'not a regular file')
    bad_copy('a symlinked directory', symlink_dir, 'not a regular file')
    bad_copy('a path outside the bundle directory', outside,
             'not a path inside dist/')
    bad_copy('a path climbing out with ..', dotdot,
             'not a path inside dist/')
    bad_copy('a file over the per-file limit', oversized, 'for one file')
    bad_copy('an artefact over the total limit', too_large,
             '-byte limit')
    bad_copy('more files than the limit', too_many, 'over the limit')
    bad_copy('a file the manifest does not list', unlisted, 'unlisted')
    bad_copy('an entry outside files/', stray, 'unexpected entries')
    bad_copy('a build from another commit', stale_head, 'was built from')
    bad_copy('a path both added and deleted', both,
             'both added and deleted')
    bad_copy('another bundle directory', lambda c, d: None,
             'names bundle directory', {'BUNDLE_PATH': 'lib'})
    bad_copy('a bundle outside the path prefix', lambda c, d: None,
             'names bundle directory', {'PATH_PREFIX': 'packages/a'})

    def forged_src(copy, data):
        shutil.rmtree(os.path.join(copy, 'files', 'dist'))
        os.makedirs(os.path.join(copy, 'files', 'src'))
        with open(os.path.join(copy, 'files', 'src', 'x.js'), 'w') as fh:
            fh.write('x')
        data.update(bundle_dir='src', additions=['src/x.js'],
                    deletions=[])

    # The build can forge the check job's outputs; a forged bundle_dir
    # output and a manifest that agree on src must still be refused
    bad_copy('a forged bundle directory', forged_src,
             "names bundle directory 'src', not 'dist'",
             {'BUNDLE_DIR': 'src'})
    for key, value in (('BUNDLE_PATH', '../src'), ('BUNDLE_PATH', '.'),
                       ('PATH_PREFIX', '/'), ('BUNDLE_PATH', 'a b')):
        rc, _, log = run_step('repair', 'Validate rebuilt bundle',
                              {**validate, key: value}, repo, runner)
        check(rc != 0 and 'Refusing' in log,
              f'refuses {key.lower()} {value!r}')
    validate_env = step('repair', 'Validate rebuilt bundle')['env']
    check(not any('needs.check.outputs' in str(v)
                  for v in validate_env.values()),
          'the repair boundary comes from inputs, not check outputs')

    print('Commit request (dry run)')
    signoff = 'bot[bot] <1+bot[bot]@users.noreply.github.com>'
    request_env = {'MANIFEST_ROOT': stage, 'REPOSITORY': 'org/repo',
                   'BRANCH': 'dependabot/npm_and_yarn/x-1.2.3',
                   'BUILD_SCRIPT': 'build', 'SIGNOFF': ''}
    rc, _, log = run_step('repair', 'Build commit request', request_env,
                          repo, runner)
    check(rc == 0 and f'expected head {head}' in log
          and 'delete: dist/old.js' in log,
          'the dry run reports the commit it would make')
    rc, _, _ = run_step('repair', 'Build commit request',
                        {**request_env, 'SIGNOFF': signoff}, repo, runner)
    with open(os.path.join(runner, 'bundle-commit-request.json')) as fh:
        request = json.load(fh)
    data = request['variables']['input']
    check('createCommitOnBranch' in request['query'],
          'the request calls createCommitOnBranch')
    check(data['expectedHeadOid'] == head,
          'expectedHeadOid is the SHA the check built from')
    check(data['branch'] == {'repositoryNameWithOwner': 'org/repo',
                             'branchName': request_env['BRANCH']},
          'the request names the pull request branch')
    added = {item['path']: base64.b64decode(item['contents']).decode()
             for item in data['fileChanges']['additions']}
    check(added == {'dist/index.js': 'v=2\n', 'dist/lib/new.js': 'new 2\n'},
          'additions carry the rebuilt contents')
    check(data['fileChanges']['deletions'] == [{'path': 'dist/old.js'}],
          'deletions name the removed file')
    message = data['message']
    check(message['headline'] == 'Build: Rebuild committed bundle',
          'the subject is a Conventional Commit')
    check('[dependabot skip]' in message['body'],
          'the body carries [dependabot skip]')
    check(message['body'].endswith(f'Bundle-Rebuilt-From: {head}\n'
                                   'Bundle-Rebuilt-Path: dist\n'
                                   f'Signed-off-by: {signoff}'),
          'the body ends with the rebuild markers and sign-off')
    check(all(len(line) <= 72 for line in message['body'].splitlines()),
          'the body wraps at 72 characters')
    rc, _, _ = run_step('repair', 'Build commit request',
                        {**request_env, 'BRANCH': 'a\nb'}, repo, runner)
    check(rc != 0, 'an unexpected branch name is refused')

    print('After the rebuild commit')
    for path, contents in added.items():
        with open(os.path.join(repo, path), 'w') as handle:
            handle.write(contents)
    git(repo, 'rm', '-q', 'dist/old.js')
    git(repo, 'add', '-A')
    git(repo, 'commit', '-q', '-m',
        message['headline'] + '\n\n' + message['body'])
    run_step('check', 'Build bundle', build, repo, runner)
    rc, out, _ = run_step('check', 'Compare bundle', compare, repo, runner)
    check(rc == 0 and out.get('stale') == 'false',
          'the rebuild commit passes the check, ending the loop')
    with open(os.path.join(repo, 'dist', 'index.js'), 'a') as handle:
        handle.write('drift\n')
    rc, out, log = run_step('check', 'Decide repair', applies, repo, runner)
    check(rc == 0 and out.get('repair') == 'false'
          and 'not deterministic' in log,
          'a stale rebuild commit reports a non-deterministic build')
    # A caller checking two bundles: the rebuild of dist/ landed first
    # and moved the head, so the repair of the other bundle failed on
    # expectedHeadOid. That bundle has not been rebuilt yet.
    app_run = {**applies, 'BUNDLE_DIR': 'packages/b/dist'}
    rc, out, log = run_step('check', 'Decide repair', app_run, repo, runner)
    check(rc == 0 and out.get('repair') == 'true'
          and 'not deterministic' not in log,
          'a rebuild of another bundle does not stop this one\'s repair')
    rc, out, log = run_step('check', 'Decide repair',
                            {**applies, 'BUNDLE_DIR': 'dis'}, repo, runner)
    check(rc == 0 and out.get('repair') == 'true',
          'the bundle directory marker must match in full')

    # Two non-deterministic bundles: dist/ was rebuilt, then
    # packages/b/dist on top. Without a guard over the whole run of
    # rebuild commits, dist/ would repair again, then b, and so on.
    git(repo, 'commit', '-q', '--allow-empty', '-m',
        'Build: Rebuild committed bundle\n\n'
        f'Bundle-Rebuilt-From: {head}\n'
        'Bundle-Rebuilt-Path: packages/b/dist')
    for bundle in ('dist', 'packages/b/dist'):
        rc, out, log = run_step('check', 'Decide repair',
                                {**applies, 'BUNDLE_DIR': bundle},
                                repo, runner)
        check(rc == 0 and out.get('repair') == 'false'
              and 'not deterministic' in log,
              f'after rebuilds of dist and b, {bundle} does not repair '
              'again')
    rc, out, _ = run_step('check', 'Decide repair',
                          {**applies, 'BUNDLE_DIR': 'packages/c/dist'},
                          repo, runner)
    check(rc == 0 and out.get('repair') == 'true',
          'a bundle with no rebuild in the run still repairs')

    shallow = os.path.join(temp, 'shallow')
    subprocess.run(['git', 'clone', '-q', '--depth', '1',
                    f'file://{repo}', shallow],
                   check=True, capture_output=True)
    rc, out, log = run_step('check', 'Decide repair',
                            {**applies, 'BUNDLE_DIR': 'packages/c/dist'},
                            shallow, runner)
    check(rc == 0 and out.get('repair') == 'false'
          and 'cannot see where' in log,
          'a history holding rebuild commits alone stops the repair')

    git(repo, 'commit', '-q', '--allow-empty', '-m', 'Bump again')
    rc, out, _ = run_step('check', 'Decide repair', applies, repo, runner)
    check(rc == 0 and out.get('repair') == 'true',
          'a commit that is not a rebuild ends the run of rebuilds')
finally:
    shutil.rmtree(temp, ignore_errors=True)

if failures:
    print(f'{len(failures)} bundle-check test(s) failed ❌')
    sys.exit(1)
print('All bundle-check tests passed ✅')
PY
