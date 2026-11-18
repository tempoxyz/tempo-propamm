# Changesets

Every change to the package's public behaviour adds one changeset (`npm run changeset` from `sdk/ts`, or a file here):
one sentence in the past tense, with a `diff` fence showing the migration for a breaking change. Update an existing
changeset rather than adding a near-duplicate: until the first release, `initial-sdk.md` describes the whole SDK.

`npm run changeset:version` turns them into a release: `changeset version` bumps package.json and writes the CHANGELOG,
then `scripts/version.mjs` rewrites `src/version.ts`, the version every error names, and package-lock.json's own
version from it. The package is at `0.0.0`, unreleased, and `initial-sdk.md` is a `minor`, so the first release is
`0.1.0`. Test snapshots name the version `<version>`, so a release changes none; `test/errors.test.ts` holds
`src/version.ts` to package.json.

No CI job checks for a changeset: `npx changeset status` compares against the base branch, whose history the job's
shallow checkout doesn't fetch.

On `main`, `.github/workflows/main.yml` releases them: its Version job opens the `chore(sdk-ts): version packages` pull
request with `npm run changeset:version`, and once that is merged its Publish job publishes the new version to npm
(`npm run changeset:publish`, trusted publishing) and tags it with a GitHub release. The repository AGENTS.md
("Releasing the TypeScript SDK") has the details and the one-time setup.
