"""Runtime dependency checks with a friendly install hint."""
import importlib


def missing_modules(names):
    missing = []
    for name in names:
        try:
            importlib.import_module(name)
        except ImportError:
            missing.append(name)
    return missing


def install_hint(names):
    return ("Missing required Python packages: %s\n"
            "Install them with:\n    pip install %s"
            % (", ".join(names), " ".join(names)))
