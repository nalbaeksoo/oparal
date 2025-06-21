# AGENTS Instructions

This repository contains a Bash script `oparal.sh` used for running shell or SQL files in parallel. When modifying this project:

- Use `bash` and `awk` only; avoid external dependencies.
- Keep variable and option names in `snake_case` for consistency.
- Run the following checks before committing:
  - `bash -n oparal.sh`
  - `./oparal.sh -h | head -n 10`
- Summarize changes and include test results in the PR description.

