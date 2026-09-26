# Local candidate images

The default release set points only at published, digest-pinned images. Some
runtime contracts required by this project currently exist as independent
local upstream commits. A chart render cannot prove those commits work together,
and rebuilding an OCI repository that installs released RPMs would not include
the local application source.

`scripts/build-local-candidate-images.rb` therefore creates three temporary,
unpublished derivative images for the amd64 integration environment:

- Foreman receives only the runtime files from the recorded Foreman and Katello
  commits. Katello files are copied into the installed gem discovered by Ruby,
  rather than assuming a versioned filesystem path.
- Candlepin receives the recorded migration entry point and keeps the numeric
  packaged Tomcat identity.
- Pulp receives the exact `django-storages` version and hash from the prepared
  packaging change plus the compatible packaged boto3 dependency. This is a
  qualification bridge only; the supported image must ultimately install both
  dependencies from the published Pulpcore RPM repository.

Every base is the immutable digest from the normal candidate profile. The
generated evidence records each upstream commit, a deterministic context hash,
the resulting image ID, and its platform. Images are labelled
`org.theforeman.kubernetes.unpublished=true`, use local names, and the script
has no push operation.

Prepare contexts on the workstation that contains the independent upstream
clones:

```bash
ruby scripts/build-local-candidate-images.rb --prepare-only \
  artifacts/local-candidate-prepared.json
```

Transfer the repository plus `artifacts/local-candidate-contexts` and the
prepared JSON to a native amd64 integration host. Build and load them into the
existing Kind cluster without transferring the upstream Git repositories:

```bash
ruby scripts/build-local-candidate-images.rb \
  --build-prepared artifacts/local-candidate-prepared.json \
  --kind foreman-stack-e2e \
  artifacts/local-candidate-images.json
```

Run the integration harness with the local application profile and retain the
candidate evidence for image-ID verification:

```bash
REUSE_CLUSTER=1 \
KEEP_CLUSTER=1 \
IMAGE_PROFILE=profiles/local-amd64-candidate.yaml \
EXECUTION_PROXY_IMAGE_PROFILE=profiles/execution-proxy-nightly-candidate-2026-09-24.yaml \
LOCAL_CANDIDATE_EVIDENCE_FILE=artifacts/local-candidate-images.json \
tests/kind/run.sh
```

The platform report marks this run `qualificationEligible: false`. It can find
runtime defects before publication, but it cannot promote a compatibility set.
Promotion still requires published, digest-pinned upstream images.
