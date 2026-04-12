//
//  CompanionScreenCaptureUtility.swift
//  leanring-buddy
//
//  Standalone screenshot capture for the companion voice flow.
//  Decoupled from the legacy ScreenshotManager so the companion mode
//  can capture screenshots independently without session state.
//

import AppKit
import ScreenCaptureKit

struct CompanionScreenCapture {
    let imageData: Data
    let label: String
    let isCursorScreen: Bool
    let displayWidthInPoints: Int
    let displayHeightInPoints: Int
    let displayFrame: CGRect
    let screenshotWidthInPixels: Int
    let screenshotHeightInPixels: Int
}

/// Errors thrown by `CompanionScreenCaptureUtility` when capture fails in a
/// way the caller may want to recognize and handle explicitly.
enum CompanionScreenCaptureError: Error {
    /// No visible, non-Clicky window was found belonging to the requested process.
    case noVisibleWindowForTarget(processIdentifier: pid_t)
    /// The captured `CGImage` could not be encoded to JPEG.
    case jpegEncodingFailed
}

@MainActor
enum CompanionScreenCaptureUtility {

    /// Captures all connected displays as JPEG data, labeling each with
    /// whether the user's cursor is on that screen. This gives the AI
    /// full context across multiple monitors.
    static func captureAllScreensAsJPEG() async throws -> [CompanionScreenCapture] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard !content.displays.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available for capture"])
        }

        let mouseLocation = NSEvent.mouseLocation

        // Exclude all windows belonging to this app so the AI sees
        // only the user's content, not our overlays or panels.
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownAppWindows = content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == ownBundleIdentifier
        }

        // Build a lookup from display ID to NSScreen so we can use AppKit-coordinate
        // frames instead of CG-coordinate frames. NSEvent.mouseLocation and NSScreen.frame
        // both use AppKit coordinates (bottom-left origin), while SCDisplay.frame uses
        // Core Graphics coordinates (top-left origin). On multi-display setups, the Y
        // origins differ for secondary displays, which breaks cursor-contains checks
        // and downstream coordinate conversions.
        var nsScreenByDisplayID: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                nsScreenByDisplayID[screenNumber] = screen
            }
        }

        // Sort displays so the cursor screen is always first
        let sortedDisplays = content.displays.sorted { displayA, displayB in
            let frameA = nsScreenByDisplayID[displayA.displayID]?.frame ?? displayA.frame
            let frameB = nsScreenByDisplayID[displayB.displayID]?.frame ?? displayB.frame
            let aContainsCursor = frameA.contains(mouseLocation)
            let bContainsCursor = frameB.contains(mouseLocation)
            if aContainsCursor != bContainsCursor { return aContainsCursor }
            return false
        }

        var capturedScreens: [CompanionScreenCapture] = []

        for (displayIndex, display) in sortedDisplays.enumerated() {
            // Use NSScreen.frame (AppKit coordinates, bottom-left origin) so
            // displayFrame is in the same coordinate system as NSEvent.mouseLocation
            // and the overlay window's screenFrame in BlueCursorView.
            let displayFrame = nsScreenByDisplayID[display.displayID]?.frame
                ?? CGRect(x: display.frame.origin.x, y: display.frame.origin.y,
                          width: CGFloat(display.width), height: CGFloat(display.height))
            let isCursorScreen = displayFrame.contains(mouseLocation)

            let filter = SCContentFilter(display: display, excludingWindows: ownAppWindows)

            let configuration = SCStreamConfiguration()
            let maxDimension = 1280
            let aspectRatio = CGFloat(display.width) / CGFloat(display.height)
            if display.width >= display.height {
                configuration.width = maxDimension
                configuration.height = Int(CGFloat(maxDimension) / aspectRatio)
            } else {
                configuration.height = maxDimension
                configuration.width = Int(CGFloat(maxDimension) * aspectRatio)
            }

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )

            guard let jpegData = NSBitmapImageRep(cgImage: cgImage)
                    .representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
                continue
            }

            let screenLabel: String
            if sortedDisplays.count == 1 {
                screenLabel = "user's screen (cursor is here)"
            } else if isCursorScreen {
                screenLabel = "screen \(displayIndex + 1) of \(sortedDisplays.count) — cursor is on this screen (primary focus)"
            } else {
                screenLabel = "screen \(displayIndex + 1) of \(sortedDisplays.count) — secondary screen"
            }

            capturedScreens.append(CompanionScreenCapture(
                imageData: jpegData,
                label: screenLabel,
                isCursorScreen: isCursorScreen,
                displayWidthInPoints: Int(displayFrame.width),
                displayHeightInPoints: Int(displayFrame.height),
                displayFrame: displayFrame,
                screenshotWidthInPixels: configuration.width,
                screenshotHeightInPixels: configuration.height
            ))
        }

        guard !capturedScreens.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to capture any screen"])
        }

        return capturedScreens
    }

    /// Captures just the frontmost on-screen window belonging to the given
    /// process and returns it as a single JPEG. Used by Interactive Mode so
    /// the AI receives only the semantically relevant window instead of the
    /// full display, reducing outbound payload size and visual noise.
    ///
    /// - Parameter targetProcessIdentifier: PID of the application whose
    ///   frontmost window should be captured. Clicky's own windows are
    ///   explicitly excluded so the method cannot accidentally capture the
    ///   companion overlay or menu bar panel.
    /// - Returns: A single `CompanionScreenCapture` whose JPEG encodes the
    ///   window at up to 1280px on its longest edge.
    /// - Throws: `CompanionScreenCaptureError.noVisibleWindowForTarget` if
    ///   no matching on-screen window was found,
    ///   `CompanionScreenCaptureError.jpegEncodingFailed` if the captured
    ///   `CGImage` could not be encoded, or any error propagated from
    ///   `SCShareableContent` / `SCScreenshotManager`.
    static func captureFrontmostWindowAsJPEG(
        targetProcessIdentifier: pid_t
    ) async throws -> CompanionScreenCapture {
        let shareableContent = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )

        // Exclude Clicky's own windows up-front so the frontmost search can
        // never pick the companion overlay, menu bar panel, or any other
        // window this app contributes to the shared window list.
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let candidateWindowsForTarget = shareableContent.windows.filter { candidateWindow in
            guard let owningApplication = candidateWindow.owningApplication else { return false }
            if owningApplication.bundleIdentifier == ownBundleIdentifier { return false }
            return owningApplication.processID == targetProcessIdentifier
        }

        // SCShareableContent.windows is returned in front-to-back z-order, so
        // the first visible window with a reasonable size is the frontmost
        // one the user is most likely interacting with. The size filter drops
        // tiny utility/helper windows (tooltips, panels, etc.) that the user
        // almost certainly did not mean to reference.
        let minimumWindowEdgeInPoints: CGFloat = 100
        guard let frontmostWindowForTarget = candidateWindowsForTarget.first(where: { candidateWindow in
            candidateWindow.isOnScreen
                && candidateWindow.frame.size.width >= minimumWindowEdgeInPoints
                && candidateWindow.frame.size.height >= minimumWindowEdgeInPoints
        }) else {
            throw CompanionScreenCaptureError.noVisibleWindowForTarget(
                processIdentifier: targetProcessIdentifier
            )
        }

        // Determine the pixel-per-point scale factor for the display this
        // window lives on. SCWindow.frame is in points (CG top-left origin),
        // but SCStreamConfiguration.width/height are in pixels. If we ignore
        // scale, the capture comes out at 1x on Retina displays and looks
        // blurry. We find the owning display by testing which SCDisplay's
        // frame contains the window's center, then compute the scale from
        // the display's pixel width vs. its point width.
        let windowCenterPoint = CGPoint(
            x: frontmostWindowForTarget.frame.midX,
            y: frontmostWindowForTarget.frame.midY
        )
        let owningDisplayForWindow = shareableContent.displays.first(where: { candidateDisplay in
            candidateDisplay.frame.contains(windowCenterPoint)
        }) ?? shareableContent.displays.first

        let pixelsPerPointScaleFactor: CGFloat
        if let owningDisplayForWindow, owningDisplayForWindow.frame.width > 0 {
            pixelsPerPointScaleFactor = CGFloat(owningDisplayForWindow.width) / owningDisplayForWindow.frame.width
        } else {
            pixelsPerPointScaleFactor = 2.0
        }

        // Compute the native pixel dimensions of the window, then cap the
        // longest edge at 1280 to match the sizing policy of
        // `captureAllScreensAsJPEG()`. Scaling is proportional so the
        // aspect ratio is preserved.
        let nativeWindowWidthInPixels = frontmostWindowForTarget.frame.width * pixelsPerPointScaleFactor
        let nativeWindowHeightInPixels = frontmostWindowForTarget.frame.height * pixelsPerPointScaleFactor

        let maxOutputEdgeInPixels: CGFloat = 1280
        let longestNativeEdgeInPixels = max(nativeWindowWidthInPixels, nativeWindowHeightInPixels)
        let outputScaleFactor: CGFloat
        if longestNativeEdgeInPixels > maxOutputEdgeInPixels {
            outputScaleFactor = maxOutputEdgeInPixels / longestNativeEdgeInPixels
        } else {
            outputScaleFactor = 1.0
        }

        let outputWidthInPixels = max(1, Int((nativeWindowWidthInPixels * outputScaleFactor).rounded()))
        let outputHeightInPixels = max(1, Int((nativeWindowHeightInPixels * outputScaleFactor).rounded()))

        let windowContentFilter = SCContentFilter(desktopIndependentWindow: frontmostWindowForTarget)

        let streamConfiguration = SCStreamConfiguration()
        streamConfiguration.width = outputWidthInPixels
        streamConfiguration.height = outputHeightInPixels

        let capturedWindowCGImage = try await SCScreenshotManager.captureImage(
            contentFilter: windowContentFilter,
            configuration: streamConfiguration
        )

        // Follow the exact same CGImage -> JPEG conversion the multi-display
        // path uses so the two code paths produce byte-identical encodings
        // for the same input pixels.
        guard let jpegEncodedWindowData = NSBitmapImageRep(cgImage: capturedWindowCGImage)
                .representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            throw CompanionScreenCaptureError.jpegEncodingFailed
        }

        let owningApplicationDisplayName = frontmostWindowForTarget.owningApplication?.applicationName ?? "Application"
        let windowTitleOrFallback = frontmostWindowForTarget.title ?? "window"
        let captureLabel = "\(owningApplicationDisplayName) - \(windowTitleOrFallback)"

        return CompanionScreenCapture(
            imageData: jpegEncodedWindowData,
            label: captureLabel,
            isCursorScreen: true,
            displayWidthInPoints: Int(frontmostWindowForTarget.frame.width),
            displayHeightInPoints: Int(frontmostWindowForTarget.frame.height),
            displayFrame: frontmostWindowForTarget.frame,
            screenshotWidthInPixels: outputWidthInPixels,
            screenshotHeightInPixels: outputHeightInPixels
        )
    }
}
