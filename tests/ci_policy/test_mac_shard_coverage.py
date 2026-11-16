"""Every Mac test class must run in exactly one shard, and the slow Review* classes stay pinned.

Shard 3 is the catch-all, so a class cannot normally drop out; these tests pin that property
against the real config and the real test sources, and prove the check can fail.
"""

import os
import sys
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import mac_shards as ms  # noqa: E402

PINNED_TO_LISTED_SHARDS = {
    "ReviewWebViewIntegrationTests",  # real WKWebView, ~6-7 min alone: must not land in the catch-all
    "ReviewNavigationPolicyTests",
    "ReviewPaneAccessibilityTests",
    "ReviewPaneHostsTests",
    "ReviewPaneModelTests",
    "ReviewPaneRedactionTests",
    "ReviewPaneStoreTests",
}


def runners_by_class(config, known):
    """{class: [shard numbers that would run it]} from the xcodebuild args of each shard."""
    runs = {c: [] for c in known}
    for shard in range(1, ms.SHARD_COUNT + 1):
        args = ms.xcodebuild_args(config, shard)
        only = {a.split("/", 1)[1] for a in args if a.startswith("-only-testing:")}
        skip = {a.split("/", 1)[1] for a in args if a.startswith("-skip-testing:")}
        for cls in known:
            if (only and cls in only) or (not only and cls not in skip):
                runs[cls].append(shard)
    return runs


class MacShardCoverageTests(unittest.TestCase):
    def setUp(self):
        self.config = ms.load_config(ms.DEFAULT_CONFIG)
        self.known = ms.discover_classes(ms.DEFAULT_TESTS_DIR)

    def test_every_test_class_runs_in_exactly_one_shard(self):
        for cls, shards in runners_by_class(self.config, self.known).items():
            self.assertEqual(len(shards), 1, "%s runs in shards %s" % (cls, shards))

    def test_slow_review_classes_are_pinned_to_a_listed_shard(self):
        listed = {c for s in self.config["shards"][:-1] for c in s["classes"]}
        self.assertEqual(sorted(PINNED_TO_LISTED_SHARDS - listed), [])

    def test_web_view_integration_is_not_with_the_other_heavy_review_classes(self):
        shard_of = {c: i for i, s in enumerate(self.config["shards"][:-1]) for c in s["classes"]}
        self.assertNotEqual(
            shard_of["ReviewWebViewIntegrationTests"], shard_of["ReviewPaneModelTests"]
        )

    def test_check_bites_when_a_class_is_in_no_shard(self):
        broken = {"shards": [{"classes": ["A"]}, {"classes": ["B"]}, {"catch_all": True}]}
        # catch-all skips A and B; a class the sources know but nothing runs would show as []
        runs = runners_by_class(broken, {"A", "B", "C"})
        self.assertEqual(runs["C"], [3])
        runs = runners_by_class(
            {"shards": [{"classes": ["A"]}, {"classes": ["A"]}, {"catch_all": True}]}, {"A", "B"}
        )
        self.assertEqual(runs["A"], [1, 2])  # double-run is detected too


if __name__ == "__main__":
    unittest.main()
