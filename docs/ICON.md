# App icon

The project uses dedicated project artwork created for Screen Privacy. Its source is `Assets/AppIcon.png`; the brand logo is `Assets/Logo.png`; the macOS bundle icon is `Packaging/AppIcon.icns`.

Local and release builds include the bundled icon automatically. The menu bar uses an adaptive monochrome SF Symbol so its appearance follows system settings.

## Replace or rebuild

1. Replace `Assets/AppIcon.png` with the intended square PNG artwork.
2. Run `./scripts/build-icon.sh` to create all macOS icon sizes in a new timestamped artifacts directory.
3. Review the result and copy the generated `.icns` to `Packaging/AppIcon.icns`.
4. Rebuild the app.

The script uses macOS `sips` and `iconutil` and refuses to overwrite an existing output directory. No image-generation service or API credentials are required to build this project.
