//
//  SDUIInlineMarkup.swift
//  Encore
//
//  Splits a resolved text string into plain and highlighted runs on `*...*`
//  markers, so a single server-supplied string can carry one accent-colored
//  word. `segments` already covers multi-run text the SERVER composes, but a
//  value substituted from one placeholder (`${rewardHeadline}`) arrives as one
//  opaque string — the only place left to express "colour this word" is inside
//  the copy itself.
//

import Foundation

/// Parser for the inline highlight marker. Pure and side-effect free so the
/// rules are unit-testable without a renderer or a running app.
enum SDUIInlineMarkup {
    /// One stretch of text and whether it was marked for the highlight color.
    struct Run: Equatable {
        let text: String
        let isHighlighted: Bool
    }

    /// The delimiter. Single asterisk rather than markdown's `**` because the
    /// copy is written by humans in a CMS field, not by a markdown author.
    private static let marker: Character = "*"

    /// Splits `text` on balanced `*…*` pairs.
    ///
    /// Deliberately conservative — this runs on publisher-authored copy, so the
    /// failure mode has to be "renders as typed", never "eats the sentence":
    /// - An unmatched marker is literal: `"5 * 3"` stays `"5 * 3"`.
    /// - An empty pair `**` contributes nothing but is still consumed.
    /// - Nesting is not a concept; the first close ends the run.
    ///
    /// Returns a single un-highlighted run when there is nothing to mark, which
    /// is what lets the caller treat "no markup" and "no `highlightColor`" as
    /// the same, unchanged path.
    static func parse(_ text: String) -> [Run] {
        guard text.contains(marker) else {
            return [Run(text: text, isHighlighted: false)]
        }

        var runs: [Run] = []
        var current = ""
        var pendingHighlight: String? = nil

        for character in text {
            guard character == marker else {
                if pendingHighlight != nil {
                    pendingHighlight?.append(character)
                } else {
                    current.append(character)
                }
                continue
            }

            if let highlighted = pendingHighlight {
                // Closing marker: flush the plain text before it, then the run.
                if !current.isEmpty {
                    runs.append(Run(text: current, isHighlighted: false))
                    current = ""
                }
                if !highlighted.isEmpty {
                    runs.append(Run(text: highlighted, isHighlighted: true))
                }
                pendingHighlight = nil
            } else {
                // Opening marker: start buffering a candidate run.
                pendingHighlight = ""
            }
        }

        // An unclosed run never happened — put the marker and its text back
        // verbatim rather than silently highlighting to end of string.
        if let unclosed = pendingHighlight {
            current.append(marker)
            current.append(unclosed)
        }
        if !current.isEmpty {
            runs.append(Run(text: current, isHighlighted: false))
        }

        return runs.isEmpty ? [Run(text: "", isHighlighted: false)] : coalesced(runs)
    }

    /// Merges neighbouring runs that share a style, so an empty `**` pair or a
    /// dropped marker never leaves two identically-styled runs behind. Keeps the
    /// contract simple — adjacent runs always differ — and saves the renderer a
    /// pointless `Text` concatenation.
    private static func coalesced(_ runs: [Run]) -> [Run] {
        runs.reduce(into: [Run]()) { result, run in
            if let last = result.last, last.isHighlighted == run.isHighlighted {
                result[result.count - 1] = Run(
                    text: last.text + run.text,
                    isHighlighted: last.isHighlighted
                )
            } else {
                result.append(run)
            }
        }
    }

    /// Whether `text` contains at least one balanced pair worth styling.
    /// Lets the renderer skip building concatenated `Text` when there is
    /// nothing to highlight.
    static func hasHighlight(_ text: String) -> Bool {
        parse(text).contains { $0.isHighlighted }
    }
}
