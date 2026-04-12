![App Icon](assets/icon.png?raw=true)
# Rackery

This is a desktop app vibe-coded in Dart, Flutter, and Rust for identifying birds and generating an eBird checklist formatted CSV for import into eBird. EfficientNet-lite is used for detecting birds in photos and BioCLIP for classification. An ebird API Key can optionally be provided to favor identifying for species that are present in the region during the season the photo was taken. Photo metadata is used to determine the date and location of the photo. Runs on Windows and Linux, and should be easy to adapt to run on MacOS. This project is in an early state of development. It currently does not maintain state between sessions (besides the eBird API key). Installer creation is in-progress.

Features in-consideration include: 
- Gallery and photo organization
- Daemon to automate bird identification
- Writing bird detections and classifications into the photo's metadata
- Automated RAW photo processing with limited features
- Researcher focused features such as tagging photos of a specific bird individual
- Manual entry of location and date time information

## Flutter Resources

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

## Rust Setup

- [Rust Installation](https://rust-lang.org/tools/install/)