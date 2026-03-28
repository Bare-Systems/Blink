# Security Policy

Blink executes deploy and verification actions. Treat target access, credential handling, and rollback behavior as security-sensitive.

## Reporting

Report vulnerabilities privately with:

- manifest shape or command involved
- target type
- expected versus actual access or execution behavior
- any credential, command-injection, or rollback concerns

## Baseline Expectations

- Keep secrets out of manifests where possible; use environment-backed values.
- Prefer explicit, reviewable pipeline behavior over hidden side effects.
- Document target, source, and verifier changes in `README.md` and `BLINK.md`.
