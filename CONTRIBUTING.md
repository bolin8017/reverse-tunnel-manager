# Contributing

Thank you for considering contributing to Reverse Tunnel Manager.

## Getting Started

1. Fork the repository.
2. Clone your fork and create a new branch from `main`.
3. Make your changes.
4. Run the checks before submitting:

```bash
make check    # Syntax check
make lint     # ShellCheck
```

## Coding Standards

This project follows the
[Google Shell Style Guide](https://google.github.io/styleguide/shellguide.html).
Key points:

- **Indent** with 2 spaces (no tabs).
- Wrap top-level logic in a `main()` function.
- Use `readonly` for constants and `local` for function variables.
- Use `printf` instead of `echo -e`.
- Send warnings and errors to `stderr`.
- Validate user-supplied port numbers with `validate_port()`.

## Pull Requests

- Keep PRs focused on a single change.
- Include a clear description of what and why.
- Ensure CI passes (ShellCheck + syntax check).
- Update documentation if behavior changes (both English and `docs/zh-tw/`).

## Reporting Bugs

Use the [Bug Report](https://github.com/bolin8017/reverse-tunnel-manager/issues/new?template=bug_report.md)
issue template.

## Suggesting Features

Use the [Feature Request](https://github.com/bolin8017/reverse-tunnel-manager/issues/new?template=feature_request.md)
issue template.
