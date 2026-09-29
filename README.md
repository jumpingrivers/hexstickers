# hexstickers

Hex stickers for CRAN packages, downloaded automatically and standardised.

| Path | Contents |
|------|----------|
| `raw/` | Logos as downloaded (4,024 PNGs, 802 SVGs), with `manifest.csv` |
| `hexstickers/` | 3,627 hexes: transparent 518×600 PNGs, matching SVGs, `report.csv` |

## Requirements

- R: `hexFinder`, `magick`, `httr2`, `R.utils`
- Python 3: `Pillow`, `numpy`, `scipy`
- `optipng` (optional)
- A GitHub token in `GITHUB_PAT`

## Usage

```sh
Rscript download_hexes.R                  # all CRAN packages (many hours)
Rscript download_hexes.R ggplot2 dplyr    # named packages
nohup ./run_all.sh >> raw/run.log 2>&1 &  # full run, restarts after crashes

python3 standardise_hexes.py              # rebuild hexstickers/ (~12 min)
python3 standardise_hexes.py ggplot2      # named packages
```

Both scripts take `--no-optipng`. The download resumes from
`raw/manifest.csv` and waits out GitHub rate limits.

`standardise_hexes.py` removes each logo's background and scores its outline
against an ideal hexagon. Close matches (thresholds at the top of the script)
are kept, resized and trimmed to a clean hex edge.

## Limitations

- Squashed hexes are stretched, and artwork past the hex edge is cut off.
- Hexes on gradient or boxed backgrounds are missed. See `not_hex` rows in
  `report.csv`, sorted by `iou`.
- A few octagons get through.

Logos belong to their packages' authors. Check the licence before reusing one.
