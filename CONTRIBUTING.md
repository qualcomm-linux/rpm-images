# Contributing to rpm-images

Hi there!
We’re thrilled that you’d like to contribute to this project.
Your help is essential for keeping this project great and for making it better.

## Branching Strategy

In general, contributors should develop on branches based off of `main` and pull requests should be made against `main`.

## Submitting a pull request

1. Please read our [code of conduct](CODE-OF-CONDUCT.md) and [license](LICENSE.txt).
1. [Fork](https://github.com/qualcomm-linux/rpm-images/fork) and clone the repository.

    ```bash
    git clone https://github.com/<username>/rpm-images.git
    ```

1. Create a new branch based on `main`:

    ```bash
    git checkout -b <my-branch-name> main
    ```

1. Create an upstream `remote` to make it easier to keep your branches up-to-date:

    ```bash
    git remote add upstream https://github.com/qualcomm-linux/rpm-images.git
    ```

1. Make your changes and [test them](#testing).
1. Commit your changes following the [commit message](#commit-messages)
   and [sign-off](#sign-off-and-trailers) rules below:

    ```bash
    git commit -s
    ```

1. After committing your changes on the topic branch, sync it with the upstream branch:

    ```bash
    git pull --rebase upstream main
    ```

1. Push to your fork.

    ```bash
    git push -u origin <my-branch-name>
    ```

    The `-u` is shorthand for `--set-upstream`. This will set up the tracking reference so subsequent runs of `git push` or `git pull` can omit the remote and branch.

1. [Submit a pull request](https://github.com/qualcomm-linux/rpm-images/pulls) from your branch to `main`.

Pull requests are discussed and reviewed within the GitHub pull-request
infrastructure.

## Commit messages

Each commit must be atomic: it must contain exactly one logical change. Do
not squash multiple features, fixes, or otherwise unrelated changes into a
single commit — split them into separate commits, one per logical change.
Each commit must be self-contained, and the tree must still build a working
image after every commit. If you want to make multiple independent changes,
consider submitting them as separate pull requests.

### Subject

This project uses [Conventional Commits](https://www.conventionalcommits.org/)
for the subject line:

```text
type(scope): summary of the change
```

`type` is one of:

- `feat` — new functionality (a package, profile, board, build option);
- `fix` — a bug fix;
- `chore` — routine updates such as kernel refs, boot binaries or firmware;
- `refactor` — restructuring with no functional change;
- `docs` — documentation only;
- `ci` — GitHub workflows and actions under `.github/`;
- `build(deps)` — dependency bumps (normally raised by Dependabot).

`scope` names the area being touched and is strongly encouraged. Commonly used
scopes are `kiwi` (`kiwi/config.xml`, `kiwi/config.sh`, `kiwi/root/`),
`image`, `gnome`, `kernel` (kernel ref and `kernel-configs/`), `firmware`,
`flash`, `make` (`Makefile`), `scripts`, or a specific script name such as
`generate_flat_build`.

Keep the subject short and specific, written in the imperative mood and
without a trailing period. It should capture intent rather than list files.
For example:

- `feat(kiwi): add CodeLinaro qli-rpm repository for self-built bluez`
- `fix(make): fail the image build when kiwi fails`
- `chore(kernel): bump kernel-ref to qcom-6.18.y-20261016`
- `ci: drop unused write permissions from the nightly build`

### Body

Separate the subject from the body with a blank line. The body must:

- be written in plain English;
- first describe the issue or problem being solved, so that a reader can
  understand *why* the change is needed;
- then describe, in the imperative mood ("add", "drop", "enable",
  "update"), what is done to solve it;
- not merely restate *what* the diff changes line by line, since the diff
  already shows that;
- avoid unnecessary bullet lists and prefer prose paragraphs;
- wrap lines at about 72 characters.

When bumping an external reference (kernel ref, boot binaries, firmware,
`qcom-dtb-metadata`, ...), state the old and new versions and why the update
is needed.

## Sign-off and trailers

Every commit must carry a `Signed-off-by` trailer, using the
[Developer Certificate of Origin](https://developercertificate.org/). The
trailer must match the author identity from your local `git config` (use
`git commit -s`). Never make up a name or email address. The commit author
email is checked automatically on every pull request.

If an AI coding assistant or other advanced tool helped create the change,
say so by adding an `Assisted-by` trailer in the form:

```text
Assisted-by: AGENT_NAME:MODEL_VERSION [TOOL1] [TOOL2]
```

`AGENT_NAME` is the name of the AI tool or framework, `MODEL_VERSION` is the
specific model version used, and `[TOOL1] [TOOL2]` are optional specialized
analysis tools. Do not list basic development tools (git, gcc, make,
editors). For example:

```text
Assisted-by: ExampleAgent:example-model-1.0
```

## Coding style

- Follow the style of the file you are editing.
- Shell scripts must start with `set -euo pipefail` (or equivalent) and fail
  loudly. Do not hide errors behind `|| true` or empty fallbacks. Keep them
  free of [ShellCheck](https://www.shellcheck.net/) warnings.
- Python scripts should follow [PEP 8](https://peps.python.org/pep-0008/).
- Every new source file must start with the project copyright and SPDX
  license header, which is verified automatically:

    ```text
    # Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
    # SPDX-License-Identifier: BSD-3-Clause-Clear
    ```

- Pin GitHub Actions to a full commit SHA with the version in a trailing
  comment (e.g. `uses: actions/checkout@<sha> # v6`), and grant workflows
  only the `permissions` they need.
- When you add or change a `make` variable, target or build option, update
  the `help` target in the `Makefile` and [README.md](README.md) as well.

## Testing

There is no unit test suite. Changes are validated by building and booting
images:

- Build the affected image variant(s) locally, e.g. `make image`,
  `make image KIWI_PROFILE=gnome` or `make image PERF_BUILD=1`, and
  `make flash` if you touched the flash artifacts or board packaging.
- For changes that affect what runs on the device, flash and boot the image
  on hardware (e.g. the RB3 Gen2) and check the change works.
- Describe what you built and tested in the pull request.

Every pull request also runs a CI image build (skipped for Markdown-only
changes) and must pass it before merging.

## Security Analysis of Pull Requests

To maintain the security and integrity of this project, every pull request is
automatically run through the QC preflight checks. These include
[Semgrep](https://github.com/semgrep/semgrep) static analysis, dependency
review, repolinter, copyright/license, commit email and commit message checks.

**Static Analysis with Semgrep:** We use Semgrep to run lightweight, fast static analysis on every PR. It helps catch risky code patterns and logic flaws early.

**Contributor Responsibility:** If any issues are flagged, contributors are expected to resolve them before the PR can be merged.

**Continuous Improvement:** Our Semgrep ruleset evolves over time to reflect best practices and emerging security concerns.

By submitting a PR, you agree to take part in this process and help us keep the project secure for everyone.
