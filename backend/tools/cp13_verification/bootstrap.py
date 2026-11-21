"""Use this checkout and its existing Python environment; never load the web app."""
from pathlib import Path
import os
import sys

PACKAGE = Path(__file__).resolve().parent
if os.environ.get('CP13_PROJECT_ROOT'):
    ROOT = Path(os.environ['CP13_PROJECT_ROOT']).expanduser().resolve()
else:
    ROOT = next((p for p in PACKAGE.parents if (p/'backend/src/sitewise').is_dir()), None)
if ROOT is None or not (ROOT/'backend/src/sitewise').is_dir():
    raise SystemExit('Set CP13_PROJECT_ROOT to the existing Project1 checkout; no alternate implementation is created.')
BACKEND = ROOT/'backend'
sys.path.insert(0, str(BACKEND / 'src'))

def configure():
    # Explicit absolute paths make execution independent of the caller's cwd.
    # No environment files or runtime settings are rewritten.
    from sitewise.core import config
    loaded = config.Settings(_env_file=(BACKEND / '.env', BACKEND / '.env.local'))
    for name in type(loaded).model_fields:
        setattr(config.settings, name, getattr(loaded, name))
    return config.settings
