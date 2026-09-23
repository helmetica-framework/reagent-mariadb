chart := `awk '/^name:/{print $2}' Chart.yaml`
version := `awk '/^version:/{print $2}' Chart.yaml`
major := `awk '/^version:/{split($2, v, "."); print v[1]}' Chart.yaml`

REGISTRY := "oci://ghcr.io/helmetica-framework"
# Holds the released azoth dependency while `just link` points it at a checkout
AZOTH_LINK := ".azoth-link"
# Registry of a local athanor (just ignite), reachable as localhost from the host
# and as registry.kube-system.svc from inside the cluster.
ATHANOR_REGISTRY := "localhost:5000/charts"
ATHANOR_REGISTRY_INTERNAL := "registry.kube-system.svc:5000/charts"

# renovate: datasource=go depName=github.com/kyverno/chainsaw
CHAINSAW_VERSION := "v0.2.15"
CHAINSAW_CMD := "go run github.com/kyverno/chainsaw@" + CHAINSAW_VERSION

# renovate: datasource=github-releases depName=helm-unittest/helm-unittest
UNITTEST_VERSION := "v1.1.2"

_default:
    @just --list

# Lint the chart and unit test the rendered templates
test:
    #!/usr/bin/env bash
    set -euo pipefail
    helm plugin list | grep -q '^unittest' \
        || helm plugin install https://github.com/helm-unittest/helm-unittest --version {{ UNITTEST_VERSION }}
    helm dependency update .
    helm lint .
    helm unittest --file 'test/unit/*_test.yaml' .

# Package the chart
build:
    helm dependency update .
    helm package .

# Develop against a local azoth checkout: just link ../azoth
link path="../azoth":
    #!/usr/bin/env bash
    set -euo pipefail
    test ! -f {{ AZOTH_LINK }} || { echo "already linked, run 'just unlink' first"; exit 1; }
    test -f "{{ path }}/Chart.yaml" || { echo "no chart at {{ path }}"; exit 1; }
    yq '.dependencies[] | select(.name == "azoth") | [.repository, .version] | .[]' \
        Chart.yaml > {{ AZOTH_LINK }}
    just _azoth-dep "file://{{ path }}" "$(yq '.version' "{{ path }}/Chart.yaml")"
    helm dependency update .

# Point the azoth dependency back at the registry
unlink:
    #!/usr/bin/env bash
    set -euo pipefail
    test -f {{ AZOTH_LINK }} || exit 0
    { read -r repository; read -r version; } < {{ AZOTH_LINK }}
    just _azoth-dep "$repository" "$version"
    rm -f {{ AZOTH_LINK }} Chart.lock charts/azoth-*.tgz
    echo "azoth dependency restored to $repository $version"

# Rewrite the azoth dependency's repository and version, leaving the rest of Chart.yaml alone
_azoth-dep repository version:
    #!/usr/bin/env bash
    set -euo pipefail
    awk -v repo='{{ repository }}' -v ver='{{ version }}' '
        /^[[:space:]]*-[[:space:]]*name:[[:space:]]*azoth[[:space:]]*$/ { inblock=1; print; next }
        /^[[:space:]]*-[[:space:]]/ { inblock=0 }
        inblock && /^[[:space:]]*repository:/ { sub(/repository:.*/, "repository: " repo); print; next }
        inblock && /^[[:space:]]*version:/ { sub(/version:.*/, "version: " ver); print; next }
        { print }
    ' Chart.yaml > Chart.yaml.tmp
    mv Chart.yaml.tmp Chart.yaml

# Refuse to run while the azoth dependency points at a local checkout
_guard-unlinked:
    #!/usr/bin/env bash
    set -euo pipefail
    repository=$(yq '.dependencies[] | select(.name == "azoth") | .repository' Chart.yaml)
    if [ -f {{ AZOTH_LINK }} ] || [ "${repository#file://}" != "$repository" ]; then
        echo "azoth is $repository, run 'just unlink' first"
        exit 1
    fi

# Push the packaged chart to the registry
push: _guard-unlinked build
    helm push {{ chart }}-{{ version }}.tgz {{ REGISTRY }}

# Read the reagent's purity: end-to-end test against a running athanor cluster (just ignite).
touchstone:
    {{ CHAINSAW_CMD }} test --config test/touchstone/chainsaw-config.yaml test/touchstone

