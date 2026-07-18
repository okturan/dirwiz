# Security policy

## Reporting a vulnerability

Please use [GitHub private vulnerability reporting](https://github.com/okturan/dirwiz/security/advisories/new). Do not open a public issue for a security problem.

Include the affected DirWiz version or commit, macOS version, the app or CLI path involved, and a minimal reproduction. For scanner or cleanup bugs, describe the filesystem shape with synthetic paths where possible. Do not attach directory listings, screenshots, or archives from a personal volume.

Useful reports include:

- a path, symlink, hardlink, or APFS-clone case that could make DirWiz inspect or act on the wrong file;
- duplicate cleanup that could move an unverified file to Trash;
- unsafe handling of Full Disk Access or other macOS privacy permissions;
- command or path injection in the CLI, packaging, or Finder integration;
- a release-integrity or update-path problem.

The published v1.0.0 zip is a historical, ad-hoc-signed arm64 build and is not notarized. Those documented signing and compatibility limits are not vulnerabilities by themselves. Current source and the latest listed release are the supported surfaces for new reports.

I will investigate private reports and coordinate disclosure after a fix or a clear mitigation is available. No response-time or remediation-time guarantee is implied.

## Safe testing

Use a synthetic volume or disposable directory. Keep backups of anything you cannot replace. Do not test destructive behavior against another person's files, shared storage, or a production volume without permission.
