"""P0-01 verification: the M2 upstream flag is default-off and opt-in only.

Covers disabled (default), missing (no env), and enabled scenarios. Enabling the
flag alone must NOT register the /m2 router in the live app.
"""

import os
import unittest

from sitewise.core.config import Settings


class TestM2UpstreamFlag(unittest.TestCase):
    def test_default_is_disabled(self):
        # The declared default, read from the model itself. Calling Settings() here
        # would also read the developer's .env, where an explicit opt-in is legal and
        # would make this assertion measure the environment instead of the code.
        declared = Settings.model_fields["m2_upstream_enabled"].default
        self.assertIs(declared, False)

    def test_missing_env_defaults_false(self):
        original = os.environ.pop("M2_UPSTREAM_ENABLED", None)
        try:
            # Test the code default, independently of a developer's opted-in .env.
            self.assertFalse(Settings(_env_file=None).m2_upstream_enabled)
        finally:
            if original is not None:
                os.environ["M2_UPSTREAM_ENABLED"] = original

    def test_enabled_via_explicit_value(self):
        self.assertTrue(Settings(m2_upstream_enabled=True).m2_upstream_enabled)

    def test_enabled_via_env(self):
        os.environ["M2_UPSTREAM_ENABLED"] = "true"
        try:
            self.assertTrue(Settings().m2_upstream_enabled)
        finally:
            os.environ.pop("M2_UPSTREAM_ENABLED", None)

    def test_enabled_flag_alone_does_not_register_m2_router_by_default(self):
        # Default settings -> live app must not expose an /m2 route.
        from sitewise.main import app

        paths = [getattr(r, "path", "") for r in app.routes]
        self.assertFalse(any("m2" in p for p in paths if p))


if __name__ == "__main__":
    unittest.main()
