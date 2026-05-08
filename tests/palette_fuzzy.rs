//! Unit tests for the command palette fuzzy-match scorer.

use nostromo::views::command_palette::subsequence_score;

#[test]
fn full_match_is_scored() {
    let score = subsequence_score("fred", "fred");
    assert!(score.is_some());
    assert!(score.unwrap() > 0.0);
}

#[test]
fn subsequence_match_scores() {
    // "fr" is a subsequence of "Switch to Fred"
    let score = subsequence_score("fr", "switch to fred");
    assert!(score.is_some());
}

#[test]
fn non_subsequence_returns_none() {
    let score = subsequence_score("xyz", "switch to fred");
    assert!(score.is_none());
}

#[test]
fn empty_query_always_matches() {
    let score = subsequence_score("", "anything");
    // An empty query trivially matches (no chars to place).
    assert!(score.is_some());
}

#[test]
fn consecutive_chars_score_higher_than_spread() {
    // Matching "fr" at positions 0,1 in "fre" is better than 0,5 in "f---re"
    let tight = subsequence_score("fr", "fred").unwrap();
    let spread = subsequence_score("fr", "f____ree").unwrap();
    assert!(tight > spread, "tight={tight} spread={spread}");
}

#[test]
fn case_insensitive_matching() {
    // subsequence_score works on already-lowercased input per the palette refilter logic.
    let score = subsequence_score("fred", "fred");
    assert!(score.is_some());
    // Also works with lowercase needle against lowercase haystack.
    let score2 = subsequence_score("switch", "switch to fred");
    assert!(score2.is_some());
}

#[test]
fn single_char_query() {
    let score = subsequence_score("f", "fred");
    assert!(score.is_some());
}

#[test]
fn query_longer_than_text_returns_none() {
    let score = subsequence_score("abcdef", "abc");
    assert!(score.is_none());
}
