# Release the Homebrew dashboard

The dashboard has a separate release track from the original menu-bar application.
The public Homebrew tap is `ryan-mahoney/homebrew-tap`.

## Prepare a release

1. Update `__version__` in `ai_capacity/__init__.py`.
2. Run the offline checks:

   ```bash
   python3 -m unittest discover -s Tests/CapacityDashboardTests -p 'test_*.py' -v
   node --check ai_capacity/static/app.js
   make check
   make test
   ```

3. Commit the changes and push them to the fork.
4. Create and push a matching tag. For example:

   ```bash
   git tag ai-capacity-v0.1.0
   git push origin ai-capacity-v0.1.0
   ```

The `Release AI capacity` workflow builds the Swift CLI on an Apple Silicon runner.
It packages only the selected application files, static assets, resource bundle, and license notices.
It does not package credentials, local configuration, `.data`, Python caches, or build caches.
The workflow attaches the archive to a GitHub release. Manual workflow runs create an artifact without a release.

## Update the tap

1. Download the archive from the completed release.
2. Calculate its SHA-256 checksum with `shasum -a 256`.
3. Update the version, release URL, and checksum in the tap's `Formula/ai-capacity.rb`.
4. Commit and push the tap changes.
5. Run the published installation checks:

   ```bash
   brew update
   brew install ryan-mahoney/tap/ai-capacity
   brew test ryan-mahoney/tap/ai-capacity
   ai-capacity --version
   ai-capacity-report report --help
   ```

If the package is already installed, use `brew upgrade ai-capacity` instead of `brew install`.
The formula test uses synthetic data. It must not request real account credentials or contact a provider.

## Package layout

Homebrew stores the payload in the formula's `libexec` directory.
The `ai-capacity` launcher uses Homebrew's Python and the installed `launch.py` file.
The report executable and its resource bundle stay together in `libexec/report-cli`.
The `ai-capacity-report` wrapper gives direct access without replacing the upstream `codexbar` command.

The first release supports Apple Silicon Macs only. Add and verify a separate archive before declaring another architecture supported.
