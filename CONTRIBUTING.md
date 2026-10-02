# Contributing

This is an experimental Foreman community project. The normal Foreman
contribution model is the baseline; this file adds only the repository-specific
rules needed to keep Kubernetes orchestration separate from application code.

## Start a change

A focused pull request is sufficient when the motivation, behavior, and test
evidence fit in its description. Opening a duplicate issue immediately before
the pull request is not required. Use an issue or a design discussion first
when the change affects public APIs, release ownership, compatibility policy,
or more than one upstream project.

Cross-repository work should be linked from the shared GitHub Project once one
is available. Do not block a useful upstream pull request on a Kubernetes
repository issue that merely repeats the same proposal.

## Ownership boundary

This repository owns Kubernetes resources, release sequencing, compatibility
metadata, and Kubernetes-specific qualification. It must not carry application
source overlays, replacement initializers, patched libraries, or private forks
of Foreman, Katello, Candlepin, Pulp, or Smart Proxy.

A generally useful runtime capability belongs in its owning upstream project.
Preserve the current package and host-container defaults, document the generic
contract, and consume it here only from a published image or from an explicitly
non-publishable local candidate used for integration testing.

## Pull requests

Keep one logical change per pull request. Include:

- the problem and the ownership boundary it affects;
- whether behavior is Kubernetes-specific or reusable by `foremanctl` and
  package installations;
- rendered-resource or runtime evidence appropriate to the change;
- compatibility, upgrade, recovery, and rollback implications;
- documentation for any new value, secret, external dependency, or operational
  limitation.

Do not describe an implemented-but-unrun drill as passing, and do not describe
an experimental compatibility set as supported.

## Local checks

Run the lightweight checks before submitting:

```sh
tests/render.sh
tests/shellcheck.sh
git diff --check
```

The disposable Kind suite is intentionally manual and substantially more
expensive:

```sh
tests/kind/run.sh
```

Its output is valid promotion evidence only when the exact commit, profiles,
images, platform, and required checks are retained by the integration evidence
workflow. Generic Foreman and Katello behavior belongs in `theforeman/smoker`;
the Kind suite should focus on orchestration, migrations, upgrades, recovery,
scaling, security boundaries, and failure convergence.

## Community conduct and review

Use the Foreman community forum for cross-project design discussion and follow
the Foreman community code of conduct. Maintainer review is required before an
experimental compatibility set or controller image is presented as a release.
