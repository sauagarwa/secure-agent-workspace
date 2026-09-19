#!/usr/bin/env python3
"""Generate an allowlisted binary build context. No build, push or deployment."""
import argparse
import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools/saw'))
from build_guest_bundle import build, load_installer_bom  # noqa: E402


def create_context(output, installer_bom):
    bom = load_installer_bom(installer_bom)
    recipe = (ROOT / 'guest/image/Containerfile.in').read_text()
    for component, selection in bom['spec']['openshell'].items():
        recipe = recipe.replace(f'@{component.upper()}_IMAGE@', selection['image'])
    output = Path(output)
    output.mkdir(mode=0o700, parents=False, exist_ok=False)
    (output / 'Dockerfile').write_text(recipe)
    (output / 'customize.sh').write_bytes((ROOT / 'guest/image/customize.sh').read_bytes())
    bundle_hash = build(output / 'guest.tar.gz', installer_bom)
    manifest = {'installerBOM': bom, 'bundleSHA256': bundle_hash,
                'files': {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                          for p in sorted(output.iterdir())}}
    (output / 'build-inputs.json').write_text(json.dumps(manifest, sort_keys=True, indent=2) + '\n')
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--installer-bom', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    create_context(args.output, args.installer_bom)
    print(f'Image build context: {args.output}; no image built or published')


if __name__ == '__main__':
    main()