# Push main, tag the current commit and push the tag to trigger the release
release: _guard-unlinked
    #!/usr/bin/env bash
    set -euo pipefail
    # Abort if the Chart.yaml version on main doesn't match the working copy.
    test "$(git show main:Chart.yaml | awk '/^version:/{print $2}')" = "{{ version }}" \
        || { echo "main Chart.yaml != working {{ version }}; commit the bump first"; exit 1; }
    # Abort if this version was already released.
    if git ls-remote --exit-code --tags origin "v{{ version }}" >/dev/null 2>&1; then
        echo "tag v{{ version }} already exists; bump the Chart.yaml version first"
        exit 1
    fi
    git push origin main
    git tag v{{ version }} main
    git push origin v{{ version }}

# Install the reagent via helm install
mix namespace="default":
    transmuter mix --namespace {{ namespace }}

# Install the reagent via helmetica into a running athanor cluster (just ignite).
infuse namespace="default" id="": build
    #!/usr/bin/env bash
    set -euo pipefail

    suffix=""
    if [ -n "{{ id }}" ]; then suffix="-{{ id }}"; fi
    group="v{{ major }}$suffix.{{ chart }}"

    # best effort pluralization
    lower='{{ lowercase(chart) }}'
    case "$lower" in
        *[!aeiou]y)       plural="${lower%y}ies" ;;
        *s|*x|*z|*ch|*sh) plural="${lower}es" ;;
        *)                plural="${lower}s" ;;
    esac

    kubectl apply -f - <<EOF
    # Install and configure upstream MariaDB crds, operator and cluster
    apiVersion: image.toolkit.fluxcd.io/v1
    kind: ImageRepository
    metadata:
      name: mariadb-crds-v26
      namespace: hel-chrysopoeia
    spec:
      exclusionList:
      - ^.*\.sig$
      - ^sha256-.+$
      image: ghcr.io/mariadb-operator/charts/mariadb-operator-crds
      interval: 12h
      provider: generic
    ---
    apiVersion: source.toolkit.fluxcd.io/v1
    kind: OCIRepository
    metadata:
      name: mariadb-crds-v26
      namespace: hel-chrysopoeia
    spec:
      interval: 12h
      provider: generic
      ref:
        semver: 26.x
      timeout: 60s
      url: oci://ghcr.io/mariadb-operator/charts/mariadb-operator-crds
    ---
    apiVersion: image.toolkit.fluxcd.io/v1
    kind: ImageRepository
    metadata:
      name: mariadb-operator-v26
      namespace: hel-chrysopoeia
    spec:
      exclusionList:
      - ^.*\.sig$
      - ^sha256-.+$
      image: ghcr.io/mariadb-operator/charts/mariadb-operator
      interval: 12h
      provider: generic
    ---
    apiVersion: source.toolkit.fluxcd.io/v1
    kind: OCIRepository
    metadata:
      name: mariadb-operator-v26
      namespace: hel-chrysopoeia
    spec:
      interval: 12h
      provider: generic
      ref:
        semver: 26.x
      timeout: 60s
      url: oci://ghcr.io/mariadb-operator/charts/mariadb-operator
    ---
    apiVersion: source.toolkit.fluxcd.io/v1
    kind: OCIRepository
    metadata:
      annotations:
      name: mariadb-cluster-v26
      namespace: hel-chrysopoeia
    spec:
      interval: 12h
      provider: generic
      ref:
        semver: 26.x
      timeout: 60s
      url: oci://ghcr.io/mariadb-operator/charts/mariadb-cluster
    ---
    apiVersion: image.toolkit.fluxcd.io/v1
    kind: ImageRepository
    metadata:
      name: mariadb-cluster-v26
      namespace: hel-chrysopoeia
    spec:
      exclusionList:
      - ^.*\.sig$
      - ^sha256-.+$
      image: ghcr.io/mariadb-operator/charts/mariadb-cluster
      interval: 12h
      provider: generic
    ---
    # Install CustomResourceDefinitionSources
    apiVersion: helmetica.io/v1
    kind: CustomResourceDefinitionSource
    metadata:
      annotations:
      name: v26.mariadb-crds
      namespace: hel-chrysopoeia
    spec:
      crdNames:
        kind: MariaDBOperatorCRD
        plural: mariadboperatorcrds
      provides:
      - dependencyGroup:
          name: mariadb
      reference:
        apiVersion: source.toolkit.fluxcd.io/v1
        kind: OCIRepository
        name: mariadb-crds-v26
      versionDiscovery:
        reference:
          apiVersion: image.toolkit.fluxcd.io/v1
          kind: ImageRepository
          name: mariadb-crds-v26
    ---
    apiVersion: helmetica.io/v1
    kind: CustomResourceDefinitionSource
    metadata:
      annotations:
      name: v26.mariadb-operator
      namespace: hel-chrysopoeia
    spec:
      crdNames:
        kind: MariaDBOperator
        plural: mariadboperators
      manages:
      - dependencyGroup:
          name: mariadb
      reference:
        apiVersion: source.toolkit.fluxcd.io/v1
        kind: OCIRepository
        name: mariadb-operator-v26
      versionDiscovery:
        reference:
          apiVersion: image.toolkit.fluxcd.io/v1
          kind: ImageRepository
          name: mariadb-operator-v26
    ---
    apiVersion: helmetica.io/v1
    kind: CustomResourceDefinitionSource
    metadata:
      annotations:
      name: v26.mariadb-cluster
      namespace: hel-chrysopoeia
    spec:
      crdNames:
        kind: MariaDBCluster
        plural: mariadbclusters
      reference:
        apiVersion: source.toolkit.fluxcd.io/v1
        kind: OCIRepository
        name: mariadb-cluster-v26
      requires:
      - dependencyGroup:
          name: mariadb
      versionDiscovery:
        reference:
          apiVersion: image.toolkit.fluxcd.io/v1
          kind: ImageRepository
          name: mariadb-cluster-v26
    ---
    # Install DependencyGroup
    apiVersion: helmetica.io/v1
    kind: DependencyGroup
    metadata:
      name: mariadb
    spec:
      crds:
      - name: backups.k8s.mariadb.com
      - name: connections.k8s.mariadb.com
      - name: databases.k8s.mariadb.com
      - name: externalmariadbs.k8s.mariadb.com
      - name: grants.k8s.mariadb.com
      - name: mariadbs.k8s.mariadb.com
      - name: maxscales.k8s.mariadb.com
      - name: physicalbackups.k8s.mariadb.com
      - name: pointintimerecoveries.k8s.mariadb.com
      - name: restores.k8s.mariadb.com
      - name: sqljobs.k8s.mariadb.com
      - name: users.k8s.mariadb.com
      harnessRef:
        kind: OperatorHarness
        name: mariadb
    EOF
    # deploy empty mariadb crd and operator for the crds to be properly installed
    kubectl apply -f - <<EOF
    apiVersion: v26.mariadb-crds.helmetica-bundles.io/bundle
    kind: MariaDBOperatorCRD
    metadata:
      name: mariadb-crds
      namespace: hel-chrysopoeia
    spec:
      approval:
        strategy: Automatic
      ociUrl: oci://ghcr.io/mariadb-operator/charts/mariadb-operator-crds
      provides:
      - dependencyGroup:
          name: mariadb
      version: 26.6.0
    ---
    apiVersion: v26.mariadb-operator.helmetica-bundles.io/bundle
    kind: MariaDBOperator
    metadata:
      name: mariadb-operator
      namespace: hel-chrysopoeia
    spec:
      approval:
        strategy: Automatic
      manages:
      - dependencyGroup:
          name: mariadb
      ociUrl: oci://ghcr.io/mariadb-operator/charts/mariadb-operator
      values:
        certController:
          enabled: false
        rbac:
          enabled: false
        webhook:
          enabled: false
      version: 26.6.0
    EOF
    ca=$(mktemp)
    trap 'rm -f "$ca"' EXIT
    kubectl -n kube-system get secret tls-server-certificate \
        -o jsonpath='{.data.ca\.crt}' | base64 -d > "$ca"
    helm push {{ chart }}-{{ version }}.tgz oci://{{ ATHANOR_REGISTRY }} --ca-file "$ca"

    # Chrysopoeia only watches CustomResourceDefinitionSources in its own namespace.
    kubectl apply -f - <<EOF
    apiVersion: source.toolkit.fluxcd.io/v1
    kind: OCIRepository
    metadata:
      name: {{ chart }}-v{{ major }}$suffix
      namespace: hel-chrysopoeia
    spec:
      interval: 5m
      provider: generic
      ref:
        semver: '{{ major }}.x'
      url: oci://{{ ATHANOR_REGISTRY_INTERNAL }}/{{ chart }}
    ---
    apiVersion: image.toolkit.fluxcd.io/v1
    kind: ImageRepository
    metadata:
      name: {{ chart }}$suffix
      namespace: hel-chrysopoeia
    spec:
      exclusionList:
        - '^.*\.sig\$'
        - '^sha256-.+\$'
      image: {{ ATHANOR_REGISTRY_INTERNAL }}/{{ chart }}
      interval: 5m
      provider: generic
    ---
    # The name becomes the API group of the generated CRD: <name>.helmetica-bundles.io
    apiVersion: helmetica.io/v1
    kind: CustomResourceDefinitionSource
    metadata:
      name: $group
      namespace: hel-chrysopoeia
    spec:
      requires:
      - dependencyGroup:
          name: mariadb
      crdNames:
        kind: {{ capitalize(lowercase(chart)) }}
        plural: $plural
      reference:
        apiVersion: source.toolkit.fluxcd.io/v1
        kind: OCIRepository
        name: {{ chart }}-v{{ major }}$suffix
      versionDiscovery:
        reference:
          apiVersion: image.toolkit.fluxcd.io/v1
          kind: ImageRepository
          name: {{ chart }}$suffix
    EOF

    kubectl -n hel-chrysopoeia wait --for condition=Ready \
        "customresourcedefinitionsource/$group" --timeout 120s

    # Manually bump the imagerepository
    kubectl annotate imagerepository/{{ chart }}$suffix -n hel-chrysopoeia \
        reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite

    # and the ocirepository
    kubectl annotate ocirepository/{{ chart }}-v{{ major }}$suffix -n hel-chrysopoeia \
        reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite

    # Chrysopoeia derives kind and plural from the chart, so both are read back.
    kind=$(kubectl get crd -o jsonpath="{.items[?(@.spec.group=='$group.helmetica-bundles.io')].spec.names.kind}")
    crd=$(kubectl get crd -o jsonpath="{.items[?(@.spec.group=='$group.helmetica-bundles.io')].metadata.name}")

    kubectl create namespace {{ namespace }} --dry-run=client -o yaml | kubectl apply -f -
    kubectl apply -f - <<EOF
    apiVersion: $group.helmetica-bundles.io/bundle
    kind: $kind
    metadata:
      name: {{ chart }}
      namespace: {{ namespace }}
    spec:
      approval:
        strategy: Automatic
      version: '{{ version }}'
      # Defaults of the chart's values.yaml.
      values: {}
    EOF

    kubectl -n {{ namespace }} wait --for=jsonpath='{.status.releaseStatus}'=Ready \
        "$crd/{{ chart }}" --timeout 300s
    kubectl -n {{ namespace }} get "$crd/{{ chart }}" \
        -o jsonpath='{"released into namespace "}{.status.instanceNamespace}{"\n"}'

