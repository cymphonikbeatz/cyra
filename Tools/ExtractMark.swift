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

// The squircle icon has a dark background (luminance ~0.02) and a white mark.
// The mark itself is located within x, y in [175..845]. Everything outside
// this region belongs to the squircle container, rounded corners, or rim
// specular highlights and must be discarded.
//
// Inside the mark region:
// - Background floor: luminance <= 0.035 (~9/255) is treated as pure transparent.
// - Anti-aliasing ramp: luminance between 0.035 and 0.94 smoothly ramps alpha from 0 to 1.
let bgFloor: CGFloat = 0.035
let peakFloor: CGFloat = 0.94
let markRegion = CGRect(x: 175, y: 175, width: 670, height: 670)

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

let clearColor = NSColor(calibratedRed: 0, green: 0, blue: 0, alpha: 0)

for y in 0..<h {
    for x in 0..<w {
        guard markRegion.contains(CGPoint(x: x, y: y)) else {
            dst.setColor(clearColor, atX: x, y: y)
            continue
        }
        guard let c = srcRep.colorAt(x: x, y: y) else {
            dst.setColor(clearColor, atX: x, y: y)
            continue
        }

        // Perceptual luminance of the source pixel
        let lum = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        if lum <= bgFloor {
            dst.setColor(clearColor, atX: x, y: y)
            continue
        }

        // Smoothly interpolate alpha from 0 at bgFloor to 1.0 at peakFloor
        let normAlpha = (lum - bgFloor) / (peakFloor - bgFloor)
        let alpha = min(c.alphaComponent, max(0, min(1, normAlpha)))
        if alpha <= 0.001 {
            dst.setColor(clearColor, atX: x, y: y)
        } else {
            dst.setColor(NSColor(calibratedRed: 1, green: 1, blue: 1, alpha: alpha), atX: x, y: y)
        }
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
