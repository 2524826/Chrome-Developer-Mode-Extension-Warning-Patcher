# Minimal unpacked extension fixture

1. Start the exact supported Edge build with a disposable profile.
2. Open `edge://extensions`, enable **Developer mode**, choose **Load unpacked**, and select this directory.
3. Restart Edge and record whether the developer-mode warning panel appears.
4. After an authorized patch installation, repeat with the same extension and a fresh disposable profile.

The extension requests no permissions, changes no pages, and exists only to make the warning reproducible.
