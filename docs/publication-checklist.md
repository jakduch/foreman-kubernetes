# First-publication checklist

This repository is intended for early, transparent community collaboration.
Publishing it does not promote a compatibility set or create a support claim.

## Repository content

- [x] Mark the project experimental and unsupported at the top of the README.
- [x] State that the project consumes upstream images and does not publish
  replacement application images.
- [x] Document component ownership, migration ordering, Helm/operator roles,
  Smart Proxy placement, and the relationship to `foremanctl`.
- [x] Remove the Kubernetes-specific Katello event-daemon split and the
  unqualified external-broker Candlepin HA experiment.
- [x] Document generic validation with `theforeman/smoker` separately from the
  Kubernetes-specific Kind suite.
- [x] Provide contribution guidance and a pull-request template; a duplicate
  issue is not mandatory for a focused change.
- [x] Add the GNU GPLv3 license used by the principal Foreman and Foreman OCI
  repositories.
- [x] Run the lightweight checks for the import snapshot.

## Foreman organization actions

- [ ] Grant the initial maintainers write access through the appropriate
  Foreman GitHub team; verify access before attempting the first push.
- [ ] Add a concise repository description, topics, and the confirmed license.
- [ ] Choose whether to preserve the development history or import a reviewed,
  squashed initial snapshot. Record that choice in the first pull request.
- [ ] Protect the default branch and require the lightweight workflow after it
  has run successfully in the organization repository.
- [ ] Create the shared GitHub Project Eric proposed and link Kubernetes,
  `foremanctl`, image, and application-upstream work without duplicating every
  upstream issue.
- [ ] Enable security reporting and point contributors to the Foreman project's
  established security process.

## First public pull request

The first pull request should call out the remaining upstream contracts and
unrun integration work rather than presenting the repository as deployable in
production. It should include the static-check result, the compatibility-set
status, and a link to the RFC thread. Runtime claims may be strengthened only
after the exact image digests and platform tuple have retained Kind and Smoker
evidence.
