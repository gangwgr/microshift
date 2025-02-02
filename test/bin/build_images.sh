#!/bin/bash
#
# This script should be run on the image build server (usually the
# same as the hypervisor).

set -euo pipefail

# If a glob pattern does not match anything, return a null value
# instead of the pattern. This ensures for loops over files do not
# produce errors when a group directory does not include any matching
# files.
shopt -s nullglob

SCRIPTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=test/bin/common.sh
source "${SCRIPTDIR}/common.sh"

configure_package_sources() {
    ## TEMPLATE VARIABLES
    #
    # Machine platform type ("x86_64")
    UNAME_M=$(uname -m)
    export UNAME_M
    export LOCAL_REPO              # defined in common.sh
    export NEXT_REPO               # defined in common.sh
    export SOURCE_VERSION
    export FAKE_NEXT_MINOR_VERSION
    export MINOR_VERSION
    export PREVIOUS_MINOR_VERSION

    # Add our sources. It is OK to run these steps repeatedly, if the
    # details change they are updated in the service.
    title "Expanding package source templates to ${IMAGEDIR}/package-sources"
    mkdir -p "${IMAGEDIR}/package-sources"
    for template in "${TESTDIR}"/package-sources/*.toml; do
        name=$(basename "${template}" .toml)
        outfile="${IMAGEDIR}/package-sources/${name}.toml"
        echo "Rendering ${template} to ${outfile}"
        envsubst <"${template}" >"${outfile}"
        echo "Adding package source from ${outfile}"
        if sudo composer-cli sources list | grep "^${name}\$"; then
            sudo composer-cli sources delete "${name}"
        fi
        sudo composer-cli sources add "${outfile}"
    done

    # Show details about the available sources to make debugging easier.
    for name in $(sudo composer-cli sources list); do
        echo
        echo "Package source: ${name}"
        sudo composer-cli sources info "${name}" | sed -e 's/gpgkeys.*/gpgkeys = .../g'
    done
}

# Given a blueprint filename, extract the name value. It does not have
# to match the filename, but some commands take the file and others
# take the name, so we need to be able to have both.
get_blueprint_name() {
    local filename="${1}"
    tomcli-get "${filename}" name
}

# Given a blueprint filename, extract the parent blue filename from
# the prefix and use that to find the actual blueprint name that
# composer knows.
#
# rhel92-microshift-source -> rhel-9.2
#
# FIXME: We may need to change the prefix separator in the future if
# we need a multi-level hierarchy.
get_image_parent() {
    local blueprint_filename="$1"

    local base
    base=$(basename "${blueprint_filename}" .toml)
    if [[ "${base}" =~ '-' ]]; then
        base="${base//-*/}"
        get_blueprint_name "${IMAGEDIR}/blueprints/${base}.toml"
    else
        echo ""
    fi
}

