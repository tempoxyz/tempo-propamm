import { defineConfig } from 'vitest/config'

// Every project's snapshots name this package's version as `<version>` (test/version-serializer.ts).
const snapshotSerializers = ['./test/version-serializer.ts']

export default defineConfig({
  test: {
    projects: [
      {
        test: {
          name: 'unit',
          include: ['test/*.test.ts'],
          snapshotSerializers,
        },
      },
      {
        test: {
          name: 'types',
          // Type-level tests only: `tsc` checks test/*.test-d.ts, and nothing runs.
          typecheck: {
            enabled: true,
            only: true,
            include: ['test/*.test-d.ts'],
          },
        },
      },
      {
        test: {
          name: 'e2e',
          include: ['test/e2e/*.test.ts'],
          snapshotSerializers,
          // Each file starts its own `anvil --network tempo` on a port it probes free and then hands to anvil. Running
          // the files one at a time keeps two of them from ever racing for one port; the whole project takes seconds.
          fileParallelism: false,
          // A differential fuzz with PROPAMM_FUZZ_RUNS raised, or a large PROPAMM_VECTORS set, runs for minutes.
          testTimeout: 600_000,
          hookTimeout: 120_000,
        },
      },
    ],
  },
})
