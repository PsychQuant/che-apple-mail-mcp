## 1. Tests first (RED)

- [x] 1.1 Add the deny-list tests (marked by the `#671` section): plain, `/.nofollow`, `/.resolve/<n>`, letter case, link, allowed spellings, missing deny root, fail-closed verdict, `/tmp` file. Verified red against a validator whose identity verdict is always clear.

## 2. Implementation (GREEN)

- [x] 2.1 Attachment paths must be regular files: identity comparison over the prefixes of the resolved path, fail closed on an unreadable prefix or deny root, `denyRoots` internal parameter. Verified: the tests above pass.

## 3. Documentation

- [x] 3.1 SECURITY.md layer 3 and limitation text; CHANGELOG entry. Verified by reading.