# Process a set of blueprint templates to create edge commit images
# for them.
do_group() {
    local groupdir="$1"

    title "Building ${groupdir}"

    local blueprint
    local blueprint_file
    local build_name
    local buildid
    local buildid_list=""
    local parent
    local parent_args
    local template
    local template_list

    # Upload the blueprint definitions
    echo "Expanding blueprint templates to ${IMAGEDIR}/blueprints and starting edge-commit builds"
    if ! ${ONLY_SOURCE}; then
        template_list=$(echo "${groupdir}"/*.toml)
    else
        template_list=$(echo "${groupdir}"/*source*.toml)
    fi
    for template in ${template_list}; do
        echo
        echo "Blueprint ${template}"

        blueprint_file="${IMAGEDIR}/blueprints/$(basename "${template}")"
        echo "Rendering ${template} to ${blueprint_file}"
        envsubst <"${template}" >"${blueprint_file}"

        blueprint=$(get_blueprint_name "${blueprint_file}")

        if sudo composer-cli blueprints list | grep -q "^${blueprint}$"; then
            echo "Removing existing definition of ${blueprint}"
            sudo composer-cli blueprints delete "${blueprint}"
        fi

        echo "Loading new definition of ${blueprint}"
        sudo composer-cli blueprints push "${blueprint_file}"

        echo "Resolving dependencies for ${blueprint}"
        # shellcheck disable=SC2024  # redirect and sudo
        sudo composer-cli blueprints depsolve "${blueprint}" \
             >"${LOGDIR}/${blueprint}-depsolve.log" 2>&1

        parent_args=""
        parent=$(get_image_parent "${template}")
        if [ -n "${parent}" ]; then
            parent_args="--parent ${parent} --url http://${VM_BRIDGE_IP}:${WEB_SERVER_PORT}/repo"
        fi
        echo "Building edge-commit from ${blueprint} ${parent_args}"
        # shellcheck disable=SC2086  # quote to avoid glob expansion
        buildid=$(sudo composer-cli compose start-ostree \
                       ${parent_args} \
                       --ref "${blueprint}" \
                       "${blueprint}" \
                       edge-commit \
                      | awk '{print $2}')
        echo "Build ID ${buildid}"
        # Record a "build name" to be used as part of the unique
        # filename for the log we download next.
        echo "${blueprint}-edge-commit" > "${IMAGEDIR}/builds/${buildid}.build"
        buildid_list="${buildid_list} ${buildid}"
    done

    if ${BUILD_INSTALLER}; then
        for image_installer in "${groupdir}"/*.image-installer; do
            blueprint=$(cat "${image_installer}")
            echo "Building image-installer from ${blueprint}"
            buildid=$(sudo composer-cli compose start \
                           "${blueprint}" \
                           image-installer \
                          | awk '{print $2}')
            echo "Build ID ${buildid}"
            # Record a "build name" to be used as part of the unique
            # filename for the log we download next.
            echo "${blueprint}-image-installer" > "${IMAGEDIR}/builds/${buildid}.build"
            buildid_list="${buildid_list} ${buildid}"
        done
    fi

    if [ -n "${buildid_list}" ]; then
        echo "Waiting for builds to complete..."
        # shellcheck disable=SC2086  # pass command arguments quotes to allow word splitting
        time "${SCRIPTDIR}/wait_images.py" ${buildid_list}
    fi

    echo "Downloading build logs, metadata, and image"
    cd "${IMAGEDIR}/builds"
    # shellcheck disable=SC2231  # allow glob expansion without quotes in for loop
    for buildid in ${buildid_list}; do
        # shellcheck disable=SC2086  # pass glob args without quotes
        rm -f ${buildid}-*.tar

        sudo composer-cli compose logs "${buildid}"
        # shellcheck disable=SC2086  # pass glob args without quotes
        sudo chown "$(whoami)." ${buildid}-*

        # The log tar file contains 1 log file. Extract that file and
        # move it to the log directory with a unique name.
        tar xf "${buildid}-logs.tar"
        build_name=$(cat "${buildid}.build")
        mv logs/osbuild.log "${LOGDIR}/osbuild-${build_name}-${buildid}.log"

        # Skip the remaining steps for anything that has a status that
        # is not finished (failed, canceled, etc.).
        status=$(sudo composer-cli compose status | grep "${buildid}" | awk '{print $2}')
        if [ "${status}" != "FINISHED" ]; then
            sudo composer-cli compose info "${buildid}"
            continue
        fi

        sudo composer-cli compose metadata "${buildid}"
        sudo composer-cli compose image "${buildid}"
        # shellcheck disable=SC2086  # pass glob args without quotes
        sudo chown "$(whoami)." ${buildid}-*

        if [[ "${build_name}" =~ edge-commit ]]; then
            commit_file="${buildid}-commit.tar"
            echo "Unpacking ${commit_file} ${build_name}"
            tar -C "${IMAGEDIR}" -xf "${commit_file}"
        elif [[ "${build_name}" =~ image-installer ]]; then
            blueprint=${build_name//-image-installer/}
            iso_file="${buildid}-installer.iso"
            echo "Moving ${iso_file} to ${VM_DISK_DIR}/${blueprint}.iso"
            mv -f "${iso_file}" "${VM_DISK_DIR}/${blueprint}.iso"
        else
            echo "Do not know how to handle build ${build_name}"
        fi
    done

    for alias_file in "${groupdir}"/*.alias; do
        alias_name=$(basename "${alias_file}" .alias)
        point_to=$(cat "${alias_file}")
        echo "Creating image reference alias ${alias_name} -> ${point_to}"
        (cd "${IMAGEDIR}" &&
             ostree refs --repo=repo --force \
                    --create "${alias_name}" "${point_to}")
    done

    cd "${IMAGEDIR}"
    echo "Updating ostree references in ${IMAGEDIR}/repo"
    ostree summary --update --repo=repo
    ostree summary --view --repo=repo
}

usage() {
    cat - <<EOF
build_images.sh [-Is] [-g group-dir]

  -h      Show this help

  -i      Build the installer image(s).

  -I      Do not build the installer image(s).

  -s      Only build source images (implies -I).

  -g DIR  Build only one group.
EOF
}

BUILD_INSTALLER=true
ONLY_SOURCE=false
GROUP=""

while getopts "iIg:sh" opt; do
    case "${opt}" in
        h)
            usage
            exit 0
            ;;
        i)
            BUILD_INSTALLER=true
            ;;
        I)
            BUILD_INSTALLER=false
            ;;
        g)
            GROUP="${OPTARG}"
            ;;
        s)
            BUILD_INSTALLER=false
            ONLY_SOURCE=true
            ;;
        *)
            echo "ERROR: Unknown option ${opt}"
            echo
            usage
            exit 1
            ;;
    esac
done

# Determine the version of the RPM in the local repo so we can use it
# in the blueprint templates.
if [ ! -d "${LOCAL_REPO}" ]; then
    error "Run ${SCRIPTDIR}/create_local_repo.sh before building images."
    exit 1
fi
release_info_rpm=$(find "${LOCAL_REPO}" -name 'microshift-release-info-*.rpm' | sort | tail -n 1)
if [ -z "${release_info_rpm}" ]; then
    error "Failed to find microshift-release-info RPM in ${LOCAL_REPO}"
    exit 1
fi
SOURCE_VERSION=$(rpm -q --queryformat '%{version}' "${release_info_rpm}")
MINOR_VERSION=$(echo "${SOURCE_VERSION}" | cut -f2 -d.)
PREVIOUS_MINOR_VERSION=$(( "${MINOR_VERSION}" - 1 ))
FAKE_NEXT_MINOR_VERSION=$(( "${MINOR_VERSION}" + 1 ))

mkdir -p "${IMAGEDIR}"
LOGDIR="${IMAGEDIR}/build-logs"
mkdir -p "${LOGDIR}"
mkdir -p "${IMAGEDIR}/blueprints"
mkdir -p "${IMAGEDIR}/builds"
mkdir -p "${VM_DISK_DIR}"

configure_package_sources

if [ -n "${GROUP}" ]; then
    do_group "${GROUP}"
else
    for group in "${TESTDIR}"/image-blueprints/group*; do
        do_group "${group}"
    done
fi
