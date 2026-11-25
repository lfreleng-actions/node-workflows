# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

"""Check agreement and release floors for action pins in workflow sources."""

import re
from collections.abc import Callable, Iterator, Sequence
from typing import NamedTuple, Protocol

SHA = re.compile(r"[0-9a-f]{40}")
VERSION = re.compile(r"[ \t]+# v([0-9]+)\.([0-9]+)\.([0-9]+)[ \t]*")


class Mark(Protocol):
    """Source coordinates supplied by the YAML composer."""

    index: int
    line: int
    column: int


class Node(Protocol):
    """The subset of a composed YAML node used by this check."""

    value: str | Sequence["Node | tuple[Node, Node]"]
    start_mark: Mark
    end_mark: Mark


class Call(NamedTuple):
    """Source location of a uses scalar, plus its ref and inline comment."""

    file: str
    line: int
    start: int
    end: int
    ref: str
    comment: str


def children(node: Node | None) -> Sequence[Node | tuple[Node, Node]]:
    return node.value if node and not isinstance(node.value, str) else ()


def field(node: Node | None, key: str) -> Node | None:
    return next(
        (
            pair[1]
            for pair in children(node)
            if isinstance(pair, tuple) and pair[0].value == key
        ),
        None,
    )


def action_calls(
    sources: dict[str, str], action: str, compose: Callable[[str], Node | None]
) -> Iterator[Call]:
    """Find real calls, ignoring mentions in comments and run blocks."""
    for file, text in sources.items():
        lines = text.splitlines()
        for pair in children(field(compose(text), "jobs")):
            if not isinstance(pair, tuple):
                continue
            job = pair[1]
            for entry in (job, *children(field(job, "steps"))):
                if isinstance(entry, tuple):
                    continue
                uses = field(entry, "uses")
                if uses is None or not isinstance(uses.value, str):
                    continue
                name, _, ref = uses.value.partition("@")
                if name.lower() != action:
                    continue
                start = uses.start_mark
                end = uses.end_mark
                # Only a comment on the uses line documents its pin.
                comment = (
                    lines[end.line][end.column :] if start.line == end.line else ""
                )
                yield Call(file, start.line + 1, start.index, end.index, ref, comment)


def pin_errors(
    calls: list[Call], action: str, floor: tuple[int, int, int]
) -> list[str]:
    """Require one full SHA and a version at or above the floor."""
    if not calls:
        return [f"{action} has no calls"]
    errors: list[str] = []
    if len({call.ref for call in calls}) != 1:
        errors.append("pins disagree")
    if any(not SHA.fullmatch(call.ref) for call in calls):
        errors.append("expected a full lowercase commit SHA")
    versions = [VERSION.fullmatch(call.comment) for call in calls]
    if any(version is None for version in versions):
        errors.append("expected an inline # vX.Y.Z comment")
    if any(
        version and tuple(map(int, version.groups())) < floor for version in versions
    ):
        errors.append(f"version is below v{'.'.join(map(str, floor))}")
    if not errors:
        return []
    sites = "; ".join(
        f"{call.file}:{call.line} @{call.ref or '<missing>'}{call.comment}"
        for call in calls
    )
    return [f"{action}: {', '.join(errors)}; calls: {sites}"]


def pin_cases(
    sources: dict[str, str], calls: list[Call], action: str
) -> Iterator[tuple[str, dict[str, str], bool]]:
    """Rewrite real calls to exercise accepted and rejected pin changes."""

    def replace(selected: list[Call], pin: str) -> dict[str, str]:
        rewritten = sources.copy()
        for call in sorted(selected, key=lambda call: call.start, reverse=True):
            text = rewritten[call.file]
            end = call.end + len(call.comment)
            rewritten[call.file] = text[: call.start] + f"{action}@{pin}" + text[end:]
        return rewritten

    first = calls[0]
    # Synthetic refs and release comments: no dependence on today's pin.
    another_sha = ("1" if first.ref[0] == "0" else "0") + first.ref[1:]
    current = max(
        tuple(map(int, call.comment.split("v")[1].split("."))) for call in calls
    )
    newer = f"v{current[0]}.{current[1]}.{current[2] + 1}"
    yield "coordinated bump", replace(calls, f"{another_sha}  # {newer}"), True
    yield "pins disagree", replace([first], f"{another_sha}{first.comment}"), False
    yield "tag instead of SHA", replace(calls, f"{newer}  # {newer}"), False
    yield "short SHA", replace(calls, f"{another_sha[:7]}  # {newer}"), False
    yield "no version comment", replace(calls, another_sha), False
    yield "version below floor", replace(calls, f"{another_sha}  # v0.0.0"), False
