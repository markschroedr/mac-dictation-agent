import unittest

try:
    from asr_worker.stitching import commit_new_text, remove_prefix_overlap
except ModuleNotFoundError as error:
    if error.name != "asr_worker":
        raise
    from stitching import commit_new_text, remove_prefix_overlap


class RemovePrefixOverlapTests(unittest.TestCase):
    def test_exact_overlap_is_removed(self):
        self.assertEqual(
            remove_prefix_overlap(
                "Please send the final report today",
                "the final report today before lunch",
            ),
            "before lunch",
        )

    def test_minimum_length_overlap_counts_original_punctuation(self):
        self.assertEqual(
            remove_prefix_overlap("We said Hello, world", "Hello, world again"),
            "again",
        )

    def test_partial_overlap_is_removed(self):
        self.assertEqual(
            remove_prefix_overlap(
                "The quick brown fox jumps over",
                "brown fox jumps over the lazy dog",
            ),
            "the lazy dog",
        )

    def test_no_overlap_returns_current_text(self):
        self.assertEqual(
            remove_prefix_overlap("The first thought is complete", "A new idea starts here"),
            "A new idea starts here",
        )

    def test_overlap_ignores_case_and_punctuation(self):
        self.assertEqual(
            remove_prefix_overlap(
                "We discussed Alpha, Beta, and Gamma.",
                "ALPHA beta and gamma; before lunch.",
            ),
            "before lunch.",
        )

    def test_empty_inputs(self):
        self.assertEqual(remove_prefix_overlap("", "  Keep this text.  "), "Keep this text.")
        self.assertEqual(remove_prefix_overlap("Existing text", ""), "")
        self.assertEqual(remove_prefix_overlap("", ""), "")

    def test_repeated_words_in_overlap_are_preserved_once(self):
        self.assertEqual(
            remove_prefix_overlap(
                "She said go go to the store",
                "go go to the store before noon",
            ),
            "before noon",
        )

    def test_partial_word_match_does_not_drop_a_real_word(self):
        # The old character-suffix algorithm incorrectly returned
        # "creates translation bugs" by matching "nationalization" inside
        # the end of "internationalization".
        current = "nationalization creates translation bugs"
        self.assertEqual(
            remove_prefix_overlap("We discussed internationalization", current),
            current,
        )


class CommitNewTextTests(unittest.TestCase):
    def test_commits_only_new_text_across_chunks(self):
        session_id = "commit-overlap-session"
        self.assertEqual(
            commit_new_text(session_id, "She said go go to the store"),
            "She said go go to the store",
        )
        self.assertEqual(
            commit_new_text(session_id, "go go to the store before noon"),
            "before noon",
        )
        self.assertEqual(
            commit_new_text(session_id, "the store before noon and buy milk"),
            "and buy milk",
        )

    def test_empty_chunk_does_not_change_session_history(self):
        session_id = "commit-empty-session"
        self.assertEqual(commit_new_text(session_id, "A complete opening sentence"), "A complete opening sentence")
        self.assertEqual(commit_new_text(session_id, ""), "")
        self.assertEqual(
            commit_new_text(session_id, "opening sentence with a continuation"),
            "with a continuation",
        )


if __name__ == "__main__":
    unittest.main()
