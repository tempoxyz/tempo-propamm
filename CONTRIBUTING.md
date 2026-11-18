# Contributing

Thanks for helping. Report security issues privately as described in [SECURITY.md](SECURITY.md), never
in an issue or pull request.

## Set up

```bash
git clone https://github.com/tempoxyz/propAMM
cd propAMM
git submodule update --init lib/forge-std lib/openzeppelin-contracts
bin/install-solar   # the source-pinned Solar compiler
```

You need Foundry v1.8.1, Rust (pinned by `rust-toolchain.toml`) for the Rust SDK and Solar, and Node 24
for the TypeScript SDK. No credentials or private access are needed.

## Before you open a pull request

1. Run the checks for what you changed. [`.github/workflows/verify.yml`](.github/workflows/verify.yml) holds
   the canonical commands, and [AGENTS.md](AGENTS.md#validation) explains them. For contracts this is at
   least `forge fmt --check`, `forge lint`, `forge build` and `forge test`.
2. Update the guide that owns the behavior you changed.
3. Keep one logical change per pull request, with no unrelated formatting or refactoring.

## Commits and pull requests

Titles follow Conventional Commits, for example `fix(managed): reject a zero settler`. Pull requests are
squash-merged with the title as the commit subject, so describe the change and how you validated it in
the body.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
