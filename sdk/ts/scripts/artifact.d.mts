/** Maximum compressed tarball and decompressed tar sizes, in bytes. */
export const MAX_ARCHIVE_BYTES: number
export const MAX_TAR_BYTES: number
/** Authenticate exact compressed registry bytes using its canonical SHA-512 SRI. */
export function verifyIntegrity(archive: Uint8Array, expected: string): void
/** Canonical SHA-256 identity of sorted paths, executable bits and exact file bytes. */
export function artifactIdentity(archive: Uint8Array): string
