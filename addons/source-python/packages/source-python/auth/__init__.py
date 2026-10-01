# ../auth/__init__.py

"""Provides Authorization specific functionality."""

# =============================================================================
# >> IMPORTS
# =============================================================================
# Source.Python Imports
#   Loggers
from loggers import _sp_logger
#   Translations
from translations.strings import LangStrings
#   Paths
from paths import AUTH_CFG_PATH


# =============================================================================
# >> GLOBAL VARIABLES
# =============================================================================
# Get the sp.auth logger
auth_logger = _sp_logger.auth

# Recursively create the authorization config directory (and any missing
# parents) so a clean installation can bootstrap itself. makedirs_p() is
# idempotent and does not raise if the directory already exists.
AUTH_CFG_PATH.makedirs_p()
