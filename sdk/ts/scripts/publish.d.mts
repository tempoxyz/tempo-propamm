// Types for the release script's offline tests.
export type Package = { name: string; version: string }
export type GitHubState = { tagCommit: string | null; releaseExists: boolean }
export type ReleasePlan = { publish: boolean; tag: boolean }
export type Environment = Record<string, string | undefined>
export type ReleaseIO = {
  head(): string
  metadata(): unknown
  github(tag: string): Promise<GitHubState | undefined>
  artifact(): string
  publishedArtifact(metadata: unknown): Promise<string | null>
  sleep?(ms: number): Promise<void>
  publish(): void
  emit(event: string): void
}

export function tagOf(pkg: Package): string
export function gitTagEvent(pkg: Package): string
export function parseNpmMetadata(
  pkg: Package,
  result: { status: number | null; stdout: string },
): unknown
export function npmMetadata(pkg: Package, cwd?: string): unknown
export function checkoutHead(cwd?: string, env?: Environment): string
export function packArtifact(pkg: Package, cwd?: string): string
export function registryTarballUrl(metadata: unknown): string
export function registryArtifact(metadata: unknown): Promise<string | null>
export function githubState(
  tag: string,
  env?: Environment,
): Promise<GitHubState | undefined>
export function plan(state: {
  pkg: Package
  metadata: unknown
  github: GitHubState | undefined
  head: string
}): ReleasePlan
export function runRelease(pkg: Package, io: ReleaseIO): Promise<ReleasePlan>
