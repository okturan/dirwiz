## ADDED Requirements

### Requirement: A volume scan stays on the scan root's device

The scanner SHALL use the scan root's device identity as the traversal boundary and SHALL NOT descend
into a directory on a different device unless cross-mount traversal is explicitly enabled.

#### Scenario: A foreign mount is nested below the scan root

- **WHEN** an encountered directory's device differs from the scan root's known device
- **THEN** the scanner skips descending into that directory
- **AND** the foreign mount's contents do not contribute to the scanned volume's totals

#### Scenario: The macOS System and Data roots share a device

- **WHEN** a root-volume scan reaches `/System/Volumes/Data` and it reports the scan root's device
- **THEN** traversal continues so the macOS volume group remains complete

#### Scenario: The foreign volume is itself the scan root

- **WHEN** the user starts a scan at that mounted volume
- **THEN** its device becomes the traversal boundary and the volume is scanned normally

### Requirement: Mount filtering fails open and has an escape hatch

The scanner SHALL preserve the existing cross-mount behavior when the root device cannot be
determined or when `DIRWIZ_CROSS_MOUNTS=1` is set.

#### Scenario: Root device lookup fails

- **WHEN** the scanner cannot determine the scan root's device
- **THEN** it traverses encountered devices as before rather than risking silent data loss

#### Scenario: Cross-mount override is enabled

- **WHEN** `DIRWIZ_CROSS_MOUNTS=1` is present
- **THEN** directories are not rejected merely because their devices differ from the scan root

### Requirement: Skipped mounts are reported distinctly

The system SHALL count and surface mount-boundary skips separately from permission-denied or system-
protected directories, including the skipped mount path and the reason it was not traversed.

#### Scenario: A mounted disk image is excluded

- **WHEN** a volume scan encounters and skips the disk image's mount point
- **THEN** scan progress records that mount path
- **AND** the sidebar explains that a separate mounted filesystem was deliberately excluded

### Requirement: Cold and warm traversal share the mount boundary

The same relative-device rule SHALL apply to full scans and subtree rescans so warm-patched and fresh
cold trees retain equivalent volume scope.

#### Scenario: A changed path reaches a foreign mount during warm patching

- **WHEN** `rescanSubtrees` encounters a device that the equivalent cold scan would exclude
- **THEN** the warm path also excludes and reports it
- **AND** the completed warm tree remains equivalent to a fresh cold scan under the same policy

#### Scenario: A skipped mount is reachable by another valid same-device path

- **WHEN** a foreign-device occurrence is rejected
- **THEN** its inode is not marked visited merely because of that rejection
- **AND** a separately encountered eligible occurrence may still be traversed

