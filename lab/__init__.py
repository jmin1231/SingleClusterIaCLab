"""The lab's Python package."""

from importlib.metadata import PackageNotFoundError, version

# Read back from the installed metadata rather than declared here. pyproject.toml
# is the single source of the version; a second copy in this file drifts the
# first time one is bumped, and a --version that lies is worse than none.
try:
    __version__ = version("lab")
except PackageNotFoundError:
    # The source tree exists but was never `pip install`ed — so there is no
    # metadata to read. Says so rather than guessing.
    __version__ = "0+unknown"
