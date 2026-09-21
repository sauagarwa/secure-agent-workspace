#!/usr/bin/env bash
# Start the intentionally isolated golden-image qualification build.
set -euo pipefail

context="${SAW_IMAGE_CONTEXT:?Set SAW_IMAGE_CONTEXT to the context made by make saw-image-context}"
namespace="${SAW_IMAGE_BUILD_NAMESPACE:-saw-installer-validation}"
test -f "$context/Dockerfile" || { echo "No Dockerfile in $context" >&2; exit 2; }
oc apply -f examples/saw/installer-build.yaml
oc start-build saw-installer -n "$namespace" --from-dir="$context" --follow
digest="$(oc get build -n "$namespace" -l buildconfig=saw-installer --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].status.output.to.imageDigest}')"
repository="$(oc get imagestream saw-installer -n "$namespace" -o jsonpath='{.status.dockerImageRepository}')"
printf '\nQualified only after the smoke, scan and approval gates succeed.\n'
printf 'Candidate immutable image: %s@%s\n' "$repository" "$digest"
