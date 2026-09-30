# Testing strategy

The project separates application validation from Kubernetes orchestration
qualification so that Foreman behavior is not reimplemented in every deployment
tool.

## Upstream component tests

Foreman, Katello, Candlepin, Pulp, Smart Proxy, and image changes retain their
unit and integration tests in the owning repositories. A local candidate image
may exercise an unpublished upstream commit, but its result is not evidence that
the capability exists in a published image.

## Generic platform validation

[`theforeman/smoker`](https://github.com/theforeman/smoker) is the intended
deployment-independent functional layer. It should validate the same public
Foreman and Katello behavior against package, `foremanctl`, and Kubernetes
installations.

The first experimental Kubernetes publication records Smoker integration as a
release gate, not as already completed work. Before a compatibility set can be
promoted beyond experimental, CI must run a reviewed Smoker selection from
outside the application namespace against the public TLS endpoint and retain:

- the Smoker revision and selected markers;
- the tested Foreman URL and compatibility-set identity, without credentials;
- the pass/fail report as release evidence.

Credentials must come from CI secrets and must not be rendered into Helm values,
workflow arguments, or retained artifacts.

## Kubernetes-specific static tests

`tests/render.sh` verifies Helm schemas, rendered relationships, security
contexts, NetworkPolicies, migrations, compatibility metadata, and operator
state-machine contracts. `tests/shellcheck.sh` validates shell entry points.
These checks run for every pull request and do not require a cluster.

## Kubernetes-specific runtime tests

The disposable Kind suite owns behavior that depends on Kubernetes:

- admission and restricted Pod Security;
- dependency preflight and migration-before-rollout ordering;
- restart adoption, leader takeover, and release fencing;
- readiness, endpoint draining, disruption, and workload replacement;
- safe failure and roll-forward after a migration error;
- backup, clean-namespace recovery, and credential rotation;
- NetworkPolicy boundaries, autoscaling configuration, and node scheduling;
- Pulp object-storage, execution-proxy, and optional provider integration.

It may use a narrow application request to prove that orchestration succeeded,
but broad content and UI behavior should move to Smoker rather than grow a
second application test suite here.

## Evidence levels

Documentation and compatibility metadata must distinguish:

1. implemented but not run;
2. passed static rendering and contract checks;
3. passed the exact disposable-cluster qualification;
4. passed generic Smoker validation;
5. observed in a sustained environment at operational scale.

An experimental release may stop at the earlier levels when its limitations are
prominent. A support claim requires an explicit platform matrix, retained
evidence, upgrade and recovery coverage, and operational feedback beyond one
successful installation.
