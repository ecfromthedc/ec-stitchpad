# Shared prompt instructions

`ponytail.md` is the one canonical copy used by every Stitchpad/Pasture runtime.
It is adapted from [DietrichGebert/ponytail](https://github.com/DietrichGebert/ponytail)
at commit `16f29800fd2681bdf24f3eb4ccffe38be3baec6b` and is distributed under the
MIT license in `LICENSE.ponytail`.

The shell builder in `bin/lib.sh` injects this fragment exactly once. The default
mode is `full`; set `STITCHPAD_PONYTAIL_MODE=off` (or
`PONYTAIL_DEFAULT_MODE=off`) for a runtime that must opt out. No global install
or user configuration is required.
