# Changelog

## [0.1.3]

### Fixed

- Inverted logic in `apply_fixes`
- Problems with Julia 1.12.* versions
- Compatibility with different Compiler implementations

### Added

- Configuration option for how many errors and warnings shall be printed

## [0.1.2]

### Added

- Control colorization with `color`
- By default print only first error, control with `only_first_error`.
- Implement `progress_bar` option, also checking if it is running in CI.
- Rename macro to `@validate`.
- Make function `validate` public.

## [0.1.1]

### Added

- Add progress bar to visualize progress ([#4]).
- Add coloring to the output to highlight problematic types ([#5]).
