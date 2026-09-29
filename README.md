# hexstickers

Hex stickers for CRAN packages, collected automatically and cleaned up so they
can be used side by side.

There are two stages:

1. `download_hexes.R` searches for a logo for every CRAN package and saves
   what it finds to `raw/`.
2. `standardise_hexes.py` works out which of those logos are hex stickers.
   It gives each one a transparent background and a standard size, and saves
   it to `hexstickers/`.

## What's here

| Path | Contents |
|------|----------|
| `raw/` | Logos as downloaded: 4,024 PNGs and 802 SVGs. Not all of them are hexes. |
| `raw/manifest.csv` | One row per attempt: package, status, source URL, files, time. |
| `hexstickers/` | 3,627 standardised hex PNGs, plus 724 matching SVGs copied unchanged. |
| `hexstickers/report.csv` | Hex score for every PNG in `raw/`, with the verdict. |

In the latest manifest, 25,223 packages have been checked:
4,020 logos were found, 21,103 packages had none, 90 failed and 10 crashed.

## Requirements

- R with `hexFinder`, `magick`, `httr2` and `R.utils`
- Python 3 with `Pillow`, `numpy` and `scipy`
- `optipng` (optional, but used by default)
- A GitHub token in `GITHUB_PAT` or `github_pat`. The search makes a lot of
  GitHub API calls, and the anonymous limit is 60 an hour.

## Downloading logos

```sh
Rscript download_hexes.R                  # all CRAN packages
Rscript download_hexes.R 20               # first 20 packages
Rscript download_hexes.R ggplot2 dplyr    # named packages
Rscript download_hexes.R --no-optipng 20  # skip PNG optimisation
```

For each package the script tries hexFinder's list of known packages and
repos. If that finds nothing, it searches the package's GitHub repository,
taken from the `URL` or `BugReports` field. When it finds a logo, it also looks
for the other format nearby, so it can save a PNG and an SVG. A JPEG is
converted to PNG, even when it was served with a `.png` name. An SVG with no
matching PNG is rendered to one at 600 px wide.

Progress goes to `raw/manifest.csv` after every package, so a stopped run
picks up where it left off. Packages that ended in an error are tried again
next time. If a package brought down the whole R process (ImageMagick
sometimes aborts), it is marked `crash` and skipped from then on.

The script checks the GitHub rate limit itself and sleeps until the limit
resets. hexFinder hides HTTP errors, so without this check a rate-limited
request would be recorded as "no logo".

A full run takes many hours. `run_all.sh` restarts the script after a hard
crash, up to 200 times:

```sh
nohup ./run_all.sh >> raw/run.log 2>&1 &
```

## Standardising the hexes

```sh
python3 standardise_hexes.py                # every PNG in raw/
python3 standardise_hexes.py ggplot2 dplyr  # named packages
python3 standardise_hexes.py --no-optipng
```

For each PNG in `raw/`, the script:

1. Removes any solid or semi-transparent background that touches the image
   edge.
2. Crops to what is left and compares its outline with an ideal hexagon, both
   point-up and flat-top. The score is the overlap between the two shapes
   (intersection over union).
3. Counts the image as a hex if the score is at least 0.90, or at least 0.85
   when the proportions are close to a true hex.
4. Resizes each hex to 518×600 (600×518 for the 38 flat-top ones) and trims
   it to a clean hexagon edge, so everything outside is transparent.

The full set takes about 12 minutes on 8 cores.

### Known limitations

- Slightly squashed hexes are stretched to the standard shape, which distorts
  their content a little. The `ratio` column in `report.csv` shows how far
  each one was out.
- Artwork that sticks out past the hexagon edge is cut off.
- Many sources are only 240×278, so they look soft once scaled up.
- Hexes on gradient or photographic backgrounds aren't detected. Neither are
  hexes drawn inside a box. Examples include makepipe, FoRDM, profileR and
  aggTrees. To review the near misses, filter `report.csv` to `not_hex` and
  sort by `iou`, highest first.
- A few octagons pass as hexes, including morestopwords, sdsfun and clockplot.

## Licensing

The logos belong to their packages' authors. Check each package's licence and
branding terms before reusing a logo.
