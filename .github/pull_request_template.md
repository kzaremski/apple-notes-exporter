## Summary

<!-- What does this PR change and why? -->

## Related issues

<!-- e.g. "Fixes #42" or "Ref #17" -->

## Checklist

- [ ] Commits follow [Conventional Commits](https://www.conventionalcommits.org/)
- [ ] Every commit is signed off (`git commit -s`) per [DCO](../CONTRIBUTING.md#developer-certificate-of-origin-dco). By signing off, I certify the [Developer Certificate of Origin](https://developercertificate.org/) and agree that my contribution will be released under the project's [GPLv3 license](../LICENSE).
- [ ] `make build` succeeds locally
- [ ] If UI changed: tested the happy path and edge cases in the running app
- [ ] If new format/export logic: `make test-formats` passes
- [ ] Added myself to `CONTRIBUTORS.txt` (if not already there)
- [ ] No em-dashes in code comments or commit messages
- [ ] Did not change `project.pbxproj`, `*.xcconfig`, `*.entitlements`, or `.github/**` unless strictly necessary (these require owner review)
