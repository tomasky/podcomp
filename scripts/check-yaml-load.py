#!/usr/bin/env python3
"""Regenerate the PyYAML loader parity fixture for plain scalars.

`config` prints what the reference prints, and the reference prints
`yaml.safe_dump(yaml.safe_load(file))`. `yaml_dump.mbt` ports the emitter and
`yaml_load.mbt` ports the scalar resolver, so this script runs the same corpus
through PyYAML and stores the result:

    testdata/yaml_scalar_corpus.yaml   hand written, all plain scalars
    testdata/yaml_scalar_expected.txt  `yaml.safe_dump(yaml.safe_load(corpus))`

The test `yaml load matches pyyaml` replays it through `load_yaml_documents`
and `y_dump`, which is what catches a resolver rule drifting from PyYAML.

Run it after editing the corpus, then `moon test`.
"""

import argparse
import os
import sys

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
CORPUS = os.path.join(ROOT, "testdata", "yaml_scalar_corpus.yaml")
EXPECTED = os.path.join(ROOT, "testdata", "yaml_scalar_expected.txt")


def render() -> str:
    with open(CORPUS) as handle:
        corpus = handle.read()
    return yaml.safe_dump(yaml.safe_load(corpus), default_flow_style=False, sort_keys=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="fail instead of writing when the fixture is out of date",
    )
    args = parser.parse_args()

    expected = render()
    if args.check:
        with open(EXPECTED) as handle:
            have = handle.read()
        if have != expected:
            print(
                "out of date: %s" % os.path.relpath(EXPECTED, ROOT),
                file=sys.stderr,
            )
            return 1
        return 0

    with open(EXPECTED, "w") as handle:
        handle.write(expected)
    print("wrote %s" % os.path.relpath(EXPECTED, ROOT))
    return 0


if __name__ == "__main__":
    sys.exit(main())
