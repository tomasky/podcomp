#!/usr/bin/env python3
"""Regenerate the PyYAML parity fixtures for `y_dump`.

`config` prints what the reference prints, and the reference prints
`yaml.safe_dump(compose)`. `yaml_dump.mbt` ports that emitter, and the test
`yaml dump matches pyyaml` replays this corpus through it, so this script is the
source of truth for both files under `testdata/`:

    testdata/yaml_dump_corpus.yaml    one mapping of case name -> value
    testdata/yaml_dump_expected.txt   `--CASE <name>` followed by safe_dump

Run it after changing the emitter, then `moon test`.

Two PyYAML behaviours are deliberately *not* covered, because they cannot be
observed through this project's loader:

  * very large floats: MoonBit prints `1e16` as `10000000000000000.0`, Python's
    `repr` switches to `1.0e+16`;
  * empty mapping keys: PyYAML emits `? ''`, which the MoonBit YAML loader
    rejects.

Both need a compose file that is pathological in the same way, and neither
changes what `config` prints for a real one.
"""

import argparse
import os
import sys

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
CORPUS = os.path.join(ROOT, "testdata", "yaml_dump_corpus.yaml")
EXPECTED = os.path.join(ROOT, "testdata", "yaml_dump_expected.txt")

CASES = {
    # Plain scalars that stay plain.
    "plain": "secret",
    "port": "8080:80",
    "mount": "./html:/usr/share/nginx/html:ro",
    "brace_str": "a{b}",
    "star_str": "x*",
    "comma_str": "a,b",
    "bracket_str": "a[b]",
    "colon_nospace": "x:y",
    "hash_end": "x#",
    "dash_end": "x-",
    "dollar": "$HOME",
    "dbl_space": "a  b",
    # Strings that have to be quoted.
    "bool_str": "true",
    "int_str": "123",
    "sexagesimal_str": "12:30",
    "date_str": "2024-01-01",
    "ts_str": "2024-01-01 10:00:00",
    "colon_space": "a: b",
    "dash_space": "- x",
    "empty_str": "",
    "hash_space": "a # b",
    "leading_space": " lead",
    "trailing_space": "trail ",
    "quote_single": "it's",
    "question_space": "? x",
    "tilde_str": "~",
    "question_str": "?",
    "single_dash": "-",
    "dot_inf_str": ".inf",
    "eq_str": "=",
    "merge_str": "<<",
    "at_str": "@x",
    "backtick_str": "`x",
    "percent": "%YAML",
    "amp": "&anchor",
    "bang": "!tag",
    "pipe": "|x",
    "gt": ">x",
    "three_dots": "...",
    "three_dashes": "---",
    "only_spaces": "   ",
    "one_space": " ",
    "under_int_str": "1_000",
    "octalish_str": "0b101",
    "quote_double": 'say "hi"',
    "both_quotes": "a'b\"c",
    "backslash": "a\\b",
    "tab": "a\tb",
    "cr": "a\rb",
    "nul": "a\x00b",
    "esc": "a\x1bb",
    "del": "a\x7fb",
    "nel": "a\x85b",
    "ls": "a\u2028b",
    "bom": "\ufeff",
    "nbsp": "\u00a0",
    "unicode": "h\u00e9llo",
    "emoji": "a\U0001F600b",
    "bmp_high": "\uffff",
    "newline": "a\nb",
    "multi": "a\n\nb",
    # Line wrapping at the 80 column mark.
    "long_plain": "word " * 25 + "end",
    "long_nospace": "x" * 200,
    "long_quoted": "1.5 " * 25,
    "long_quoted_words": (
        "this is a long single quoted string that has enough words to wrap "
        "over the width limit"
    ),
    "wrap_boundary": "x" * 79 + " y",
    "wrap_boundary2": "x" * 78 + " yy",
    "nested_wrap": {"a": {"b": {"c": "word " * 25 + "end"}}},
    "seq_wrap": ["word " * 25 + "end"],
    "long_seq_items": {"cmd": ["word " * 30, "x" * 100, "short"]},
    "long_quoted_seq": ["1.5 " * 30],
    "long_double": ["a\tb " * 20],
    "long_key": {"k" * 130: 1},
    "long_key_nested": {"a": {"k" * 140: 1}},
    # Collection shapes.
    "empty_map": {},
    "empty_seq": [],
    "empties": {"a": None, "b": [], "c": {}, "d": ""},
    "empty_in_seq": [[], {}, ""],
    "seq_of_seq": [[1, 2], [3, [4, 5]]],
    "seq_of_map": [{"f": 1, "g": {"h": 2}}, {"i": [3, 4]}],
    "seq_in_seq_in_map": {"a": [["x"]]},
    "map_in_seq_in_map": {"a": [{"b": {"c": 1}}]},
    "deep_list": {"a": [[1]]},
    "deep": {"a": {"b": {"c": {"d": {"e": {"f": [1, 2, 3]}}}}}},
    "nested": {"a": {"b": {"c": [1, 2, {"d": []}]}}},
    "key_sort": {"b": 1, "a": 2, "M": 3, "z": 4, "_x": 5, ".": 6},
    "quoted_key": {"a: b": 1, "true": 2, "123": 3},
    "list_in_map": {"cmd": ["echo", "hello"]},
    # Scalars of every type.
    "int": 42,
    "neg": -7,
    "zero": 0,
    "bool": True,
    "false": False,
    "null": None,
    "float": 1.5,
    "float_int": 2.0,
    "float_zero": 0.0,
    "float_neg": -0.0,
    "float_small": 0.001,
    "float_exp": 1.5e-7,
    "float_100": 100.0,
    "float_tenth": 0.1,
}


def render() -> tuple[str, str]:
    """Return (corpus YAML, expected dump text)."""
    corpus = yaml.safe_dump(CASES, default_flow_style=False, sort_keys=True)
    lines = []
    for name in sorted(CASES):
        lines.append("--CASE %s\n" % name)
        lines.append(yaml.safe_dump(CASES[name], default_flow_style=False, sort_keys=True))
    return corpus, "".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="fail instead of writing when the fixtures are out of date",
    )
    args = parser.parse_args()

    corpus, expected = render()
    if args.check:
        ok = True
        for path, want in ((CORPUS, corpus), (EXPECTED, expected)):
            with open(path) as handle:
                have = handle.read()
            if have != want:
                print("out of date: %s" % os.path.relpath(path, ROOT), file=sys.stderr)
                ok = False
        return 0 if ok else 1

    os.makedirs(os.path.dirname(CORPUS), exist_ok=True)
    with open(CORPUS, "w") as handle:
        handle.write(corpus)
    with open(EXPECTED, "w") as handle:
        handle.write(expected)
    print("wrote %s and %s" % (os.path.relpath(CORPUS, ROOT), os.path.relpath(EXPECTED, ROOT)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
