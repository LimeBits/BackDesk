# GitHub Publishing Guide

BackDesk is prepared to publish under the `LimeBits` GitHub account:

```text
https://github.com/LimeBits/BackDesk
```

## One-time Repository Setup

1. Create a new empty GitHub repository named `BackDesk` under `LimeBits`.
2. Keep the repository empty at creation time if possible. Do not add a README or license from the GitHub UI because the project already contains those files.
3. Add a GitHub remote locally:

```bash
git remote add github git@github.com:LimeBits/BackDesk.git
```

If the remote already exists, update it:

```bash
git remote set-url github git@github.com:LimeBits/BackDesk.git
```

4. Push the main branch:

```bash
git push github main
```

## Release v0.2.6

After the repository exists on GitHub, publish the first GitHub release:

```bash
git tag -a v0.2.6 -m "BackDesk v0.2.6"
git push github v0.2.6
```

Then open GitHub Releases and create a release from `v0.2.6`. Upload:

- `BackDesk_v0.2.6_universal.zip`
- `BackDesk_v0.2.6_arm64.zip`
- `BackDesk_v0.2.6_x86_64.zip`

## App Integration

The app update checker and feedback links are configured for:

```text
LimeBits/BackDesk
```

Until that GitHub repository exists, update checks will fail with a not-found response and feedback links will open a missing repository page. That is expected during migration.
