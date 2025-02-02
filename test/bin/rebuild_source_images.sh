#!/bin/bash
#
# This script should be run on the image build server (usually the
# same as the hypervisor).

set -euo pipefail

SCRIPTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=test/bin/common.sh
source "${SCRIPTDIR}/common.sh"

# Rebuild the RPM from source
"${SCRIPTDIR}/build_rpms.sh"

# Rebuild the images
"${SCRIPTDIR}/build_images.sh" -s
