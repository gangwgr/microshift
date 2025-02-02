package prerun

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/openshift/microshift/pkg/config"
	"github.com/openshift/microshift/pkg/util"
	"github.com/openshift/microshift/pkg/version"
	"k8s.io/klog/v2"
)

var (
	versionFilePath = filepath.Join(config.DataDir, "version")

	errDataVersionDoesNotExist = errors.New("version file for MicroShift data does not exist")
)

// CheckAndUpdateDataVersion checks version compatibility between data and executable,
// and updates data version
func CheckAndUpdateDataVersion() error {
	execVer, err := getVersionOfExecutable()
	if err != nil {
		return fmt.Errorf("failed to get version of MicroShift executable: %w", err)
	}

	dataVer, err := getVersionOfData()
	dataVersionMissing := errors.Is(err, errDataVersionDoesNotExist)

	if err != nil && !dataVersionMissing {
		return fmt.Errorf("failed to get version of existing MicroShift data: %w", err)
	}

	if dataVersionMissing {
		// Ignoring .nodename to not get false positives from mere existence of the path
		dataExists, err := util.PathExistsAndIsNotEmpty(config.DataDir, ".nodename")
		if err != nil {
			return err
		}

		if !dataExists {
			// Data directory does not exist so it's first run of MicroShift
			klog.InfoS("Version file does not exist yet - assuming first run of MicroShift")
			return writeDataVersion(execVer)
		}

		// Data exists but without version file, let's assume 4.13 and compare versions
		klog.InfoS("MicroShift data directory exists, but doesn't contain version file" +
			" - assuming 4.13.0 and proceeding with version compatibility checks")
		dataVer = versionMetadata{Major: 4, Minor: 13, Patch: 0}
	}

	if err := checkVersionCompatibility(execVer, dataVer); err != nil {
		return fmt.Errorf("checking version compatibility failed: %w", err)
	}

	if err := isUpgradeBlocked(execVer, dataVer); err != nil {
		return err
	}

	if err := writeDataVersion(execVer); err != nil {
		return fmt.Errorf("failed to update data version: %w", err)
	}

	return nil
}

type versionMetadata struct {
	Major, Minor, Patch int
}

func (v versionMetadata) String() string {
	return fmt.Sprintf("%d.%d.%d", v.Major, v.Minor, v.Patch)
}

// versionMetadataFromString creates versionMetadata object from "major.minor.patch" string where major, minor, and patch are integers
func versionMetadataFromString(majorMinorPatch string) (versionMetadata, error) {
	majorMinorPatch = strings.TrimSpace(majorMinorPatch)
	split := strings.Split(majorMinorPatch, ".")
	if len(split) != 3 {
		return versionMetadata{}, fmt.Errorf("invalid version string (%s): expected Major.Minor.Patch", majorMinorPatch)
	}

	major, err := strconv.Atoi(split[0])
	if err != nil {
		return versionMetadata{}, fmt.Errorf("converting %q to an int failed: %w", split[0], err)
	}

	minor, err := strconv.Atoi(split[1])
	if err != nil {
		return versionMetadata{}, fmt.Errorf("converting %q to an int failed: %w", split[1], err)
	}

	patch, err := strconv.Atoi(split[2])
	if err != nil {
		return versionMetadata{}, fmt.Errorf("converting %q to an int failed: %w", split[2], err)
	}

	return versionMetadata{Major: major, Minor: minor, Patch: patch}, nil
}

func getVersionOfExecutable() (versionMetadata, error) {
	ver := version.Get()
	return versionMetadataFromString(fmt.Sprintf("%s.%s.%s", ver.Major, ver.Minor, ver.Patch))
}

func getVersionOfData() (versionMetadata, error) {
	exists, err := util.PathExistsAndIsNotEmpty(versionFilePath)
	if err != nil {
		return versionMetadata{}, fmt.Errorf("checking if path exists failed: %w", err)
	}

	if !exists {
		return versionMetadata{}, errDataVersionDoesNotExist
	}

	versionFileContents, err := os.ReadFile(versionFilePath)
	if err != nil {
		return versionMetadata{}, fmt.Errorf("reading %s failed: %w", versionFilePath, err)
	}

	return versionMetadataFromString(string(versionFileContents))
}

// checkVersionCompatibility compares versions of executable and existing data for purposes of data migration.
func checkVersionCompatibility(execVer, dataVer versionMetadata) error {
	if execVer == dataVer {
		return nil
	}

	if execVer.Major != dataVer.Major {
		return fmt.Errorf("major versions are different: %d and %d", dataVer.Major, execVer.Major)
	}

	if execVer.Minor < dataVer.Minor {
		return fmt.Errorf("executable (%s) is older than existing data (%s): migrating data to older version is not supported", execVer.String(), dataVer.String())
	}

	if execVer.Minor > dataVer.Minor {
		if execVer.Minor-1 == dataVer.Minor {
			return nil
		} else {
			return fmt.Errorf("executable (%s) is too recent compared to existing data (%s): maximum minor version difference is 1", execVer.String(), dataVer.String())
		}
	}

	return nil
}

func writeDataVersion(v versionMetadata) error {
	s := v.String()
	klog.InfoS("Writing MicroShift version to the file in data directory", "version", s)

	if err := os.WriteFile(versionFilePath, []byte(s), 0600); err != nil {
		return fmt.Errorf("writing %q to %q failed: %w", s, versionFilePath, err)
	}
	return nil
}
