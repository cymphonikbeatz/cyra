// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Cyra
//
// ExtractMark.swift
// Reads a full-colour squircle icon (black background, white mark) and outputs
// the mark isolated on a transparent background.  Pixels whose luminance exceeds
// a threshold are treated as mark ink and kept; all others are made transparent.
//
// Usage: swift Tools/ExtractMark.swift <input.png> <output.png>
// Example: swift Tools/ExtractMark.swift "Cyra logo.png" Resources/Brand/logo.png

import AppKit

guard CommandLine.arguments.count == 3 else {
    print("usage: ExtractMark <input.png> <output.png>")
    exit(1)
}

let inPath  = CommandLine.arguments[1]
let outPath = CommandLine.arguments[2]

guard let src = NSImage(contentsOfFile: inPath),
      let srcTIFF = src.tiffRepresentation,
      let srcRep  = NSBitmapImageRep(data: srcTIFF)
else {
    print("could not load \(inPath)")
    exit(1)
}

let w = srcRep.pixelsWide
let h = srcRep.pixelsHigh

// The squircle has a very dark (near-black) background and a pure-white mark.
// Threshold: keep pixels where any channel > 40/255 (~16 %), treating them as
// mark ink.  Retain original alpha so genuine transparency in the source is
// respected.  Output alpha = source alpha × luminance-derived mask.
let threshold: CGFloat = 0.16

guard let dst = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: w, pixelsHigh: h,
    bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0)
else {
    print("could not create output bitmap")
    exit(1)
}

for y in 0..<h {
    for x in 0..<w {
        guard let c = srcRep.colorAt(x: x, y: y) else { continue }
        // Perceptual luminance of the source pixel
        let lum = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        // Use luminance directly as the mark opacity; this gracefully handles
        // anti-aliased edges (grey fringe → semi-transparent white) instead of
        // a hard cut that would produce jagged edges.
        let alpha = min(c.alphaComponent, lum / (1.0 - threshold) )
        let clamped = max(0, min(1, alpha))
        dst.setColor(NSColor(calibratedRed: 1, green: 1, blue: 1, alpha: clamped), atX: x, y: y)
    }
}

guard let data = dst.representation(using: .png, properties: [:]) else {
    print("could not encode output PNG")
    exit(1)
}
do {
    try data.write(to: URL(fileURLWithPath: outPath))
    print("mark written to \(outPath)  (\(w)×\(h))")
} catch {
    print("write error: \(error)")
    exit(1)
}
