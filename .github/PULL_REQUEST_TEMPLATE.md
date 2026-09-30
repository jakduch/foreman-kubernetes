## What changed

Describe the problem, the ownership boundary, and the resulting behavior.

## Scope

- [ ] The change is Kubernetes orchestration or compatibility metadata, not an application patch.
- [ ] Any generic runtime capability is proposed in its owning upstream project.
- [ ] Existing package and `foremanctl` defaults remain unchanged or the change is explicitly coordinated.

## Verification

- [ ] `tests/render.sh`
- [ ] `tests/shellcheck.sh`
- [ ] `git diff --check`
- [ ] Runtime evidence is attached or the unrun status is stated explicitly.

## Operational impact

Document compatibility, migration, upgrade, recovery, security, external-service,
and rollback implications. Do not describe this experimental project as
supported or production-ready.
