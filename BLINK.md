# Blink Blink Status

Blink is the deployment tool itself and does not currently use a project-local `blink.toml` to deploy its own repository.

## Current State

- Build and test are local Ruby workflows.
- The repository implements the `blink.toml` engine used by other BareSystems projects.
- The workspace root `blink.toml` and the service manifests in sibling projects are the real production manifests that exercise this tool.

## What This Means

- There is no project-local Blink deploy pipeline for the Blink repo itself today.
- This file exists to document that status explicitly and to keep the repo aligned with the shared documentation contract.