# Uninstall what mix installed
strain namespace="default":
    helm uninstall $(basename $(pwd)) -n {{ namespace }}

# Uninstall what infuse installed, including the generated CRD
decant namespace="default" id="":
    #!/usr/bin/env bash
    set -euo pipefail

    suffix=""
    if [ -n "{{ id }}" ]; then suffix="-{{ id }}"; fi
    group="v{{ major }}$suffix.{{ chart }}"
    crd=$(kubectl get crd -o jsonpath="{.items[?(@.spec.group=='$group.helmetica-bundles.io')].metadata.name}")

    # The instance goes first: chrysopoeia uninstalls the release behind it.
    if [ -n "$crd" ]; then
        kubectl -n {{ namespace }} delete "$crd" {{ chart }} --ignore-not-found
    fi
    kubectl -n hel-chrysopoeia delete \
        "mariadboperator/mariadb-operator" \
        "mariadboperatorcrds/mariadb-crds" \
        "customresourcedefinitionsource/$group" \
        "ocirepository/{{ chart }}-v{{ major }}$suffix" \
        "imagerepository/{{ chart }}$suffix" --ignore-not-found \
        "customresourcedefinitionsources/v26.mariadb-cluster" \
        "ocirepository/mariadb-cluster-v26" \
        "imagerepository/mariadb-cluster-v26" --ignore-not-found \
        "customresourcedefinitionsources/v26.mariadb-operator" \
        "ocirepository/mariadb-operator-v26" \
        "imagerepository/mariadb-operator-v26" --ignore-not-found \
        "customresourcedefinitionsources/v26.mariadb-crds" \
        "ocirepository/mariadb-crds-v26" \
        "imagerepository/mariadb-crds-v26" --ignore-not-found
    kubectl delete dependencygroup/mariadb
    # Chrysopoeia owns the generated CRD, dropping its source does not remove it.
    # The CRD is cluster wide: this also takes any instance of this chart that
    # someone else claimed in another namespace.
    if [ -n "$crd" ]; then
        kubectl delete crd "$crd" --ignore-not-found
    fi
    if [ "{{ namespace }}" != default ]; then
        kubectl delete namespace {{ namespace }} --ignore-not-found
    fi
