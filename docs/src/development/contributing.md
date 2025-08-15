# Contributing to ZiggyDB

Thank you for your interest in contributing to ZiggyDB! We appreciate your help in making this project better.

## Getting Started

1. Fork the repository on GitHub
2. Clone your fork locally
3. Set up the development environment (see [Building from Source](./building.md))
4. Create a new branch for your changes
5. Make your changes and write tests
6. Run the test suite to ensure everything passes
7. Submit a pull request

## Code Style

We follow the [Zig Style Guide](https://ziglang.org/documentation/master/#Style-Guide) with the following additions:

- Use 4 spaces for indentation
- Maximum line length of 100 characters
- Document all public APIs with doc comments
- Write tests for new functionality

## Commit Messages

Follow the [Conventional Commits](https://www.conventionalcommits.org/) specification:

```
<type>[optional scope]: <description>

[optional body]

[optional footer(s)]
```

### Types

- `feat`: A new feature
- `fix`: A bug fix
- `docs`: Documentation only changes
- `style`: Changes that do not affect the meaning of the code
- `refactor`: A code change that neither fixes a bug nor adds a feature
- `perf`: A code change that improves performance
- `test`: Adding missing tests or correcting existing tests
- `chore`: Changes to the build process or auxiliary tools

## Testing

Run the test suite with:

```bash
zig build test
```

## Pull Requests

1. Keep pull requests focused on a single feature or bug fix
2. Include tests for new functionality
3. Update documentation as needed
4. Ensure all tests pass
5. Reference any related issues in the PR description

## Code Review

- Be respectful and constructive in code reviews
- Focus on the code, not the person
- Explain your reasoning when requesting changes
- Be open to feedback and discussion

## Reporting Issues

When reporting issues, please include:

1. A clear description of the problem
2. Steps to reproduce the issue
3. Expected behavior
4. Actual behavior
5. Environment details (OS, Zig version, etc.)

## License

By contributing to ZiggyDB, you agree that your contributions will be licensed under the project's [MIT License](../LICENSE).
